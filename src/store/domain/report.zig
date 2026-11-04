//! Session reports and lists rendered as JSON, and failed-response capture.

const std = @import("std");
const attempt = @import("../../attempt.zig");
const named_scratch = @import("../../named_scratch.zig");
const protocol = @import("../../protocol.zig");
const model_capability = @import("../../model_capability.zig");
const tool_catalog = @import("../../tools.zig");
const turn_policy = @import("../../turn_policy.zig");
const session_work = @import("../../session_work.zig");
const Quota = @import("../../transport_policy.zig").Quota;
const change_ring = @import("../../change_ring.zig");
const store_core = @import("../Store.zig");
const rsql = @import("../rsql.zig");
const store_access = @import("../access.zig");
const pages = @import("../../os/pages.zig");
const Store = store_core.Store;
const action_domain = @import("action.zig");
const command_domain = @import("command.zig");
const configuration_domain = @import("configuration.zig");
const content_domain = @import("content.zig");
const model_admission_domain = @import("model_admission.zig");
const reads_domain = @import("reads.zig");
const store_schema = @import("../schema.zig");
const turn_domain = @import("turn.zig");
const AttemptBinding = store_core.AttemptBinding;
const ContentReference = content_domain.ContentReference;
const CurrentConfiguration = configuration_domain.CurrentConfiguration;
const RevisionContentField = configuration_domain.RevisionContentField;
const TurnOutcome = turn_domain.TurnOutcome;
const max_action_resolution_code_bytes = action_domain.max_action_resolution_code_bytes;
const max_permission_decision_bytes = command_domain.max_permission_decision_bytes;
pub const ReadAccess = reads_domain.ReadAccess;
const SessionText = protocol.Bounded(protocol.max_session_bytes);
const Code = protocol.Bounded(protocol.max_code_bytes);

pub const SessionReportExecution = struct {
    dispatch_fenced: bool,
    custody_occupied: usize,
    scratch_used_bytes: u64,
};

pub const SessionReportOptions = struct {
    scratch_path: []const u8,
    scratch_budget: protocol.ScratchBudget,
    request_number: u64,
    profile: protocol.ReportProfile = .current,
    execution: SessionReportExecution,
    fail_unlink: bool = false,
};

pub const SessionListOptions = struct {
    scratch_path: []const u8,
    scratch_budget: protocol.ScratchBudget,
    request_number: u64,
    fail_unlink: bool = false,
};

pub const SessionReport = struct {
    pub const read_window_bytes = 64 * 1024;

    io: std.Io,
    file: std.Io.File,
    length: u64,
    charged: u64,
    budget: protocol.ScratchBudget,

    pub fn read(self: *SessionReport, start: u64, destination: []u8) !usize {
        if (destination.len > read_window_bytes) return error.WindowTooLarge;
        if (start > self.length) return error.RangeOutOfBounds;
        const wanted: usize = @intCast(@min(self.length - start, destination.len));
        return self.file.readPositionalAll(self.io, destination[0..wanted], start);
    }

    pub fn deinit(self: *SessionReport) void {
        self.file.close(self.io);
        self.budget.release(self.charged);
        self.* = undefined;
    }
};

pub const SessionReportCapture = struct {
    const buffer_bytes = 4096;

    io: std.Io,
    writer: ?std.Io.File,
    budget: protocol.ScratchBudget,
    buffer: [buffer_bytes]u8 = undefined,
    buffered: usize = 0,
    length: u64 = 0,
    charged: u64 = 0,
    ordinary_failure: bool = false,

    /// Creates the capture's unlinked scratch file. The capture is declared
    /// with a literal of its io, budget and null writer, which leaves its
    /// 4 KB buffer unwritten; `= undefined` would fill it with 0xAA first.
    pub fn create(self: *SessionReportCapture, scratch_path: []const u8, request_number: u64, fail_unlink: bool) !void {
        std.debug.assert(self.writer == null and self.charged == 0);
        const io = self.io;
        var scratch = try std.Io.Dir.cwd().openDir(io, scratch_path, .{});
        defer scratch.close(io);
        var name_buffer: [96]u8 = undefined;
        const name = try named_scratch.NumericName.report.format(&name_buffer, request_number, 1);
        const writer = try scratch.createFile(io, name, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        errdefer writer.close(io);
        if (fail_unlink) return error.ReportScratchCleanupFailed;
        scratch.deleteFile(io, name) catch return error.ReportScratchCleanupFailed;
        self.writer = writer;
    }

    pub fn append(self: *SessionReportCapture, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len != 0) {
            if (self.buffered == self.buffer.len) try self.flush();
            const count = @min(remaining.len, self.buffer.len - self.buffered);
            @memcpy(self.buffer[self.buffered..][0..count], remaining[0..count]);
            self.buffered += count;
            remaining = remaining[count..];
        }
    }

    fn appendFmt(self: *SessionReportCapture, comptime format: []const u8, args: anytype) !void {
        var bytes: [512]u8 = undefined;
        const value = std.fmt.bufPrint(&bytes, format, args) catch {
            self.ordinary_failure = true;
            return error.ReportEncodingFailed;
        };
        try self.append(value);
    }

    /// Writes a protocol shape straight into the capture, so a fact's
    /// maximum encoding never sits whole on the intake worker's stack.
    fn appendShape(self: *SessionReportCapture, comptime shape: anytype, args: anytype) AppendError!void {
        var buffer: [256]u8 = undefined;
        var sink: ShapeSink = .{ .capture = self, .writer = .{ .vtable = &.{ .drain = ShapeSink.drain }, .buffer = &buffer } };
        protocol.writeShape(&sink.writer, shape, args) catch return sink.failure.?;
        sink.writer.flush() catch return sink.failure.?;
    }

    const AppendError = @typeInfo(@typeInfo(@TypeOf(append)).@"fn".return_type.?).error_union.error_set;

    const ShapeSink = struct {
        capture: *SessionReportCapture,
        failure: ?AppendError = null,
        writer: std.Io.Writer,

        fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const sink: *ShapeSink = @alignCast(@fieldParentPtr("writer", writer));
            try sink.put(writer.buffer[0..writer.end]);
            writer.end = 0;
            var written: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                try sink.put(bytes);
                written += bytes.len;
            }
            for (0..splat) |_| {
                try sink.put(data[data.len - 1]);
                written += data[data.len - 1].len;
            }
            return written;
        }

        fn put(sink: *ShapeSink, bytes: []const u8) std.Io.Writer.Error!void {
            sink.capture.append(bytes) catch |err| {
                sink.failure = err;
                return error.WriteFailed;
            };
        }
    };

    fn appendJsonString(self: *SessionReportCapture, value: []const u8) !void {
        try self.append("\"");
        try self.appendJsonStringBytes(value);
        try self.append("\"");
    }

    fn appendJsonStringBytes(self: *SessionReportCapture, value: []const u8) !void {
        var run_start: usize = 0;
        for (value, 0..) |byte, index| {
            const escaped: ?[]const u8 = switch (byte) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                8 => "\\b",
                12 => "\\f",
                0...7, 11, 14...31 => null,
                else => continue,
            };
            if (index != run_start) try self.append(value[run_start..index]);
            if (escaped) |bytes| {
                try self.append(bytes);
            } else {
                var control: [6]u8 = undefined;
                _ = std.fmt.bufPrint(&control, "\\u00{x:0>2}", .{byte}) catch unreachable;
                try self.append(&control);
            }
            run_start = index + 1;
        }
        if (run_start != value.len) try self.append(value[run_start..]);
    }

    fn appendContentReference(self: *SessionReportCapture, reference: ContentReference) !void {
        try self.appendFmt("{{\"type\":\"text\",\"bytes\":\"{d}\",\"sha256\":\"", .{reference.length});
        try self.append(&std.fmt.bytesToHex(reference.digest, .lower));
        try self.append("\"}");
    }

    fn appendBareContentReference(self: *SessionReportCapture, reference: ContentReference) !void {
        try self.appendFmt("{{\"bytes\":\"{d}\",\"sha256\":\"", .{reference.length});
        try self.append(&std.fmt.bytesToHex(reference.digest, .lower));
        try self.append("\"}");
    }

    fn appendOwnedContentReference(
        self: *SessionReportCapture,
        reference: ContentReference,
        owner_revision: i64,
        owner_field: RevisionContentField,
    ) !void {
        try self.appendFmt("{{\"bytes\":\"{d}\",\"sha256\":\"", .{reference.length});
        try self.append(&std.fmt.bytesToHex(reference.digest, .lower));
        try self.appendFmt("\",\"owner\":{{\"revision\":\"{d}\",\"field\":\"{s}\"}}}}", .{ owner_revision, @tagName(owner_field) });
    }

    fn appendTools(self: *SessionReportCapture, tools_mask: u8) !void {
        const tools = try configuration_domain.toolSet(tools_mask);
        try self.append("[");
        var first = true;
        for (std.enums.values(tool_catalog.Tool)) |tool| if (tools.contains(tool)) {
            if (!first) try self.append(",");
            first = false;
            try self.append("\"");
            try self.append(@tagName(tool));
            try self.append("\"");
        };
        try self.append("]");
    }

    fn appendPermissionMode(self: *SessionReportCapture, permission_mode: u8) !void {
        try self.appendJsonString(@tagName(try configuration_domain.permissionMode(permission_mode)));
    }

    fn flush(self: *SessionReportCapture) !void {
        if (self.buffered == 0) return;
        const amount: u64 = self.buffered;
        const next_charged = std.math.add(u64, self.charged, amount) catch {
            self.ordinary_failure = true;
            return error.ReportLengthOverflow;
        };
        const next_length = std.math.add(u64, self.length, amount) catch {
            self.ordinary_failure = true;
            return error.ReportLengthOverflow;
        };
        if (!self.budget.allocate(amount)) {
            self.ordinary_failure = true;
            return error.ReportScratchExhausted;
        }
        self.charged = next_charged;
        const writer = self.writer orelse unreachable;
        writer.writeStreamingAll(self.io, self.buffer[0..self.buffered]) catch |err| {
            self.ordinary_failure = true;
            return err;
        };
        self.length = next_length;
        self.buffered = 0;
    }

    pub fn seal(self: *SessionReportCapture) !SessionReport {
        try self.flush();
        const writer = self.writer orelse unreachable;
        if (writer.length(self.io) catch |err| {
            self.ordinary_failure = true;
            return err;
        } != self.length) {
            self.ordinary_failure = true;
            return error.ReportSealFailed;
        }
        const report = SessionReport{
            .io = self.io,
            .file = writer,
            .length = self.length,
            .charged = self.charged,
            .budget = self.budget,
        };
        self.writer = null;
        self.charged = 0;
        return report;
    }

    pub fn deinit(self: *SessionReportCapture) void {
        if (self.writer) |writer| writer.close(self.io);
        self.budget.release(self.charged);
    }
};

/// The Turn of the Operation a failed response names, in its Session, at
/// or past its Attempt.
const failed_response_turn = rsql.Read(.{
    .sql = "SELECT turn_id FROM model_operation WHERE operation_id=?1 AND session_ref=?2 AND attempt_ordinal>=?3",
    .Args = struct { operation: u64, session: []const u8, attempt: u64 },
    .Row = struct { turn_id: rsql.Positive },
    .cardinality = .optional,
});

/// One round: the failed response's Operation, which must still be in its
/// Session at or past the Attempt asked for.
pub fn failedResponseBinding(a: *ReadAccess, session: []const u8, selection: protocol.FailedResponseExport) !AttemptBinding {
    var found: failed_response_turn.Result = undefined;
    a.read(failed_response_turn, .{ .operation = selection.operation, .session = session, .attempt = selection.attempt }, &found);
    try store_access.runAs(a, error.OperationReadFailed);
    const row = found orelse return error.ContentNotFound;
    return .{ .turn_id = row.turn_id.get(), .operation_id = selection.operation, .attempt_ordinal = selection.attempt };
}

/// The newest Session's creation sequence, the ceiling of a list that
/// starts from the beginning.
const list_ceiling = rsql.Read(.{
    .sql = "SELECT coalesce(max(created_seq),0) AS ceiling FROM session",
    .Args = struct {},
    .Row = struct { ceiling: u64 },
    .cardinality = .each,
});

/// A page and one Session more, which says whether there are more: the
/// `LIMIT` of each page read and its `readEach` bound.
const list_limit = protocol.session_list_page_size + 1;

/// A full traversal's page of Sessions in creation order, with the one
/// after it.
const list_page = rsql.Read(.{
    .sql = "SELECT created_seq,session_ref FROM session WHERE created_seq>?1 AND created_seq<=?2 ORDER BY created_seq LIMIT " ++ std.fmt.comptimePrint("{d}", .{list_limit}),
    .Args = struct { after: u64, ceiling: u64 },
    .Row = ListPage.Row,
    .cardinality = .each,
});

/// `list_page` within one Workspace.
const workspace_list_page = rsql.Read(.{
    .sql = "SELECT created_seq,session_ref FROM session @index(session_workspace_list) " ++
        "WHERE workspace_digest=?3 AND workspace=?4 AND created_seq>?1 AND created_seq<=?2 ORDER BY created_seq LIMIT " ++ std.fmt.comptimePrint("{d}", .{list_limit}),
    .Args = struct { after: u64, ceiling: u64, digest: [32]u8, workspace: []const u8 },
    .Row = ListPage.Row,
    .cardinality = .each,
});

/// The change ring's key for a Workspace: the stored key of its
/// Sessions, or none while it has none.
const workspace_key = rsql.Read(.{
    .sql = "SELECT workspace_key FROM session WHERE workspace_digest=?1 AND workspace=?2 LIMIT 1",
    .Args = struct { digest: [32]u8, workspace: []const u8 },
    .Row = struct { workspace_key: rsql.Positive },
    .cardinality = .optional,
});

/// A page of a full traversal: its Sessions' references, up to a page,
/// and whether a Session follows them (`list_limit`).
const ListPage = struct {
    const Row = struct { created_seq: rsql.Positive, session_ref: SessionText };

    refs: [protocol.session_list_page_size]change_ring.Id = undefined,
    count: usize = 0,
    last: u64 = 0,
    more: bool = false,
    failure: ?error{CorruptStore} = null,

    pub fn visit(page: *ListPage, row: *const Row) bool {
        if (page.count == page.refs.len) {
            page.more = true;
            return false;
        }
        const ref = row.session_ref.slice();
        // The session table's CHECK (schema.zig) holds every stored
        // reference to `id_bytes`; main read any up to 128 bytes.
        if (ref.len != change_ring.id_bytes) {
            page.failure = error.CorruptStore;
            return false;
        }
        page.refs[page.count] = ref[0..change_ring.id_bytes].*;
        page.last = row.created_seq.get();
        page.count += 1;
        return true;
    }
};

pub fn renderSessionList(a: *ReadAccess, request: *const protocol.ListSessions, capture: *SessionReportCapture) !void {
    const self = a.store;
    const generation = self.commit_generation.load(.acquire);
    // Changed rows answer while the hint still covers the token; a token
    // from another opening, or one too old, gets a full traversal.
    if (request.since) |since| {
        const through = if (request.changed) |changed| changed.through else generation;
        if (std.mem.eql(u8, &since.instance, &self.instance) and through <= generation and self.changes.covers(since.generation))
            return renderChangedSessions(a, request, since.generation, through, capture);
    }
    try renderAllSessions(a, request, generation, capture);
}

/// Every Session in scope, in creation order, eight per page. A full
/// traversal reads only the request's scope, `after` and `ceiling`. A
/// list from the beginning reads its ceiling in the page's round: every
/// Session is at or below the newest, so the page needs no bound then.
fn renderAllSessions(a: *ReadAccess, request: *const protocol.ListSessions, generation: u64, capture: *SessionReportCapture) !void {
    // An aggregate has one row, stepped once, as main did.
    var maximum: reads_domain.First(list_ceiling.Row) = .{};
    if (request.after == 0) a.readEach(list_ceiling, .{}, 1, &maximum);
    const bound: u64 = if (request.after == 0) std.math.maxInt(i64) else request.ceiling;
    var page: ListPage = .{};
    if (request.workspace) |*workspace|
        a.readEach(workspace_list_page, .{ .after = request.after, .ceiling = bound, .digest = store_core.workspaceDigest(workspace.slice()), .workspace = workspace.slice() }, list_limit, &page)
    else
        a.readEach(list_page, .{ .after = request.after, .ceiling = bound }, list_limit, &page);
    try store_access.runAs(a, error.SessionReadFailed);
    if (page.failure) |err| return err;
    const ceiling = if (request.after == 0) (maximum.row orelse return error.SessionReadFailed).ceiling else request.ceiling;
    try appendSessionRows(a, page.refs[0..page.count], capture);
    var token: [protocol.SinceToken.max_bytes]u8 = undefined;
    const since = (protocol.SinceToken{ .instance = a.store.instance, .generation = generation }).format(&token);
    if (page.more)
        try capture.appendShape(protocol.session_list_reply.full_tail, .{ protocol.ListDelta.full, since, page.last, ceiling })
    else
        try capture.appendShape(protocol.session_list_reply.last_tail, .{ protocol.ListDelta.full, since });
    std.debug.assert(capture.length + capture.buffered <= protocol.session_list_reply.max_bytes);
}

/// The Sessions in scope that the hint says changed in (since, through],
/// in ID order, eight per page: the Workspace's key, then one pass over
/// the ring in memory, then the shown rows. A Session it names may be
/// unchanged; one it omits did not change.
fn renderChangedSessions(a: *ReadAccess, request: *const protocol.ListSessions, since: u64, through: u64, capture: *SessionReportCapture) !void {
    var workspace: ?u64 = null;
    if (request.workspace) |*scope| {
        var key: workspace_key.Result = undefined;
        a.read(workspace_key, .{ .digest = store_core.workspaceDigest(scope.slice()), .workspace = scope.slice() }, &key);
        try store_access.runAs(a, error.SessionReadFailed);
        workspace = if (key) |row| row.workspace_key.get() else 0;
    }
    const self = a.store;
    const after: ?*const change_ring.Id = if (request.changed) |*changed| &changed.after_reference else null;
    var references: [protocol.session_list_page_size + 1]change_ring.Id = undefined;
    const changed = self.changes.changed(since, through, workspace, after, &references);
    const count = @min(changed.len, protocol.session_list_page_size);
    try appendSessionRows(a, changed[0..count], capture);
    var token: [protocol.SinceToken.max_bytes]u8 = undefined;
    const next = (protocol.SinceToken{ .instance = self.instance, .generation = through }).format(&token);
    if (changed.len > count)
        try capture.appendShape(protocol.session_list_reply.changed_tail, .{ protocol.ListDelta.changed, next, through, &changed[count - 1] })
    else
        try capture.appendShape(protocol.session_list_reply.last_tail, .{ protocol.ListDelta.changed, next });
    std.debug.assert(capture.length + capture.buffered <= protocol.session_list_reply.max_bytes);
}

/// A Session's first Message is the earlier of two seeks: a Turn binds
/// queued Messages in admission order, so the first Turn's first
/// admission precedes every other bound one, and the only other candidate
/// is the oldest Message never bound, queued or excluded by a stop.
const first_bound = rsql.Read(.{
    .sql = "SELECT first_admission_id FROM turn @index(turn_session_latest) WHERE session_ref=?1 ORDER BY turn_id LIMIT 1",
    .Args = struct { session: []const u8 },
    .Row = struct { first_admission_id: rsql.Positive },
    .cardinality = .optional,
});

const first_unbound = rsql.Read(.{
    .sql = "SELECT admission_id FROM message_admission @index(message_admission_session_pending) " ++
        "WHERE session_ref=?1 AND turn_id IS NULL ORDER BY admission_id LIMIT 1",
    .Args = struct { session: []const u8 },
    .Row = struct { admission_id: rsql.Positive },
    .cardinality = .optional,
});

/// Both first-Message seeks, queued in one round.
const FirstCandidates = struct {
    bound: first_bound.Result = null,
    unbound: first_unbound.Result = null,

    fn queue(first: *FirstCandidates, a: *ReadAccess, session: []const u8) void {
        a.read(first_bound, .{ .session = session }, &first.bound);
        a.read(first_unbound, .{ .session = session }, &first.unbound);
    }

    /// The earlier candidate, or 0 for none.
    fn admission(first: *const FirstCandidates) u64 {
        const bound = if (first.bound) |row| row.first_admission_id.get() else std.math.maxInt(u64);
        const unbound = if (first.unbound) |row| row.admission_id.get() else std.math.maxInt(u64);
        const earlier = @min(bound, unbound);
        return if (earlier == std.math.maxInt(u64)) 0 else earlier;
    }
};

/// The latest Message to the Session ?1 with no Session sender.
const person_message_sql = "SELECT admitted_at FROM message_admission @index(message_admission_person) " ++
    "WHERE session_ref=?1 AND sender_session_ref IS NULL ORDER BY admission_position DESC LIMIT 1";

const person_message = rsql.Read(.{
    .sql = person_message_sql,
    .Args = struct { session: []const u8 },
    .Row = struct { admitted_at: rsql.Positive },
    .cardinality = .optional,
});

/// The first Message `m`'s own row and its content's metadata.
const first_message_columns = "m.admission_id AS first_admission,m.admission_position AS first_position,m.admitted_at AS first_admitted_at," ++
    "m.sender_session_ref AS first_sender,first_content.byte_length AS first_length,first_content.digest AS first_digest,first_content.private AS first_private";

/// The content metadata of the first Message `m`.
const first_content_join = "JOIN content first_content ON first_content.content_id=m.content_id";

/// A first Message as `firstMessage` reads it; a list row's are null
/// when it has none.
const FirstMessageColumns = struct {
    first_admission: ?rsql.Positive,
    first_position: ?rsql.Positive,
    first_admitted_at: ?rsql.Positive,
    first_sender: ?SessionText,
    first_length: ?u64,
    first_digest: ?[32]u8,
    first_private: ?bool,
};

const first_message = rsql.Read(.{
    .sql = "SELECT " ++ first_message_columns ++ " FROM message_admission m " ++ first_content_join ++ " WHERE m.admission_id=?2 AND m.session_ref=?1",
    .Args = struct { session: []const u8, first: u64 },
    .Row = FirstMessageColumns,
    .cardinality = .optional,
});

const settings_columns = "s.session_ref,s.workspace,s.provider,s.model,s.tools_mask,s.permission_mode,s.label,s.created_at,s.revision,s.next_position," ++
    "(" ++ person_message_sql ++ ") AS from_person_at,";

/// One list row: the Session's settings, its latest Message from no
/// Session, and its first Message, the admission ?2. A missing Message
/// or content finds no row. Its Row is over 1 KiB, so its visitor owns
/// it (`RowsRender`).
const list_row = rsql.Read(.{
    .sql = "SELECT " ++ settings_columns ++ first_message_columns ++ " FROM session s " ++
        "JOIN message_admission m ON m.admission_id=?2 AND m.session_ref=s.session_ref " ++ first_content_join ++ " WHERE s.session_ref=?1",
    .Args = struct { session: []const u8, first: u64 },
    .Row = ListRow,
    .cardinality = .each,
});

/// `list_row` of a Session with no first Message.
const list_row_bare = rsql.Read(.{
    .sql = "SELECT " ++ settings_columns ++ "NULL AS first_admission,NULL AS first_position,NULL AS first_admitted_at,NULL AS first_sender," ++
        "NULL AS first_length,NULL AS first_digest,NULL AS first_private FROM session s WHERE s.session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = ListRow,
    .cardinality = .each,
});

const ListRow = struct {
    session_ref: SessionText,
    workspace: protocol.Bounded(protocol.max_workspace_bytes),
    provider: protocol.Provider,
    model: protocol.Bounded(protocol.max_model_bytes),
    tools_mask: u8,
    permission_mode: u8,
    label: ?protocol.Bounded(protocol.max_label_bytes),
    created_at: rsql.Positive,
    revision: rsql.Positive,
    next_position: rsql.Positive,
    from_person_at: ?rsql.Positive,
    first_admission: ?rsql.Positive,
    first_position: ?rsql.Positive,
    first_admitted_at: ?rsql.Positive,
    first_sender: ?SessionText,
    first_length: ?u64,
    first_digest: ?[32]u8,
    first_private: ?bool,
};

/// The first Message of a row with `FirstMessageColumns`, read for the
/// admission `first` (0 for none). Content that is private is
/// `CorruptStore`.
fn firstMessage(row: anytype, first: u64) error{CorruptStore}!?protocol.FirstMessage {
    if (first == 0) return null;
    if (row.first_private orelse return error.CorruptStore) return error.CorruptStore;
    return .{
        .position = (row.first_position orelse return error.CorruptStore).get(),
        .admission = (row.first_admission orelse return error.CorruptStore).get(),
        .admitted_at = (row.first_admitted_at orelse return error.CorruptStore).get(),
        .sender = if (row.first_sender) |sender| .{ .session = sender } else null,
        .content = .{ .length = row.first_length orelse return error.CorruptStore, .digest = row.first_digest orelse return error.CorruptStore },
    };
}

/// The page head and its rows. Each row's first admission and work take
/// the rounds their reads depend on, shared by every row; the rows'
/// settings come last (`renderRows`), so the page holds one row's text at
/// a time and not eight.
noinline fn appendSessionRows(a: *ReadAccess, references: []const change_ring.Id, capture: *SessionReportCapture) !void {
    const now_ms = try store_core.readUnixMilliseconds(a.store.io);
    try capture.appendShape(protocol.session_list_reply.head, .{});
    var firsts: [protocol.session_list_page_size]FirstCandidates = undefined;
    var works: [protocol.session_list_page_size]WorkRead = undefined;
    // Each row's reads queued together: a pass ends where a statement is
    // queued again, so the round takes one pass per row, not two.
    for (references, firsts[0..references.len], works[0..references.len]) |*reference, *first, *work| {
        first.queue(a, reference);
        work.* = .{ .session = reference };
        _ = work.queue(a);
    }
    try runReport(a);
    for (works[0..references.len]) |*work| try work.advance();
    try readWorks(a, works[0..references.len]);
    var shown: [protocol.session_list_page_size]ShownRow = undefined;
    for (references, firsts[0..references.len], works[0..references.len], shown[0..references.len]) |*reference, *first, *work, *row|
        row.* = .{ .reference = reference, .first = first.admission(), .work = work };
    try renderRows(a, shown[0..references.len], std.math.cast(u64, now_ms) orelse return error.IntegerOutOfRange, capture);
}

/// What a list row read before its settings.
const ShownRow = struct { reference: *const change_ring.Id, first: u64, work: *const WorkRead };

/// Reads each shown row's `list_row` in one round and renders it as it
/// steps. Not inlined: its visitor holds a row's text.
noinline fn renderRows(a: *ReadAccess, rows: []const ShownRow, now_ms: u64, capture: *SessionReportCapture) !void {
    // A literal that omits `decoded` leaves its bytes unwritten until a
    // row decodes into it.
    var render: RowsRender = .{ .rows = rows, .now_ms = now_ms, .capture = capture };
    for (rows) |row| {
        if (row.first == 0)
            a.readEach(list_row_bare, .{ .session = row.reference }, 1, &render)
        else
            a.readEach(list_row, .{ .session = row.reference, .first = row.first }, 1, &render);
    }
    const ran = runReport(a);
    // A pass stops at a failed step, so a row that failed to render did
    // before any later row's step failed: its error is main's first.
    if (render.failure) |err| return err;
    try ran;
    if (render.shown != rows.len) return error.CorruptStore;
}

/// Renders each `list_row` as it steps, in the page's order. A row that
/// is not the next shown Session's, or a missing one, is `CorruptStore`;
/// after a failure it renders nothing more.
const RowsRender = struct {
    decoded: ListRow = undefined,
    rows: []const ShownRow,
    now_ms: u64,
    capture: *SessionReportCapture,
    shown: usize = 0,
    failure: ?RenderError = null,

    const RenderError = @typeInfo(@typeInfo(@TypeOf(renderListRow)).@"fn".return_type.?).error_union.error_set;

    pub fn visit(render: *RowsRender, row: *const ListRow) bool {
        if (render.failure != null) return false;
        renderListRow(render.capture, render.rows, render.shown, render.now_ms, row) catch |err| {
            render.failure = err;
            return false;
        };
        render.shown += 1;
        return true;
    }
};

fn renderListRow(capture: *SessionReportCapture, rows: []const ShownRow, index: usize, now_ms: u64, row: *const ListRow) !void {
    if (index == rows.len or !std.mem.eql(u8, row.session_ref.slice(), rows[index].reference)) return error.CorruptStore;
    const tools = try configuration_domain.toolSet(row.tools_mask);
    if (row.label) |*label| try configuration_domain.checkLabel(label.slice());
    const work: protocol.SessionWork = .fromCore(try rows[index].work.work(row.created_at.get(), now_ms));
    const peers: protocol.PeerFacts = .{ .from_person_at = optional(row.from_person_at) };
    const fields: protocol.SessionRow.Fields = .{
        .reference = row.session_ref.slice(),
        .workspace = row.workspace.slice(),
        .provider = row.provider,
        .model = row.model.slice(),
        .bash = tools.contains(.bash),
        .web_search = tools.contains(.web_search),
        .permission_mode = try configuration_domain.permissionMode(row.permission_mode),
        .label = if (row.label) |*label| label.slice() else null,
        .created_at = row.created_at.get(),
        .revision = row.revision.get(),
        .end = row.next_position.get() - 1,
        .first_message = try firstMessage(row, rows[index].first),
        .work = &work,
        .peers = &peers,
    };
    if (index != 0) try capture.append(",");
    try capture.appendShape(.{protocol.Hole{ .json = protocol.SessionRow.Fields }}, .{&fields});
}

/// A Session report on the report's Access `a`: its saved Session and
/// Current facts (`renderHead`), then, for the Full profile, its history
/// (`renderFull`), all under one Entry, so one snapshot.
pub fn renderSessionReport(
    a: *ReadAccess,
    session_ref: []const u8,
    profile: protocol.ReportProfile,
    execution: SessionReportExecution,
    capture: *SessionReportCapture,
) !void {
    if (!try renderHead(a, session_ref, profile, capture)) return;
    if (profile == .full) try renderFull(a, session_ref, capture);
    try capture.appendFmt(",\"execution\":{{\"status\":\"partial\",\"dispatch_fenced\":{s},\"custody_occupied\":\"{d}\",\"scratch_used_bytes\":\"{d}\",\"unavailable\":[\"structured_output\"]}}}}", .{
        if (execution.dispatch_fenced) "true" else "false",
        execution.custody_occupied,
        execution.scratch_used_bytes,
    });
}

/// A report's head, whose rounds tests count: round 1 reads the saved
/// Session, and a missing one ends the report there, with its execution
/// (false); the Current facts follow (`renderCurrent`). Not inlined: the
/// saved Session lives in its frame, which returns before any history
/// content is read.
pub noinline fn renderHead(a: *ReadAccess, session_ref: []const u8, profile: protocol.ReportProfile, capture: *SessionReportCapture) !bool {
    var current: CurrentConfiguration = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } };
    var found: store_access.Found = undefined;
    configuration_domain.readSaved(a, session_ref, &current, &found);
    try a.run();
    if (found.get()) try configuration_domain.checkSaved(&current);
    try capture.append("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_report\",\"profile\":\"");
    try capture.append(@tagName(profile));
    try capture.append("\",\"session\":");
    if (!found.get()) {
        try capture.append("null,\"pending_messages\":\"0\",\"execution\":{\"status\":\"unavailable\",\"reason\":\"session_not_found\"}}");
        return false;
    }
    try renderCurrent(a, session_ref, &current, capture);
    return true;
}

/// The active Turn's Operations that proposed calls: each resolved with
/// tool proposals, as main checked them, and each other one with a call,
/// whose Actions and rejected calls the Current report lists, where main
/// checked the listed calls' Operations and Proposals.
const active_proposers_sql = "FROM turn active @index(turn_one_active_per_session) " ++
    "CROSS JOIN model_operation operation @index(model_operation_turn_history) ON operation.turn_id=active.turn_id " ++
    "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND (" ++ store_schema.resolutionIs("operation.resolution_code", .tool_proposals) ++ " " ++
    "OR EXISTS(SELECT 1 FROM model_tool_call proposal WHERE proposal.operation_id=operation.operation_id))";

/// Whether the active Turn has an Operation that proposed calls: one row
/// stepped, so a Session with none pays only this seek, where main's
/// scope read cost as much.
const active_proposer = rsql.Read(.{
    .sql = "SELECT operation.operation_id " ++ active_proposers_sql,
    .Args = struct { session: []const u8 },
    .Row = struct { operation_id: rsql.Positive },
    .cardinality = .each,
});

/// The tool outcome rule (`reads.ToolOutcome`) over those Operations, for
/// the Current report and Session inspection, so the lists after it read
/// no Proposal.
const active_tool_calls = reads_domain.ToolOutcome("", "SELECT DISTINCT operation.operation_id," ++
    reads_domain.expectedCallsSql("operation.operation_id") ++ " " ++ active_proposers_sql, struct { session: []const u8 }, false);

/// The active Turn's Actions, as main counted them.
const action_count = rsql.Read(.{
    .sql = "SELECT count(*) AS actions FROM turn active @index(turn_one_active_per_session) " ++
        "CROSS JOIN model_operation operation @index(model_operation_turn_history) ON operation.turn_id=active.turn_id " ++
        "CROSS JOIN action_operation action ON action.parent_operation_id=operation.operation_id " ++
        "WHERE active.session_ref=?1 AND active.outcome_code IS NULL",
    .Args = struct { session: []const u8 },
    .Row = struct { actions: u64 },
    .cardinality = .each,
});

/// The active Turn's rejected calls, as main counted them.
const rejected_call_count = rsql.Read(.{
    .sql = "SELECT count(*) AS rejected FROM turn active @index(turn_one_active_per_session) " ++
        "CROSS JOIN model_operation operation @index(model_operation_turn_history) ON operation.turn_id=active.turn_id " ++
        "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=operation.operation_id " ++
        "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND tool_call.rejection_code IS NOT NULL",
    .Args = struct { session: []const u8 },
    .Row = struct { rejected: u64 },
    .cardinality = .each,
});

/// The names main gave `SessionCounts`' failed steps; the cutoff's is
/// the work's (`work_failures`).
pub const session_count_failures = .{
    .{ active_proposer, error.CallReadFailed },
    .{ active_tool_calls, error.CallReadFailed },
    .{ action_count, error.ActionReadFailed },
    .{ rejected_call_count, error.CallReadFailed },
    .{ command_domain.pending_messages, error.MessageAdmissionReadFailed },
};

/// What the Current report and Session inspection count, with the tool
/// outcome rule over the active Turn's calls (`active_tool_calls`). Round
/// 1 (`queue`) reads the latest stop's cutoff and whether the active Turn
/// proposed calls; round 2 (`queuePending`), in main's order, the
/// Messages pending after the cutoff, only when it proposed calls the
/// rule's rows, then the two counts, so a fault on a table both step
/// answers the rule's name, as on main. Each count steps its one row
/// once, as main's did. `judge` follows round 2, in the same order.
pub const SessionCounts = struct {
    session: []const u8,
    cutoff: reads_domain.First(command_domain.stop_cutoff.Row) = .{},
    proposer: reads_domain.First(active_proposer.Row) = .{},
    check: reads_domain.ToolOutcomeCheck = .{},
    actions: reads_domain.First(action_count.Row) = .{},
    rejected: reads_domain.First(rejected_call_count.Row) = .{},
    pending: reads_domain.First(command_domain.pending_messages.Row) = .{},

    pub const Counted = struct { pending: u64, actions: u64, rejected: u64 };

    pub fn queue(counts: *SessionCounts, a: *ReadAccess) void {
        a.readEach(command_domain.stop_cutoff, .{ .session = counts.session }, 1, &counts.cutoff);
        a.readEach(active_proposer, .{ .session = counts.session }, 1, &counts.proposer);
    }

    /// The latest stop's admission cutoff, 0 without a stop, once round 1
    /// ran.
    pub fn stopCutoff(counts: *const SessionCounts) u64 {
        return if (counts.cutoff.row) |row| row.admission_cutoff else 0;
    }

    pub fn queuePending(counts: *SessionCounts, a: *ReadAccess) void {
        a.readEach(command_domain.pending_messages, .{ .session = counts.session, .cutoff = counts.stopCutoff() }, 1, &counts.pending);
        if (counts.proposer.row != null) a.readEach(active_tool_calls, .{ .session = counts.session }, std.math.maxInt(u64), &counts.check);
        a.readEach(action_count, .{ .session = counts.session }, 1, &counts.actions);
        a.readEach(rejected_call_count, .{ .session = counts.session }, 1, &counts.rejected);
    }

    /// After round 2. An aggregate always has its row, so a missing one is
    /// the name main gave its failed step.
    pub fn judge(counts: *SessionCounts) !Counted {
        const pending = counts.pending.row orelse return error.MessageAdmissionReadFailed;
        try counts.check.finish();
        const actions = counts.actions.row orelse return error.ActionReadFailed;
        const rejected = counts.rejected.row orelse return error.CallReadFailed;
        return .{ .pending = pending.pending, .actions = actions.actions, .rejected = rejected.rejected };
    }
};

/// The Message the active Turn started from: an active Turn owns the
/// selection even if a successor is queued.
const selected_active = rsql.Read(.{
    .sql = "SELECT m.command_key FROM turn t @index(turn_one_active_per_session) JOIN message_admission m ON m.admission_id=t.first_admission_id " ++
        "WHERE t.session_ref=?1 AND t.outcome_code IS NULL",
    .Args = struct { session: []const u8 },
    .Row = SelectedRow,
    .cardinality = .each,
});

const SelectedRow = struct { command_key: protocol.Bounded(protocol.max_key_bytes) };

/// Without an active Turn, the oldest Message queued after the latest
/// stop's cutoff ?2.
const selected_queued = rsql.Read(.{
    .sql = "SELECT command_key FROM message_admission @index(message_admission_session_pending) " ++
        "WHERE session_ref=?1 AND turn_id IS NULL AND admission_id>?2 ORDER BY admission_id LIMIT 1",
    .Args = struct { session: []const u8, cutoff: u64 },
    .Row = SelectedRow,
    .cardinality = .each,
});

/// The ten newest Messages of terminal Turns. CROSS JOIN fixes the
/// indexed order, Turns newest first and then their admissions, so LIMIT
/// stops after ten Messages, even when older history or other Sessions
/// grow.
const recent_messages = rsql.Read(.{
    .sql = "SELECT t.turn_id,m.command_key,t.outcome_code FROM turn t @index(turn_session_latest) " ++
        "CROSS JOIN message_admission m @index(message_admission_session_order) " ++
        "WHERE t.session_ref=?1 AND t.outcome_code IS NOT NULL AND m.session_ref=t.session_ref AND m.turn_id=t.turn_id " ++
        "ORDER BY t.turn_id DESC,m.admission_id DESC LIMIT 10",
    .Args = struct { session: []const u8 },
    .Row = struct { turn_id: rsql.Positive, command_key: protocol.Bounded(protocol.max_key_bytes), outcome_code: Code },
    .cardinality = .each,
});

/// The active Turn's current Operation's unresolved Actions, with each
/// call's line for its presentation.
const unresolved_actions = rsql.Read(.{
    .sql = "SELECT a.action_id,a.parent_operation_id,a.call_ordinal,a.permission_revision,a.authorized,revision.permission_mode," ++
        "call_id.byte_length AS call_id_length,call_id.digest AS call_id_digest,arguments.byte_length AS arguments_length,arguments.digest AS arguments_digest," ++
        "tool_call.description FROM turn active @index(turn_one_active_per_session) " ++
        "CROSS JOIN action_operation a ON a.parent_operation_id=active.operation_id " ++
        "CROSS JOIN session_revision revision ON revision.session_ref=a.session_ref AND revision.revision=a.permission_revision " ++
        "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=a.parent_operation_id AND tool_call.call_ordinal=a.call_ordinal " ++
        "CROSS JOIN content call_id ON call_id.content_id=tool_call.call_id_content_id " ++
        "CROSS JOIN content arguments ON arguments.content_id=tool_call.arguments_content_id " ++
        "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND a.resolution_code IS NULL ORDER BY a.action_id",
    .Args = struct { session: []const u8 },
    .Row = struct {
        action_id: rsql.Positive,
        parent_operation_id: rsql.Positive,
        call_ordinal: u64,
        permission_revision: rsql.Positive,
        authorized: bool,
        permission_mode: u1,
        call_id_length: u64,
        call_id_digest: [32]u8,
        arguments_length: u64,
        arguments_digest: [32]u8,
        description: ?Description,
    },
    .cardinality = .each,
});

const Description = protocol.Bounded(protocol.max_tool_description_bytes);

/// The CTE `publications`: each active Operation's tool group
/// publication, as main's outcome facts gave it, its largest acceptance
/// when every call has one and none otherwise. Grouped once per
/// Operation, so a list joins it per row without rescanning the
/// Operation's calls. The rule over `active_tool_calls` proved every
/// call of each listed Operation valid in an earlier round of this
/// Access, under the Entry that excludes every writer, so its Operation
/// has as many calls as call items. By the schema's CHECKs a call has an
/// acceptance exactly when it is rejected (`model_tool_call`'s) or its
/// Action resolved (`action_operation`'s), main's terminal calls, so this
/// counts what main counted.
const publications_sql = "WITH publications AS (SELECT operation.operation_id," ++
    "CASE WHEN count(*)=count(coalesce(sibling.acceptance_position,sibling_action.acceptance_position)) " ++
    "THEN max(coalesce(sibling.acceptance_position,sibling_action.acceptance_position)) END AS publication " ++
    "FROM turn active @index(turn_one_active_per_session) " ++
    "CROSS JOIN model_operation operation @index(model_operation_turn_history) ON operation.turn_id=active.turn_id " ++
    "CROSS JOIN model_tool_call sibling ON sibling.operation_id=operation.operation_id " ++
    "LEFT JOIN action_operation sibling_action ON sibling_action.parent_operation_id=sibling.operation_id AND sibling_action.call_ordinal=sibling.call_ordinal " ++
    "WHERE active.session_ref=?1 AND active.outcome_code IS NULL GROUP BY operation.operation_id) ";

/// The active Turn's resolved Actions, with each call's line and its
/// group's publication for its presentation. An Action's call is its
/// foreign key.
const resolved_actions = rsql.Read(.{
    .sql = publications_sql ++ "SELECT a.action_id,a.parent_operation_id,a.call_ordinal,a.resolution_code,a.acceptance_position," ++
        "result.byte_length AS result_length,result.digest AS result_digest,tool_call.description,publications.publication " ++
        "FROM turn active @index(turn_one_active_per_session) " ++
        "CROSS JOIN model_operation operation @index(model_operation_turn_history) ON operation.turn_id=active.turn_id " ++
        "CROSS JOIN action_operation a ON a.parent_operation_id=operation.operation_id " ++
        "CROSS JOIN content result ON result.content_id=a.resolution_content_id " ++
        "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=a.parent_operation_id AND tool_call.call_ordinal=a.call_ordinal " ++
        "LEFT JOIN publications ON publications.operation_id=operation.operation_id " ++
        "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND a.resolution_code IS NOT NULL ORDER BY a.action_id",
    .Args = struct { session: []const u8 },
    .Row = struct {
        action_id: rsql.Positive,
        parent_operation_id: rsql.Positive,
        call_ordinal: u64,
        resolution_code: protocol.Bounded(32),
        acceptance_position: rsql.Positive,
        result_length: u64,
        result_digest: [32]u8,
        description: ?Description,
        publication: ?rsql.Positive,
    },
    .cardinality = .each,
});

/// The active Turn's rejected calls, with each one's line and its group's
/// publication for its presentation.
const rejected_calls = rsql.Read(.{
    .sql = publications_sql ++ "SELECT tool_call.operation_id,tool_call.call_ordinal,tool_call.rejection_code,tool_call.acceptance_position," ++
        "rejection.byte_length AS rejection_length,rejection.digest AS rejection_digest,name.byte_length AS name_length,name.digest AS name_digest," ++
        "call_id.byte_length AS call_id_length,call_id.digest AS call_id_digest,arguments.byte_length AS arguments_length,arguments.digest AS arguments_digest," ++
        "tool_call.description,publications.publication " ++
        "FROM turn active @index(turn_one_active_per_session) " ++
        "CROSS JOIN model_operation operation @index(model_operation_turn_history) ON operation.turn_id=active.turn_id " ++
        "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=operation.operation_id " ++
        "CROSS JOIN content name ON name.content_id=tool_call.name_content_id " ++
        "CROSS JOIN content call_id ON call_id.content_id=tool_call.call_id_content_id " ++
        "CROSS JOIN content arguments ON arguments.content_id=tool_call.arguments_content_id " ++
        "CROSS JOIN content rejection ON rejection.content_id=tool_call.rejection_content_id " ++
        "LEFT JOIN publications ON publications.operation_id=operation.operation_id " ++
        "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND tool_call.rejection_code IS NOT NULL " ++
        "ORDER BY tool_call.operation_id,tool_call.call_ordinal",
    .Args = struct { session: []const u8 },
    .Row = struct {
        operation_id: rsql.Positive,
        call_ordinal: u64,
        rejection_code: protocol.Bounded(32),
        acceptance_position: rsql.Positive,
        rejection_length: u64,
        rejection_digest: [32]u8,
        name_length: u64,
        name_digest: [32]u8,
        call_id_length: u64,
        call_id_digest: [32]u8,
        arguments_length: u64,
        arguments_digest: [32]u8,
        description: ?Description,
        publication: ?rsql.Positive,
    },
    .cardinality = .each,
});

/// The active Turn's current Operation's Actions awaiting permission.
const actionable_permissions = rsql.Read(.{
    .sql = "SELECT action.action_id,action.permission_revision FROM turn active @index(turn_one_active_per_session) " ++
        "JOIN action_operation action ON action.parent_operation_id=active.operation_id " ++
        "WHERE active.session_ref=?1 AND active.outcome_code IS NULL " ++
        "AND action.resolution_code IS NULL AND action.authorized=0 ORDER BY action.action_id",
    .Args = struct { session: []const u8 },
    .Row = struct { action_id: rsql.Positive, permission_revision: rsql.Positive },
    .cardinality = .each,
});

/// The names main gave the Current report's failed steps; any other is
/// `CorruptStore`, main's answer for content metadata. A presentation's
/// reads, which main named apart, are its list's own columns now, so
/// they take its list's name.
pub const current_failures = .{
    .{ selected_active, error.TurnReadFailed },
    .{ selected_queued, error.MessageAdmissionReadFailed },
    .{ recent_messages, error.TurnReadFailed },
    .{ unresolved_actions, error.ActionReadFailed },
    .{ resolved_actions, error.ActionReadFailed },
    .{ rejected_calls, error.CallReadFailed },
    .{ actionable_permissions, error.ActionReadFailed },
} ++ session_count_failures ++ model_admission_domain.compaction_failures ++ report_failures;

/// Ends a round of the Current report, naming a failed step by
/// `current_failures`.
fn runCurrent(a: *ReadAccess) !void {
    return store_access.runNamed(a, current_failures, error.CorruptStore);
}

/// What the Current report reads before its lists.
const CurrentFacts = struct {
    instructions: content_domain.content_metadata.Row = undefined,
    output_schema: content_domain.content_metadata.Row = undefined,
    counts: SessionCounts,
    compaction: model_admission_domain.CompactionRead,
    work: WorkRead,
    person: person_message.Result = null,
    first: FirstCandidates = .{},
    first_row: first_message.Result = null,
    active: reads_domain.First(SelectedRow) = .{},
    queued: reads_domain.First(SelectedRow) = .{},
    outcome: content_domain.content_metadata.Row = undefined,
};

/// The Current report after its saved Session, in the rounds its reads'
/// dependencies take. Round 2: the instructions' and output schema's
/// metadata, the counts' first round (`SessionCounts`), the latest Turn
/// for `context_estimate` (`CompactionRead`), the work's latest Turn, the
/// latest Message from no Session, both first-Message seeks and the
/// active Turn's Message. Round 3: the counts' second round, the queued Message
/// when no Turn is active, the work's second stage, the first Message's
/// row, the latest outcome's content metadata and the compaction facts'
/// next stage. The work's and compaction facts' later stages share the
/// rounds after it. Then each list, in a round of its own; the active
/// Turn's lists only when it counts an Action or rejected call to list.
/// Not inlined, so its reads take no slot in the Full profile's frames.
noinline fn renderCurrent(a: *ReadAccess, session_ref: []const u8, current: *const CurrentConfiguration, capture: *SessionReportCapture) !void {
    const policy = model_capability.compactionPolicy(current.model.slice(), current.compaction_trigger, current.output_reservation);
    var facts: CurrentFacts = .{
        .counts = .{ .session = session_ref },
        .compaction = .init(session_ref, current.next_position, current.provider, current.model.slice(), policy),
        .work = .{ .session = session_ref },
    };
    // `checkSaved` refused a missing or zero instructions id and a zero
    // output schema id. A negative id is `CorruptStore` without a read,
    // where main read it and found no row unless one had that id.
    const instructions_id = current.instructions_id.?;
    if (instructions_id < 0 or (current.output_schema_id orelse 1) < 0) return error.CorruptStore;
    const metadata = content_domain.content_metadata;
    a.read(metadata, .{ .content_id = @intCast(instructions_id) }, &facts.instructions);
    if (current.output_schema_id) |content_id| a.read(metadata, .{ .content_id = @intCast(content_id) }, &facts.output_schema);
    facts.counts.queue(a);
    _ = facts.compaction.queue(a);
    _ = facts.work.queue(a);
    a.read(person_message, .{ .session = session_ref }, &facts.person);
    facts.first.queue(a, session_ref);
    a.readEach(selected_active, .{ .session = session_ref }, 1, &facts.active);
    try runCurrent(a);
    try facts.compaction.advance();
    try facts.work.advance();

    facts.counts.queuePending(a);
    if (facts.active.row == null) a.readEach(selected_queued, .{ .session = session_ref, .cutoff = facts.counts.stopCutoff() }, 1, &facts.queued);
    const admission = facts.first.admission();
    if (admission != 0) a.read(first_message, .{ .session = session_ref, .first = admission }, &facts.first_row);
    // The work's latest Turn is read, so its outcome is known.
    const outcome = facts.work.outcome();
    if (outcome) |found| if (found.content_id) |content_id| a.read(metadata, .{ .content_id = content_id }, &facts.outcome);
    var work_more = facts.work.queue(a);
    var compaction_more = facts.compaction.queue(a);
    while (true) {
        try runCurrent(a);
        if (work_more) try facts.work.advance();
        if (compaction_more) try facts.compaction.advance();
        work_more = facts.work.queue(a);
        compaction_more = facts.compaction.queue(a);
        if (!work_more and !compaction_more) break;
    }
    const counted = try facts.counts.judge();
    if (admission != 0 and facts.first_row == null) return error.CorruptStore;

    try capture.append("{\"reference\":");
    try capture.appendJsonString(session_ref);
    try capture.append(",\"workspace\":");
    try capture.appendJsonString(current.workspace.slice());
    try capture.append(",\"provider\":");
    try capture.appendJsonString(@tagName(current.provider));
    try capture.append(",\"model\":");
    try capture.appendJsonString(current.model.slice());
    try capture.append(",\"compaction_trigger\":");
    try capture.appendFmt("\"{d}\"", .{policy.compaction_trigger});
    try capture.append(",\"context_estimate\":");
    if (turn_policy.comparedPressure(facts.compaction.facts)) |value| try capture.appendFmt("\"{d}\"", .{@min(value, std.math.maxInt(i64))}) else try capture.append("null");
    try capture.appendFmt(",\"output_reservation\":\"{d}\",\"compaction_trigger_override\":", .{policy.output_reservation});
    if (current.compaction_trigger) |value| try capture.appendFmt("\"{d}\"", .{value}) else try capture.append("null");
    try capture.append(",\"output_reservation_override\":");
    if (current.output_reservation) |value| try capture.appendFmt("\"{d}\"", .{value}) else try capture.append("null");
    try capture.append(",\"reasoning_effort\":");
    try appendNullableEffort(configuration_domain.effectiveReasoningEffort(current), capture);
    try capture.append(",\"reasoning_effort_override\":");
    try appendNullableEffort(current.reasoning_effort, capture);
    try capture.appendFmt(",\"revision\":\"{d}\",\"tools\":", .{current.revision});
    try capture.appendTools(current.tools_mask);
    try capture.append(",\"permission_mode\":");
    try capture.appendPermissionMode(current.permission_mode);
    try capture.append(",\"instructions\":");
    try capture.appendBareContentReference(.{ .length = facts.instructions.byte_length, .digest = facts.instructions.digest });
    try capture.append(",\"output_schema\":");
    if (current.output_schema_id != null) {
        try capture.appendBareContentReference(.{ .length = facts.output_schema.byte_length, .digest = facts.output_schema.digest });
    } else {
        try capture.append("null");
    }
    try capture.append(",\"label\":");
    if (current.label) |*label| try capture.appendJsonString(label.slice()) else try capture.append("null");
    try capture.appendFmt(",\"created_at\":\"{d}\"}},\"pending_messages\":\"{d}\",\"work\":", .{ current.created_at, counted.pending });
    const work: protocol.SessionWork = .fromCore(try facts.work.work(current.created_at, std.math.cast(u64, try store_core.readUnixMilliseconds(a.store.io)) orelse return error.IntegerOutOfRange));
    try capture.appendShape(.{"{"} ++ protocol.SessionWork.fields, work.args());
    if (outcome) |found| {
        try capture.append(",\"latest_outcome\":{\"code\":");
        try capture.appendJsonString(found.code);
        try capture.append(",\"content\":");
        if (found.content_id != null) {
            try capture.appendBareContentReference(.{ .length = facts.outcome.byte_length, .digest = facts.outcome.digest });
        } else {
            try capture.append("null");
        }
        try capture.append("}}");
    } else try capture.append(",\"latest_outcome\":null}");
    try capture.append(",\"peers\":");
    const peers: protocol.PeerFacts = .{ .from_person_at = if (facts.person) |found| found.admitted_at.get() else null };
    try capture.appendShape(.{protocol.Hole{ .json = protocol.PeerFacts }}, .{peers});
    try capture.append(",\"first_message\":");
    try capture.appendShape(.{protocol.Hole{ .optional_json = protocol.FirstMessage }}, .{if (facts.first_row) |*found| try firstMessage(found, admission) else null});
    try capture.append(",\"selected_message\":");
    if (facts.active.row orelse facts.queued.row) |selected| try capture.appendJsonString(selected.command_key.slice()) else try capture.append("null");
    try capture.append(",\"recent_messages\":[");
    try renderList(a, recent_messages, .{ .session = session_ref }, 10, renderRecent, capture);
    try capture.appendFmt("],\"actions\":{{\"count\":\"{d}\",\"unresolved\":[", .{counted.actions});
    if (counted.actions != 0) try renderList(a, unresolved_actions, .{ .session = session_ref }, std.math.maxInt(u64), renderUnresolved, capture);
    try capture.append("],\"resolved\":[");
    if (counted.actions != 0) try renderList(a, resolved_actions, .{ .session = session_ref }, std.math.maxInt(u64), renderResolved, capture);
    try capture.appendFmt("]}},\"rejected_calls\":{{\"count\":\"{d}\",\"items\":[", .{counted.rejected});
    if (counted.rejected != 0) try renderList(a, rejected_calls, .{ .session = session_ref }, std.math.maxInt(u64), renderRejected, capture);
    try capture.append("]},\"actionable_permissions\":[");
    if (counted.actions != 0) try renderList(a, actionable_permissions, .{ .session = session_ref }, std.math.maxInt(u64), renderActionable, capture);
    try capture.append("]");
}

/// One list of the Current report, in a round of its own, rendered as it
/// steps, so it keeps no row: `limit` bounds only a list whose text does.
/// A row that failed to render did before any later row's step failed,
/// so its error is main's first.
fn renderList(a: *ReadAccess, comptime S: type, args: S.Args, limit: u64, comptime renderRow: anytype, capture: *SessionReportCapture) !void {
    var render: ListRender(S.Row, renderRow) = .{ .capture = capture };
    a.readEach(S, args, limit, &render);
    const ran = runCurrent(a);
    if (render.failure) |err| return err;
    try ran;
}

/// Renders a list's rows, comma separated; after a failure it renders
/// nothing more.
fn ListRender(comptime Row: type, comptime renderRow: anytype) type {
    return struct {
        capture: *SessionReportCapture,
        first: bool = true,
        failure: ?Failure = null,

        const Failure = @typeInfo(@typeInfo(@TypeOf(renderRow)).@"fn".return_type.?).error_union.error_set;

        pub fn visit(render: *@This(), row: *const Row) bool {
            render.renderOne(row) catch |err| {
                render.failure = err;
                return false;
            };
            return true;
        }

        fn renderOne(render: *@This(), row: *const Row) Failure!void {
            if (!render.first) try render.capture.append(",");
            render.first = false;
            try renderRow(render.capture, row);
        }
    };
}

fn renderRecent(capture: *SessionReportCapture, row: *const recent_messages.Row) !void {
    try capture.appendFmt("{{\"turn\":\"{d}\",\"message\":", .{row.turn_id.get()});
    try capture.appendJsonString(row.command_key.slice());
    try capture.append(",\"outcome\":");
    try capture.appendJsonString(row.outcome_code.slice());
    try capture.append("}");
}

fn renderUnresolved(capture: *SessionReportCapture, row: *const unresolved_actions.Row) !void {
    // The insert authorizes every Action proposed under `bypass`.
    if (row.permission_mode == 1 and !row.authorized) return error.CorruptStore;
    try capture.appendFmt("{{\"action\":\"{d}\",\"parent_operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"tool\":\"bash\",\"permission_revision\":\"{d}\",\"authorization\":\"{s}\",\"call_id\":", .{
        row.action_id.get(),
        row.parent_operation_id.get(),
        row.call_ordinal,
        row.permission_revision.get(),
        if (!row.authorized) "pending" else if (row.permission_mode == 1) "bypass" else "allow_once",
    });
    try capture.appendContentReference(.{ .length = row.call_id_length, .digest = row.call_id_digest });
    try capture.append(",\"arguments\":");
    try capture.appendContentReference(.{ .length = row.arguments_length, .digest = row.arguments_digest });
    // Unresolved, and not rejected: the rule proved a call with an Action
    // has no rejection, so main's code, either one's, is none.
    try appendPresentation(capture, try reads_domain.presentationOf(row.description, null, row.authorized, null));
    try capture.append("}");
}

fn renderResolved(capture: *SessionReportCapture, row: *const resolved_actions.Row) !void {
    try capture.appendFmt("{{\"action\":\"{d}\",\"parent_operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"code\":", .{
        row.action_id.get(),
        row.parent_operation_id.get(),
        row.call_ordinal,
    });
    try capture.appendJsonString(row.resolution_code.slice());
    try capture.appendFmt(",\"acceptance_position\":\"{d}\",\"result\":", .{row.acceptance_position.get()});
    try capture.appendContentReference(.{ .length = row.result_length, .digest = row.result_digest });
    // Main's code was the rejection's, else the resolution's; the rule
    // proved a call with an Action has no rejection. A code decides the
    // outcome, so whether the Action was authorized is not weighed.
    try appendPresentation(capture, try reads_domain.presentationOf(row.description, try presentedCode(row.resolution_code.slice()), null, optional(row.publication)));
    try capture.append("}");
}

fn renderRejected(capture: *SessionReportCapture, row: *const rejected_calls.Row) !void {
    try capture.appendFmt("{{\"parent_operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"code\":", .{ row.operation_id.get(), row.call_ordinal });
    try capture.appendJsonString(row.rejection_code.slice());
    try capture.appendFmt(",\"acceptance_position\":\"{d}\",\"result\":", .{row.acceptance_position.get()});
    try capture.appendContentReference(.{ .length = row.rejection_length, .digest = row.rejection_digest });
    try capture.append(",\"name\":");
    try capture.appendContentReference(.{ .length = row.name_length, .digest = row.name_digest });
    try capture.append(",\"call_id\":");
    try capture.appendContentReference(.{ .length = row.call_id_length, .digest = row.call_id_digest });
    try capture.append(",\"arguments\":");
    try capture.appendContentReference(.{ .length = row.arguments_length, .digest = row.arguments_digest });
    // A code decides the outcome, so no authorization is weighed.
    try appendPresentation(capture, try reads_domain.presentationOf(row.description, try presentedCode(row.rejection_code.slice()), null, optional(row.publication)));
    try capture.append("}");
}

fn renderActionable(capture: *SessionReportCapture, row: *const actionable_permissions.Row) !void {
    try capture.appendFmt("{{\"action\":\"{d}\",\"permission_revision\":\"{d}\"}}", .{ row.action_id.get(), row.permission_revision.get() });
}

/// A stored outcome code as a presentation's: one it does not name is
/// `CorruptStore`, as main's decode answered.
fn presentedCode(code: []const u8) error{CorruptStore}!protocol.ToolPresentation.Code {
    return std.meta.stringToEnum(protocol.ToolPresentation.Code, code) orelse error.CorruptStore;
}

fn appendPresentation(capture: *SessionReportCapture, presentation: protocol.ToolPresentation) !void {
    var buffer: [protocol.ToolPresentation.max_json_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try presentation.writeJson(&writer);
    try capture.append(",\"presentation\":");
    try capture.append(writer.buffered());
}

/// The Session's latest Turn and its current Operation. The quota
/// diagnostic is read only for a failed outcome, and only while it is
/// small enough to be one (`Quota.max_bytes`).
const work_latest = rsql.Read(.{
    .sql = "SELECT t.turn_id,t.operation_id,t.input_cutoff,t.outcome_code,t.outcome_content_id,t.outcome_at,t.outcome_position," ++
        "coalesce(o.resolution_code,o.last_failure_code) AS operation_code,o.retry_due_at_ms,o.attempt_ordinal,o.attempt_at,o.retry_scheduled_at,o.resolved_at," ++
        "(SELECT payload FROM content WHERE content_id=o.resolution_content_id AND byte_length<=" ++ std.fmt.comptimePrint("{d}", .{Quota.max_bytes}) ++
        " AND t.outcome_code NOT IN ('completed','cancelled')) AS diagnostic," ++
        "(SELECT stopped_at FROM session_stop @index(session_stop_turn) WHERE selected_turn_id=t.turn_id ORDER BY position LIMIT 1) AS stopped_at " ++
        "FROM turn t @index(turn_session_latest) JOIN model_operation o ON o.operation_id=t.operation_id " ++
        "WHERE t.session_ref=?1 ORDER BY t.turn_id DESC LIMIT 1",
    .Args = struct { session: []const u8 },
    .Row = struct {
        turn_id: rsql.Positive,
        operation_id: rsql.Positive,
        input_cutoff: rsql.Positive,
        outcome_code: ?Code,
        outcome_content_id: ?rsql.Positive,
        outcome_at: ?rsql.Positive,
        outcome_position: ?rsql.Positive,
        /// The resolution once resolved, else the last failure's code:
        /// the schema's checks make a resolution exactly a `resolved_at`.
        operation_code: ?Code,
        retry_due_at_ms: ?u64,
        attempt_ordinal: ?rsql.Positive,
        attempt_at: ?rsql.Positive,
        retry_scheduled_at: ?rsql.Positive,
        resolved_at: ?rsql.Positive,
        /// Bytes `quotaResetsAt` parses; ones that are not UTF-8 give
        /// no reset time, as on main.
        diagnostic: ?rsql.Blob(Quota.max_bytes),
        stopped_at: ?rsql.Positive,
    },
    .cardinality = .each,
});

/// One aggregate over an active Turn's Operation's Actions, bounded by
/// its calls. On SQLite it renders as main's text, with column names.
const work_actions = rsql.Read(.{
    .sql = "SELECT count(*) AS total,@count_where(a.resolution_code IS NULL) AS unresolved," ++
        "@count_where(a.resolution_code IS NULL AND a.authorized=0) AS awaiting," ++
        "min(CASE WHEN a.resolution_code IS NULL AND a.authorized=0 THEN a.action_id END) AS first_awaiting," ++
        "@count_where(a.resolution_code IS NULL AND a.attempt_ordinal=1) AS running," ++
        // The last resolution is the one at the greatest position.
        "(SELECT resolved_at FROM action_operation WHERE parent_operation_id=?1 AND resolution_code IS NOT NULL ORDER BY acceptance_position DESC LIMIT 1) AS latest_resolution_at," ++
        // Under an `ask` revision only an `allow_once` decision
        // authorizes; under `bypass` the proposal did.
        "@max_where(a.decided_at,a.resolution_code IS NULL AND r.permission_mode=0) AS latest_decision_at " ++
        "FROM action_operation a LEFT JOIN session_revision r ON r.session_ref=a.session_ref AND r.revision=a.permission_revision " ++
        "WHERE a.parent_operation_id=?1",
    .Args = struct { operation: u64 },
    .Row = struct {
        total: u64,
        unresolved: u64,
        awaiting: u64,
        first_awaiting: ?rsql.Positive,
        running: u64,
        latest_resolution_at: ?rsql.Positive,
        latest_decision_at: ?rsql.Positive,
    },
    .cardinality = .each,
});

/// The oldest running Action's call ordinal and saved description.
const work_oldest = rsql.Read(.{
    .sql = "SELECT a.attempt_at,tool_call.description,a.call_ordinal FROM action_operation a " ++
        "JOIN model_tool_call tool_call ON tool_call.operation_id=a.parent_operation_id AND tool_call.call_ordinal=a.call_ordinal " ++
        "WHERE a.parent_operation_id=?1 AND a.resolution_code IS NULL AND a.attempt_ordinal=1 ORDER BY a.attempt_at,a.action_id LIMIT 1",
    .Args = struct { operation: u64 },
    .Row = struct { attempt_at: rsql.Positive, description: ?protocol.Bounded(protocol.max_tool_description_bytes), call_ordinal: u64 },
    .cardinality = .each,
});

/// The oldest Message queued after the cutoff ?2.
const work_queued = rsql.Read(.{
    .sql = "SELECT admitted_at,admission_position FROM message_admission @index(message_admission_session_pending) " ++
        "WHERE session_ref=?1 AND turn_id IS NULL AND admission_id>?2 ORDER BY admission_id LIMIT 1",
    .Args = struct { session: []const u8, cutoff: u64 },
    .Row = struct { admitted_at: rsql.Positive, admission_position: rsql.Positive },
    .cardinality = .each,
});

/// With nothing queued after the cutoff ?2: the newest Message a stop
/// excluded.
const work_excluded = rsql.Read(.{
    .sql = "SELECT admission_id FROM message_admission @index(message_admission_session_pending) " ++
        "WHERE session_ref=?1 AND turn_id IS NULL AND admission_id<=?2 ORDER BY admission_id DESC LIMIT 1",
    .Args = struct { session: []const u8, cutoff: u64 },
    .Row = struct { admission_id: rsql.Positive },
    .cardinality = .each,
});

/// The earliest stop that excluded the admission ?2.
const work_stop = rsql.Read(.{
    .sql = "SELECT position,stopped_at FROM session_stop @index(session_stop_exclusion) " ++
        "WHERE session_ref=?1 AND admission_cutoff>=?2 ORDER BY admission_cutoff,position LIMIT 1",
    .Args = struct { session: []const u8, admission: u64 },
    .Row = struct { position: rsql.Positive, stopped_at: rsql.Positive },
    .cardinality = .each,
});

/// The name main gave each work and list statement whose step fails;
/// any other is `CorruptStore`, as main's per-row reads answered.
pub const report_failures = .{
    .{ list_ceiling, error.SessionReadFailed },
    .{ list_page, error.SessionReadFailed },
    .{ workspace_list_page, error.SessionReadFailed },
    .{ workspace_key, error.SessionReadFailed },
    .{ first_bound, error.SessionReadFailed },
    .{ first_unbound, error.SessionReadFailed },
    .{ person_message, error.SessionReadFailed },
    .{ first_message, error.CorruptStore },
    .{ list_row, error.SessionReadFailed },
    .{ list_row_bare, error.SessionReadFailed },
} ++ work_failures;

/// The names main gave the work reads' failed steps.
pub const work_failures = .{
    .{ work_latest, error.TurnReadFailed },
    .{ work_actions, error.ActionReadFailed },
    .{ command_domain.stop_cutoff, error.SessionStopReadFailed },
    .{ work_queued, error.MessageAdmissionReadFailed },
    .{ work_excluded, error.MessageAdmissionReadFailed },
};

/// Ends a round of this file's reads, naming a failed step by
/// `report_failures`.
fn runReport(a: *ReadAccess) !void {
    return store_access.runNamed(a, report_failures, error.CorruptStore);
}

/// A Session's work now, read in the rounds its seeks depend on, none of
/// which reads history: its latest Turn; then an active Turn's Actions
/// and, only while one runs, the oldest running one; or else the latest
/// stop's cutoff, the oldest Message queued after it and, only when none
/// is but a stop cut off, the newest Message it excluded and that stop.
/// On SQLite each stage renders as main's statement with its columns
/// named, but `work_latest`, which folds main's two code columns into one
/// (`operation_code`). Many reads share each round (`readWorks`). List
/// rows, activity pages, Message progress and the Current report read
/// work here. Each stage reads one row, stepped once, as main did.
pub const WorkRead = struct {
    /// Read in place when each stage's pass steps it.
    session: []const u8,
    stage: Stage = .latest,
    count: reads_domain.RowCount = .{},
    /// What `session_work.derive` weighs, but its texts, which `work`
    /// points at this read's own copies.
    inputs: session_work.Inputs = .{ .now_ms = 0, .created_at = 0 },
    /// The latest Turn's outcome code, once it has one.
    code: Code = .{},
    outcome_content_id: ?u64 = null,
    /// A waiting Operation's failure code.
    cause: Code = .{},
    description: ?protocol.Bounded(protocol.max_tool_description_bytes) = null,
    cutoff: u64 = 0,

    const Stage = enum { latest, actions, oldest, cutoff, queued, excluded, stop, done };

    /// Queues this stage's read; false once the work is read.
    pub fn queue(w: *WorkRead, a: *ReadAccess) bool {
        switch (w.stage) {
            .latest => reads_domain.readFirst(a, work_latest, .{ .session = w.session }, w),
            .actions => reads_domain.readFirst(a, work_actions, .{ .operation = w.inputs.latest.?.operation_id }, w),
            .oldest => reads_domain.readFirst(a, work_oldest, .{ .operation = w.inputs.latest.?.operation_id }, w),
            .cutoff => reads_domain.readFirst(a, command_domain.stop_cutoff, .{ .session = w.session }, w),
            .queued => reads_domain.readFirst(a, work_queued, .{ .session = w.session, .cutoff = w.cutoff }, w),
            .excluded => reads_domain.readFirst(a, work_excluded, .{ .session = w.session, .cutoff = w.cutoff }, w),
            .stop => reads_domain.readFirst(a, work_stop, .{ .session = w.session, .admission = w.inputs.excluded.?.admission }, w),
            .done => return false,
        }
        return true;
    }

    pub fn visit(w: *WorkRead, row: anytype) bool {
        return reads_domain.visitRow(w, row);
    }

    /// After the round that ran this stage's read: judges what it found
    /// and picks the next stage.
    pub fn advance(w: *WorkRead) !void {
        const found = try w.count.found();
        w.stage = switch (w.stage) {
            .latest => if (found and w.inputs.latest.?.terminal == null) .actions else .cutoff,
            // An aggregate always has a row.
            .actions => if (!found) return error.ActionReadFailed else if (w.inputs.latest.?.actions.running != 0) .oldest else .done,
            .oldest, .stop => if (!found) return error.CorruptStore else .done,
            .cutoff => .queued,
            .queued => if (found or w.cutoff == 0) .done else .excluded,
            .excluded => if (found) .stop else .done,
            .done => .done,
        };
    }

    pub fn keep(w: *WorkRead, row: anytype) error{CorruptStore}!void {
        const Row = @TypeOf(row.*);
        if (Row == work_latest.Row) return w.keepLatest(row);
        if (Row == work_actions.Row) {
            const turn = &w.inputs.latest.?;
            turn.actions = .{
                .total = row.total,
                .unresolved = row.unresolved,
                .awaiting = row.awaiting,
                .first_awaiting = optional(row.first_awaiting),
                .running = row.running,
                .latest_resolution_at = optional(row.latest_resolution_at),
                .latest_decision_at = optional(row.latest_decision_at),
            };
        } else if (Row == work_oldest.Row) {
            w.description = row.description;
            w.inputs.latest.?.actions.oldest_running = .{ .at = row.attempt_at.get(), .call = row.call_ordinal, .description = null };
        } else if (Row == command_domain.stop_cutoff.Row) {
            w.cutoff = row.admission_cutoff;
        } else if (Row == work_queued.Row) {
            w.inputs.oldest_pending = .{ .at = row.admitted_at.get(), .position = row.admission_position.get() };
        } else if (Row == work_excluded.Row) {
            w.inputs.excluded = .{ .admission = row.admission_id.get(), .stop_position = undefined, .stop_at = undefined };
        } else if (Row == work_stop.Row) {
            const excluded = &w.inputs.excluded.?;
            excluded.stop_position = row.position.get();
            excluded.stop_at = row.stopped_at.get();
        } else @compileError("WorkRead reads no " ++ @typeName(Row));
    }

    fn keepLatest(w: *WorkRead, row: *const work_latest.Row) error{CorruptStore}!void {
        var turn: session_work.Inputs.Turn = .{
            .turn_id = row.turn_id.get(),
            .operation_id = row.operation_id.get(),
            .input_cutoff = row.input_cutoff.get(),
            .stopped_at = optional(row.stopped_at),
            .op = undefined,
        };
        if (row.resolved_at) |at| {
            const resolution = row.operation_code orelse return error.CorruptStore;
            turn.op = .{ .resolved = .{ .resolution = turn_policy.Resolution.parse(resolution.slice()), .at = at.get() } };
        } else if ((row.retry_due_at_ms orelse 0) == 0) {
            // NULL reads as 0, as main's integer read did.
            turn.op = .{ .in_flight = .{ .attempt_at = (row.attempt_at orelse return error.CorruptStore).get() } };
        } else {
            w.cause = row.operation_code orelse return error.CorruptStore;
            turn.op = .{ .waiting = .{
                .scheduled_at = (row.retry_scheduled_at orelse return error.CorruptStore).get(),
                .due_at_ms = row.retry_due_at_ms.?,
                .cause = "",
                .attempt = (row.attempt_ordinal orelse return error.CorruptStore).get(),
            } };
        }
        if (row.outcome_code) |*code| {
            w.code = code.*;
            w.outcome_content_id = optional(row.outcome_content_id);
            turn.terminal = .{
                .outcome = switch (try TurnOutcome.decode(code.slice(), if (row.outcome_content_id) |id| @intCast(id.get()) else null)) {
                    .completed => .completed,
                    .cancelled => .cancelled,
                    .retry_exhausted, .resource_exceeded, .failed => .failed,
                },
                .code = "",
                .at = (row.outcome_at orelse return error.CorruptStore).get(),
                .position = (row.outcome_position orelse return error.CorruptStore).get(),
                .resets_at = session_work.quotaResetsAt(code.slice(), if (row.diagnostic) |*bytes| bytes.slice() else null),
            };
        }
        w.inputs.latest = turn;
    }

    /// The latest Turn's outcome code and content, once it has one.
    pub fn outcome(w: *const WorkRead) ?struct { code: []const u8, content_id: ?u64 } {
        const turn = w.inputs.latest orelse return null;
        if (turn.terminal == null) return null;
        return .{ .code = w.code.slice(), .content_id = w.outcome_content_id };
    }

    /// The work these reads describe, for a Session created at
    /// `created_at`, as of `now_ms`.
    pub fn work(w: *const WorkRead, created_at: u64, now_ms: u64) error{CorruptStore}!session_work.Work {
        std.debug.assert(w.stage == .done);
        var inputs = w.inputs;
        inputs.created_at = created_at;
        inputs.now_ms = now_ms;
        if (inputs.latest) |*turn| {
            if (turn.terminal) |*terminal| terminal.code = w.code.slice();
            switch (turn.op) {
                .waiting => |*waiting| waiting.cause = w.cause.slice(),
                .in_flight, .resolved => {},
            }
            if (turn.actions.oldest_running) |*running| running.description = if (w.description) |*text| text.slice() else null;
        }
        return session_work.derive(inputs);
    }
};

fn optional(value: ?rsql.Positive) ?u64 {
    return if (value) |positive| positive.get() else null;
}

/// Reads every `works` to its end, each stage of every one in a shared
/// round, so the rounds are the deepest work's stages, not the count.
/// Reads its caller queued before it share its first round, which runs
/// only while some work is not `.done`; with none, it runs no round.
pub fn readWorks(a: *ReadAccess, works: []WorkRead) !void {
    while (true) {
        var queued = false;
        for (works) |*w| queued = w.queue(a) or queued;
        if (!queued) return;
        try runReport(a);
        for (works) |*w| try w.advance();
    }
}

/// The Full profile's history, after the Current facts, on the report's
/// Access, in output order: the revisions (`renderRevisions`), then the
/// other lists in runs (`renderRun`).
pub fn renderFull(a: *ReadAccess, session_ref: []const u8, capture: *SessionReportCapture) !void {
    try capture.append(",\"full\":{\"session_revisions\":[");
    try renderRevisions(a, session_ref, capture);
    try renderRun(a, .{Messages}, session_ref, capture);
    try renderRun(a, .{ Conversation, Turns, Operations }, session_ref, capture);
    try renderRun(a, .{Calls}, session_ref, capture);
    try renderRun(a, .{Actions}, session_ref, capture);
    try renderRun(a, .{ Decisions, Stops, Interruptions, Results }, session_ref, capture);
    try capture.append("]}");
}

/// The rows a Full list renders per chunk. Each list's text reads one row
/// more (`chunk_limit`), so a list of at most this many rows without
/// inline content takes one statement, and each further `chunk_rows`
/// rows take one more.
const chunk_rows = 256;
const chunk_limit = std.fmt.comptimePrint(" LIMIT {d}", .{chunk_rows + 1});

/// The hooks a list without them declares: no state, no check, and no
/// first read.
pub const NoState = struct {};
pub fn noCheck(_: *NoState, _: anytype) error{}!void {}
pub const NoFirst = struct {};
pub fn noQueueFirst(_: *ReadAccess, _: []const u8, _: *NoFirst) void {}
pub fn noCheckFirst(_: *const NoFirst) error{}!void {}
pub fn streamsNever(_: anytype) bool {
    return false;
}

/// Where a list stands in its run (`renderRun`), as the lists after it in
/// the same pass need to know.
const ListStatus = struct {
    previous: ?*const ListStatus,
    /// Every row rendered, in an earlier round.
    done: bool = false,
    /// This round read the list.
    queued: bool = false,
    /// This round's chunk saw a row past it, kept a row for after the
    /// round, or failed.
    more: bool = false,
    kept: bool = false,
    failed: bool = false,
    /// A round read the list ahead and found no row: it is not read
    /// again.
    empty: bool = false,

    /// Whether every row of the list is rendered once this round's pass
    /// reaches the list after it: done before, or read in this round
    /// after every list before it finished, with no row past its chunk
    /// and none kept.
    fn finished(list: *const ListStatus) bool {
        if (list.done) return true;
        return list.queued and list.previousFinished() and !list.more and !list.kept and !list.failed;
    }

    fn previousFinished(list: *const ListStatus) bool {
        return if (list.previous) |previous| previous.finished() else true;
    }
};

/// A run's headers, which each list opens in order before its first row,
/// or after its round when it has none.
const Headers = struct {
    capture: *SessionReportCapture,
    texts: []const []const u8,
    opened: usize = 0,

    fn open(headers: *Headers, list: usize) !void {
        while (headers.opened <= list) : (headers.opened += 1) try headers.capture.append(headers.texts[headers.opened]);
    }
};

/// One round's chunk of a Full list (`renderRun`). `L` declares, all
/// required:
/// - `S`, its statement, whose Args are the Session and the key after
///   which a chunk starts, 0 before the first;
/// - `after(session, row)`, the Args of the chunk after `row`;
/// - `failed`, the name main gave its statement's failed step;
/// - `header`, the text that opens the list;
/// - `kept_rows`, how many rows a chunk keeps for after its round: the
///   first row that shows content whole (`streams(row)`) and every row
///   after it in the chunk, since rows render in order;
/// - `render(a, capture, row)`, which streams the row's inline content;
/// - `State` and `check(state, row)`, run for every row in order;
/// - `First`, `queueFirst` and `checkFirst`: a read the list's first
///   round queues before it, judged before any of its rows' failures.
/// `NoState`, `noCheck`, `NoFirst`, `noQueueFirst`, `noCheckFirst` and
/// `streamsNever` are the hooks of a list that has none.
fn Chunk(comptime L: type) type {
    return struct {
        const Row = L.S.Row;
        const Failure = @typeInfo(@typeInfo(@TypeOf(L.render)).@"fn".return_type.?).error_union.error_set ||
            @typeInfo(@typeInfo(@TypeOf(L.check)).@"fn".return_type.?).error_union.error_set ||
            SessionReportCapture.AppendError;

        a: *ReadAccess,
        capture: *SessionReportCapture,
        headers: *Headers,
        list: usize,
        first: *bool,
        state: *L.State,
        status: *ListStatus,
        after: L.S.Args,
        rows: u16 = 0,
        /// Whether every list before it in the run finished, judged at
        /// the chunk's first row.
        ready: ?bool = null,
        kept: [L.kept_rows]Row = undefined,
        count: u8 = 0,
        failure: ?Failure = null,

        /// Takes `row` once every list before it finished, unless the
        /// chunk is full, of rows or of kept rows: then `row` is the next
        /// chunk's first, and the chunk stops. Before every list before
        /// it finished, it stops at its first row and takes nothing.
        pub fn visit(chunk: *@This(), row: *const Row) bool {
            const ready = chunk.ready orelse chunk.status.previousFinished();
            chunk.ready = ready;
            if (!ready) return false;
            if (chunk.rows == chunk_rows or (L.kept_rows != 0 and chunk.count == L.kept_rows)) {
                chunk.status.more = true;
                return false;
            }
            chunk.rows += 1;
            chunk.after = L.after(chunk.after.session, row);
            chunk.take(row) catch |err| {
                chunk.failure = err;
                chunk.status.failed = true;
                return false;
            };
            return true;
        }

        /// Renders `row` in the pass, unless it or a row before it in
        /// this chunk shows content whole: then keeps it, in order.
        fn take(chunk: *@This(), row: *const Row) Failure!void {
            try L.check(chunk.state, row);
            if (L.kept_rows == 0 or (chunk.count == 0 and !L.streams(row))) return chunk.render(row);
            chunk.kept[chunk.count] = row.*;
            chunk.count += 1;
            chunk.status.kept = true;
        }

        fn render(chunk: *@This(), row: *const Row) Failure!void {
            try chunk.headers.open(chunk.list);
            if (!chunk.first.*) try chunk.capture.append(",");
            chunk.first.* = false;
            try L.render(chunk.a, chunk.capture, row);
        }
    };
}

/// A list's place in its run across rounds.
fn ListRun(comptime L: type) type {
    return struct {
        state: L.State = .{},
        first: bool = true,
        after: L.S.Args,
        status: ListStatus,
        /// The chunk read this round, and the first read with it.
        chunk: Chunk(L) = undefined,
        first_read: L.First = undefined,
        first_queued: bool = false,
        /// Whether `checkFirst` passed, in the round that rendered the
        /// list's first rows.
        begun: bool = false,
    };
}

fn RunState(comptime Ls: anytype) type {
    var types: [Ls.len]type = undefined;
    for (Ls, 0..) |L, i| types[i] = ListRun(L);
    const list = types;
    return @Tuple(&list);
}

/// What a failed round of run `Ls` can answer (`runFailure`).
fn RunError(comptime Ls: anytype) type {
    var set = @typeInfo(@typeInfo(@TypeOf(ReadAccess.run)).@"fn".return_type.?).error_union.error_set;
    for (Ls) |L| set = set || @TypeOf(L.failed) || Chunk(L).Failure ||
        @typeInfo(@typeInfo(@TypeOf(L.checkFirst)).@"fn".return_type.?).error_union.error_set;
    return set;
}

/// Renders lists `Ls` in order, each in keyset chunks, a round per chunk.
/// A list's chunk renders its rows as the pass steps them, so the next
/// list's rows can render in the same pass only once it finished: every
/// list but the last keeps no rows (`kept_rows` 0), and each round reads
/// the first list not done and the first chunk of each list after it.
/// A list reached before the lists ahead of it finished takes one row
/// and nothing from it, and is read again, its first read not; one with
/// no row is not read again. That happens only after a list of more than
/// `chunk_rows` rows. After the round, each finished
/// list's kept rows render with their content. A failed step answers the
/// name of the list whose statement failed; a step failure of a list
/// read ahead answers before the content of the lists before it.
/// Not inlined, so each run's kept rows take only their own chain.
pub noinline fn renderRun(a: *ReadAccess, comptime Ls: anytype, session_ref: []const u8, capture: *SessionReportCapture) !void {
    comptime for (0..Ls.len - 1) |i| std.debug.assert(Ls[i].kept_rows == 0);
    const texts = comptime blk: {
        var list: [Ls.len][]const u8 = undefined;
        for (Ls, 0..) |L, i| list[i] = L.header;
        const result = list;
        break :blk result;
    };
    var headers: Headers = .{ .capture = capture, .texts = &texts };
    var lists: RunState(Ls) = undefined;
    inline for (0..Ls.len) |i| lists[i] = .{
        .after = .{ .session = session_ref },
        .status = .{ .previous = if (i == 0) null else &lists[i - 1].status },
    };
    var current: usize = 0;
    while (current < Ls.len) {
        inline for (Ls, 0..) |L, i| if (i >= current and !lists[i].status.empty) {
            const list = &lists[i];
            list.status.queued = true;
            list.status.more = false;
            list.status.kept = false;
            list.status.failed = false;
            if (!list.begun and !list.first_queued) {
                L.queueFirst(a, session_ref, &list.first_read);
                list.first_queued = true;
            }
            list.chunk = .{ .a = a, .capture = capture, .headers = &headers, .list = i, .first = &list.first, .state = &list.state, .status = &list.status, .after = list.after };
            a.readEach(L.S, list.after, chunk_rows + 1, &list.chunk);
        };
        a.run() catch |err| return runFailure(a, Ls, &lists, current, err);
        var blocked = false;
        inline for (Ls, 0..) |L, i| if (i >= current) {
            const list = &lists[i];
            if (blocked or !list.status.previousFinished()) {
                // Read ahead of a list not finished: read again, unless it
                // has no row. The snapshot is the report's, so its first
                // read stands.
                blocked = true;
                if (list.chunk.ready == null) list.status.empty = true;
            } else {
                if (!list.begun) {
                    try L.checkFirst(&list.first_read);
                    list.begun = true;
                }
                if (list.chunk.failure) |err| return err;
                try headers.open(i);
                for (list.chunk.kept[0..list.chunk.count]) |*row| try list.chunk.render(row);
                list.after = list.chunk.after;
                if (list.status.more) {
                    blocked = true;
                    current = i;
                } else {
                    list.status.done = true;
                    current = i + 1;
                }
            }
        };
    }
}

/// The answer to a failed round of a run: the lists before the one whose
/// statement failed answer their first read's check and their rows'
/// failures first, as main reached them first; the failed list answers
/// its rows' failure, else its name.
fn runFailure(a: *const ReadAccess, comptime Ls: anytype, lists: *RunState(Ls), current: usize, err: RunError(Ls)) RunError(Ls) {
    if (err != error.StatementFailed) return err;
    var failed: ?usize = null;
    inline for (Ls, 0..) |L, i| if (failed == null and i >= current) {
        if (a.failedOn(L.S) or failedOnFirst(a, L)) failed = i;
    };
    const index = failed orelse return err;
    inline for (Ls, 0..) |L, i| if (i >= current and i <= index) {
        const list = &lists[i];
        if (i == index) return list.chunk.failure orelse L.failed;
        if (!list.begun) L.checkFirst(&list.first_read) catch |check| return check;
        if (list.chunk.failure) |row| return row;
    };
    unreachable;
}

/// Whether list `L`'s first read recorded the round's failure.
fn failedOnFirst(a: *const ReadAccess, comptime L: type) bool {
    return if (L.First == NoFirst) false else a.failedOn(L.FirstRead);
}

/// A content value a Full row shows whole, with the metadata its row
/// joined; `streamInline` reads it.
const InlineValue = struct { id: u64, length: u64, digest: [32]u8 };

/// A content value's id and joined metadata, as a row decodes them: no
/// id is none, and an id without metadata names no content row.
fn optionalValue(id: ?rsql.Positive, length: ?u64, digest: ?[32]u8) error{CorruptStore}!?InlineValue {
    const content_id = id orelse return null;
    return .{ .id = content_id.get(), .length = length orelse return error.CorruptStore, .digest = digest orelse return error.CorruptStore };
}

/// Shows `value` whole: its metadata, then its text, which
/// `content.streamVerified` reads and checks.
fn streamInline(a: *ReadAccess, capture: *SessionReportCapture, value: InlineValue) !void {
    try capture.appendFmt("{{\"type\":\"text\",\"bytes\":\"{d}\",\"sha256\":\"", .{value.length});
    try capture.append(&std.fmt.bytesToHex(value.digest, .lower));
    try capture.append("\",\"text\":\"");
    const Sink = struct {
        capture: *SessionReportCapture,
        pub fn write(sink: @This(), bytes: []const u8) !void {
            try sink.capture.appendJsonStringBytes(bytes);
        }
    };
    try content_domain.streamVerified(a, value.id, .{ .length = value.length, .digest = value.digest }, Sink{ .capture = capture });
    try capture.append("\"}");
}

/// Where a revision's content value first occurs in its Session: the
/// revision, and the field within it, instructions before output schema.
pub const ContentOwner = struct {
    revision: u64,
    field: RevisionContentField,

    /// One integer that orders owners as they occur.
    fn slot(owner: ContentOwner) u64 {
        return owner.revision * 2 + @as(u64, @intCast(@backingInt(owner.field)));
    }

    fn ofSlot(value: u64) ContentOwner {
        return .{ .revision = value / 2, .field = if (value % 2 == 0) .instructions else .output_schema };
    }
};

/// The owner of each content value the revisions listed so far hold, by
/// content id: an open-addressing table in pages of its own
/// (`pages.mapZeroed`), so no frame holds it, mapped for one report and
/// doubled whenever it is half full. It holds every value the Session's
/// revisions hold, as main's ownership statement sorted them, so each
/// lookup and insertion is one probe sequence however many revisions
/// there are. Revisions list in order, so a value not found here occurs
/// first in the row that holds it.
pub const ContentOwners = struct {
    pub const initial_capacity = 1024;

    /// `id` 0 is an empty entry: content ids are positive.
    const Entry = struct { id: u64, slot: u64 };

    entries: []Entry,
    count: usize = 0,

    fn map() error{SessionReadFailed}!ContentOwners {
        return .{ .entries = pages.mapZeroed(Entry, initial_capacity) catch return error.SessionReadFailed };
    }

    fn unmap(owners: *ContentOwners) void {
        pages.unmapZeroed(owners.entries);
    }

    /// The entry holding `id`, or the empty one where it would go.
    fn probe(entries: []Entry, id: u64) *Entry {
        var at: usize = @intCast((id *% 0x9E3779B97F4A7C15) >> 32 & (entries.len - 1));
        while (entries[at].id != 0 and entries[at].id != id) at = (at + 1) & (entries.len - 1);
        return &entries[at];
    }

    fn find(owners: *const ContentOwners, id: u64) ?ContentOwner {
        const entry = probe(owners.entries, id);
        return if (entry.id == id) .ofSlot(entry.slot) else null;
    }

    /// Adds `id`, which it does not hold, doubling the table first when
    /// the addition would fill it past half.
    fn add(owners: *ContentOwners, id: u64, owner: ContentOwner) error{SessionReadFailed}!void {
        if (2 * (owners.count + 1) > owners.entries.len) {
            const grown = pages.mapZeroed(Entry, 2 * owners.entries.len) catch return error.SessionReadFailed;
            for (owners.entries) |entry| if (entry.id != 0) {
                probe(grown, entry.id).* = entry;
            };
            pages.unmapZeroed(owners.entries);
            owners.entries = grown;
        }
        probe(owners.entries, id).* = .{ .id = id, .slot = owner.slot() };
        owners.count += 1;
    }
};

/// A revision row. `newest` is the Session's last revision, so a chunk
/// that stops after a row knows whether another follows without reading
/// it.
const RevisionRow = struct {
    revision: rsql.Positive,
    newest: rsql.Positive,
    command_key: protocol.Bounded(128),
    workspace: protocol.Bounded(protocol.max_workspace_bytes),
    provider: protocol.Provider,
    model: protocol.Bounded(protocol.max_model_bytes),
    compaction_trigger: ?rsql.Positive,
    output_reservation: ?u64,
    reasoning_effort: ?protocol.ReasoningEffort,
    label: ?protocol.Bounded(protocol.max_label_bytes),
    tools_mask: u8,
    permission_mode: u8,
    instructions_id: rsql.Positive,
    instructions_length: u64,
    instructions_digest: [32]u8,
    output_schema_id: ?rsql.Positive,
    output_schema_length: ?u64,
    output_schema_digest: ?[32]u8,
};

/// The Session's revisions after ?2, by `revision`, with each content's
/// metadata; `ContentOwners` names the owners.
pub const full_revisions = rsql.Read(.{
    .sql = "SELECT r.revision,(SELECT max(revision) FROM session_revision WHERE session_ref=?1) AS newest,r.command_key,r.workspace,r.provider,r.model," ++
        "r.compaction_trigger,r.output_reservation,r.reasoning_effort,r.label,r.tools_mask,r.permission_mode," ++
        "r.instructions_content_id AS instructions_id,instructions.byte_length AS instructions_length,instructions.digest AS instructions_digest," ++
        "r.output_schema_content_id AS output_schema_id,output_schema.byte_length AS output_schema_length,output_schema.digest AS output_schema_digest " ++
        "FROM session_revision r LEFT JOIN content instructions ON instructions.content_id=r.instructions_content_id " ++
        "LEFT JOIN content output_schema ON output_schema.content_id=r.output_schema_content_id " ++
        "WHERE r.session_ref=?1 AND r.revision>?2 ORDER BY r.revision" ++ chunk_limit,
    .Args = struct { session: []const u8, after: u64 = 0 },
    .Row = RevisionRow,
    .cardinality = .each,
});

/// A revision's content, as its row shows it: whole where the revision
/// owns it, else a reference to its owner.
const RevisionContent = struct {
    value: InlineValue,
    owner: ContentOwner,
    owned: bool,

    fn of(value: InlineValue, owner: ContentOwner, here: ContentOwner) RevisionContent {
        return .{ .value = value, .owner = owner, .owned = owner.slot() == here.slot() };
    }

    /// Inline, so streaming adds no frame between the revisions' and
    /// `content.streamVerified`'s.
    inline fn render(content: *const RevisionContent, a: *ReadAccess, capture: *SessionReportCapture) !void {
        if (content.owned) return streamInline(a, capture, content.value);
        try content.renderReference(capture);
    }

    /// Not inlined: its formatting takes no frame on the streaming chain.
    noinline fn renderReference(content: *const RevisionContent, capture: *SessionReportCapture) !void {
        try capture.appendOwnedContentReference(.{ .length = content.value.length, .digest = content.value.digest }, @intCast(content.owner.revision), content.owner.field);
    }
};

/// What follows a revision's settings: its instructions and output schema.
const RevisionTail = struct {
    instructions: RevisionContent,
    output_schema: ?RevisionContent,

    fn render(tail: *const RevisionTail, a: *ReadAccess, capture: *SessionReportCapture) !void {
        try capture.append(",\"instructions\":");
        try tail.instructions.render(a, capture);
        try capture.append(",\"output_schema\":");
        if (tail.output_schema) |*content| try content.render(a, capture) else try capture.append("null");
        try capture.append("}");
    }

    /// Whether the tail reads content: an owned value of at least a byte.
    fn streams(tail: *const RevisionTail) bool {
        const instructions = tail.instructions.owned and tail.instructions.value.length != 0;
        const output_schema = if (tail.output_schema) |content| content.owned and content.value.length != 0 else false;
        return instructions or output_schema;
    }
};

/// Renders the revisions as their chunks step: each row's settings, then
/// its contents, which wait for the round's end when the row reads one
/// (`RevisionTail.streams`), so the chunk stops after that row and its
/// next starts after it. A row holds a workspace of up to 4 KiB, so only
/// that tail is kept.
const RevisionChunk = struct {
    a: *ReadAccess,
    capture: *SessionReportCapture,
    owners: *ContentOwners,
    first: bool,
    after: u64,
    rows: u16 = 0,
    more: bool = false,
    tail: ?RevisionTail = null,
    failure: ?Failure = null,
    decoded: RevisionRow = undefined,

    const Failure = SessionReportCapture.AppendError || error{ ReportEncodingFailed, CorruptStore, SessionReadFailed } ||
        @typeInfo(@typeInfo(@TypeOf(RevisionTail.render)).@"fn".return_type.?).error_union.error_set;

    pub fn visit(chunk: *RevisionChunk, row: *const RevisionRow) bool {
        if (chunk.rows == chunk_rows) {
            chunk.more = true;
            return false;
        }
        const tail = chunk.take(row) catch |err| {
            chunk.failure = err;
            return false;
        };
        chunk.rows += 1;
        chunk.after = row.revision.get();
        if (!tail.streams()) {
            tail.render(chunk.a, chunk.capture) catch |err| {
                chunk.failure = err;
                return false;
            };
            return true;
        }
        chunk.tail = tail;
        chunk.more = row.revision.get() < row.newest.get();
        return false;
    }

    /// Renders `row`'s settings and returns its tail.
    fn take(chunk: *RevisionChunk, row: *const RevisionRow) Failure!RevisionTail {
        const revision = row.revision.get();
        const instructions_here: ContentOwner = .{ .revision = revision, .field = .instructions };
        const output_schema_here: ContentOwner = .{ .revision = revision, .field = .output_schema };
        const instructions: InlineValue = .{ .id = row.instructions_id.get(), .length = row.instructions_length, .digest = row.instructions_digest };
        const output_schema = try optionalValue(row.output_schema_id, row.output_schema_length, row.output_schema_digest);
        const instructions_owner = try chunk.ownerOf(instructions.id, instructions_here);
        const output_schema_content: ?RevisionContent = if (output_schema) |value| .of(value, try chunk.ownerOf(value.id, output_schema_here), output_schema_here) else null;
        try chunk.renderSettings(row);
        return .{ .instructions = .of(instructions, instructions_owner, instructions_here), .output_schema = output_schema_content };
    }

    /// The owner of content `id` at `here`: from `ContentOwners`, else
    /// `here`, which it then adds.
    fn ownerOf(chunk: *RevisionChunk, id: u64, here: ContentOwner) error{SessionReadFailed}!ContentOwner {
        if (chunk.owners.find(id)) |owner| return owner;
        try chunk.owners.add(id, here);
        return here;
    }

    fn renderSettings(chunk: *RevisionChunk, row: *const RevisionRow) (SessionReportCapture.AppendError || error{ ReportEncodingFailed, CorruptStore })!void {
        const capture = chunk.capture;
        if (!chunk.first) try capture.append(",");
        chunk.first = false;
        try capture.appendFmt("{{\"revision\":\"{d}\",\"command_key\":", .{row.revision.get()});
        try capture.appendJsonString(row.command_key.slice());
        try capture.append(",\"workspace\":");
        try capture.appendJsonString(row.workspace.slice());
        try capture.append(",\"provider\":");
        try capture.appendJsonString(@tagName(row.provider));
        try capture.append(",\"model\":");
        try capture.appendJsonString(row.model.slice());
        try capture.append(",\"compaction_trigger\":");
        try appendOptionalPositive(row.compaction_trigger, capture);
        try capture.append(",\"output_reservation\":");
        if (row.output_reservation) |value| try capture.appendFmt("\"{d}\"", .{value}) else try capture.append("null");
        try capture.append(",\"reasoning_effort\":");
        try appendNullableEffort(row.reasoning_effort, capture);
        try capture.append(",\"label\":");
        if (row.label) |*label| {
            try configuration_domain.checkLabel(label.slice());
            try capture.appendJsonString(label.slice());
        } else try capture.append("null");
        try capture.append(",\"tools\":");
        try capture.appendTools(row.tools_mask);
        try capture.append(",\"permission_mode\":");
        try capture.appendPermissionMode(row.permission_mode);
    }
};

/// The revisions list (`RevisionChunk`), whose step failure is main's
/// `SessionReadFailed`, as is a failed map of `ContentOwners`' pages.
/// Not inlined: its chunk holds a decoded row.
noinline fn renderRevisions(a: *ReadAccess, session_ref: []const u8, capture: *SessionReportCapture) !void {
    var owners: ContentOwners = try .map();
    defer owners.unmap();
    var first = true;
    var after: u64 = 0;
    while (true) {
        var chunk: RevisionChunk = .{ .a = a, .capture = capture, .owners = &owners, .first = first, .after = after };
        a.readEach(full_revisions, .{ .session = session_ref, .after = after }, chunk_rows + 1, &chunk);
        const ran = store_access.runAs(a, error.SessionReadFailed);
        if (chunk.failure) |err| return err;
        try ran;
        if (chunk.tail) |*tail| try tail.render(a, capture);
        if (!chunk.more) return;
        first = chunk.first;
        after = chunk.after;
    }
}

/// The Session's Messages, by `admission_position` and then id, each
/// with its content, its Turn's outcome and, for one no Turn took, the
/// stop with the least cutoff that reaches it, the first by position
/// among equal cutoffs. Main walked the stops in command order and took
/// the first that reaches it: the same stop, since a stop's cutoff is its
/// Session's newest admission when it commits and its position is claimed
/// in that commit, so neither falls in command order. Nothing checks this
/// at run time. The seek (`session_stop_exclusion`) keeps the work linear
/// in Messages and stops.
pub const full_messages = rsql.Read(.{
    .sql = "SELECT m.admission_position,m.admission_id,m.command_key,m.content_id,input.byte_length AS content_length,input.digest AS content_digest," ++
        "m.turn_id,t.operation_id,o.attempt_ordinal,t.outcome_code,t.outcome_content_id,outcome.byte_length AS outcome_length,outcome.digest AS outcome_digest," ++
        "CASE WHEN m.turn_id IS NULL THEN (SELECT stopped.command_key FROM session_stop stopped " ++
        "WHERE stopped.session_ref=m.session_ref AND stopped.admission_cutoff>=m.admission_id " ++
        "ORDER BY stopped.admission_cutoff,stopped.position LIMIT 1) END AS excluding_stop " ++
        "FROM message_admission m @index(message_admission_position) LEFT JOIN content input ON input.content_id=m.content_id " ++
        "LEFT JOIN turn t ON t.turn_id=m.turn_id LEFT JOIN model_operation o ON o.operation_id=t.operation_id " ++
        "LEFT JOIN content outcome ON outcome.content_id=t.outcome_content_id " ++
        "WHERE m.session_ref=?1 AND m.admission_position>=?2 AND (m.admission_position>?2 OR m.admission_id>?3) " ++
        "ORDER BY m.admission_position,m.admission_id" ++ chunk_limit,
    .Args = struct { session: []const u8, position: u64 = 0, admission: u64 = 0 },
    .Row = struct {
        admission_position: rsql.Positive,
        admission_id: rsql.Positive,
        command_key: protocol.Bounded(128),
        content_id: rsql.Positive,
        content_length: u64,
        content_digest: [32]u8,
        turn_id: ?rsql.Positive,
        operation_id: ?rsql.Positive,
        attempt_ordinal: ?rsql.Positive,
        outcome_code: ?protocol.Bounded(protocol.max_code_bytes),
        outcome_content_id: ?rsql.Positive,
        outcome_length: ?u64,
        outcome_digest: ?[32]u8,
        excluding_stop: ?protocol.Bounded(128),
    },
    .cardinality = .each,
});

/// Whether the Session has a Message without a position, which a list by
/// position would leave out.
const unpositioned_message = rsql.Read(.{
    .sql = "SELECT 1 AS found FROM message_admission @index(message_admission_unpositioned) WHERE session_ref=?1 AND admission_position IS NULL LIMIT 1",
    .Args = struct { session: []const u8 },
    .Row = struct { found: bool },
    .cardinality = .optional,
});

pub const Messages = struct {
    const S = full_messages;
    const failed = error.MessageReadFailed;
    const header = "],\"messages\":[";
    pub const kept_rows = 4;
    pub const First = unpositioned_message.Result;
    const FirstRead = unpositioned_message;
    /// The last admission listed: main listed Messages by admission, so
    /// positions must order them the same way.
    pub const State = struct { admission: u64 = 0 };

    fn after(session: []const u8, row: *const S.Row) S.Args {
        return .{ .session = session, .position = row.admission_position.get(), .admission = row.admission_id.get() };
    }

    pub fn queueFirst(a: *ReadAccess, session: []const u8, found: *First) void {
        a.read(unpositioned_message, .{ .session = session }, found);
    }

    /// A Message without a position is `CorruptStore`, where main listed it.
    pub fn checkFirst(found: *const First) error{CorruptStore}!void {
        if (found.* != null) return error.CorruptStore;
    }

    /// A Message admitted before one listed ahead of it is `CorruptStore`.
    pub fn check(state: *State, row: *const S.Row) error{CorruptStore}!void {
        if (row.admission_id.get() <= state.admission) return error.CorruptStore;
        state.admission = row.admission_id.get();
    }

    fn streams(_: *const S.Row) bool {
        return true;
    }

    fn render(a: *ReadAccess, capture: *SessionReportCapture, row: *const S.Row) !void {
        const projection = try command_domain.projectMessage(row, if (row.excluding_stop) |*stop| stop.slice() else null);
        try capture.appendFmt("{{\"admission\":\"{d}\",\"command_key\":", .{projection.admission_id});
        try capture.appendJsonString(projection.command_key.slice());
        try capture.append(",\"content\":");
        try streamInline(a, capture, .{ .id = row.content_id.get(), .length = row.content_length, .digest = row.content_digest });
        try capture.append(",\"turn\":");
        switch (projection.state) {
            .applied => |applied| try capture.appendFmt("\"{d}\"", .{applied.binding.turn_id}),
            .pending, .excluded => try capture.append("null"),
        }
        try capture.append(",\"application\":");
        try capture.appendJsonString(@tagName(projection.state));
        try capture.append(",\"exclusion\":");
        switch (projection.state) {
            .excluded => |stop_key| {
                try capture.append("{\"code\":\"session_stopped\",\"command_key\":");
                try capture.appendJsonString(stop_key.slice());
                try capture.append("}");
            },
            .pending, .applied => try capture.append("null"),
        }
        try capture.append(",\"outcome\":");
        switch (projection.state) {
            .applied => |applied| if (applied.outcome_code) |code| {
                try capture.append("{\"code\":");
                try capture.appendJsonString(code.slice());
                try capture.append(",\"content\":");
                try appendReference(row.outcome_content_id, row.outcome_length, row.outcome_digest, capture);
                try capture.append("}");
            } else try capture.append("null"),
            .pending, .excluded => try capture.append("null"),
        }
        try capture.append("}");
    }
};

/// Content shown by reference, or null for none.
fn appendReference(id: ?rsql.Positive, length: ?u64, digest: ?[32]u8, capture: *SessionReportCapture) !void {
    const value = try optionalValue(id, length, digest) orelse return capture.append("null");
    try capture.appendBareContentReference(.{ .length = value.length, .digest = value.digest });
}

/// A Turn's or Operation's outcome code, with no content when it has none.
fn checkOutcome(code: anytype, content_id: ?rsql.Positive) error{CorruptStore}!void {
    if (code.* == null and content_id != null) return error.CorruptStore;
}

/// The Session's Conversation entries, by `entry_ordinal`, each with its
/// content's metadata and, for a message or assistant entry, whether it
/// is public (`reads.publicEntryRead`), which main read per row.
const full_conversation = rsql.Read(.{
    .sql = reads_domain.publicEntryRead(
        "e.entry_ordinal,e.session_position,e.entry_kind,e.turn_id,e.source_admission_id,e.source_revision,e.source_operation_id," ++
            "c.byte_length AS content_length,c.digest AS content_digest",
        "e.entry_kind=2 OR ",
        "WHERE e.session_ref=?1 AND e.entry_ordinal>?2 ORDER BY e.entry_ordinal" ++ chunk_limit,
    ),
    .Args = struct { session: []const u8, after: u64 = 0 },
    .Row = struct {
        entry_ordinal: rsql.Positive,
        session_position: rsql.Positive,
        entry_kind: u8,
        turn_id: rsql.Positive,
        source_admission_id: ?rsql.Positive,
        source_revision: ?rsql.Positive,
        source_operation_id: ?rsql.Positive,
        content_length: u64,
        content_digest: [32]u8,
        consistent: bool,
    },
    .cardinality = .each,
});

pub const Conversation = struct {
    const S = full_conversation;
    const failed = error.ConversationReadFailed;
    const header = "],\"conversation\":[";
    const State = NoState;
    const check = noCheck;
    const streams = streamsNever;
    pub const kept_rows = 0;
    pub const First = reads_domain.missing_assistant_entry.Result;
    const FirstRead = reads_domain.missing_assistant_entry;

    fn after(session: []const u8, row: *const S.Row) S.Args {
        return .{ .session = session, .after = row.entry_ordinal.get() };
    }

    /// Every accepted assistant message has its entry, at any position,
    /// as main checked before the list; it implies main's check per row.
    pub fn queueFirst(a: *ReadAccess, session: []const u8, missing: *First) void {
        a.read(reads_domain.missing_assistant_entry, .{ .session = session, .lower = 0, .upper = std.math.maxInt(i64) }, missing);
    }

    pub fn checkFirst(missing: *const First) error{CorruptStore}!void {
        if (missing.* != null) return error.CorruptStore;
    }

    fn render(_: *ReadAccess, capture: *SessionReportCapture, row: *const S.Row) !void {
        if (row.entry_kind < 1 or row.entry_kind > 3 or !row.consistent) return error.CorruptStore;
        try capture.appendFmt("{{\"ordinal\":\"{d}\",\"position\":\"{d}\",\"kind\":\"{s}\",\"turn\":\"{d}\",\"source_admission\":", .{
            row.entry_ordinal.get(),
            row.session_position.get(),
            switch (row.entry_kind) {
                1 => "message",
                2 => "settings",
                3 => "assistant",
                else => unreachable,
            },
            row.turn_id.get(),
        });
        try appendOptionalPositive(row.source_admission_id, capture);
        try capture.append(",\"source_revision\":");
        try appendOptionalPositive(row.source_revision, capture);
        try capture.append(",\"source_operation\":");
        try appendOptionalPositive(row.source_operation_id, capture);
        try capture.append(",\"content\":");
        try capture.appendBareContentReference(.{ .length = row.content_length, .digest = row.content_digest });
        try capture.append("}");
    }
};

fn appendOptionalPositive(value: ?rsql.Positive, capture: *SessionReportCapture) !void {
    if (value) |positive| try capture.appendFmt("\"{d}\"", .{positive.get()}) else try capture.append("null");
}

/// The Session's Turns, by `turn_id`, with their outcomes' metadata.
const full_turns = rsql.Read(.{
    .sql = "SELECT t.turn_id,t.first_admission_id,t.input_cutoff,t.operation_id,t.outcome_code,t.outcome_content_id," ++
        "outcome.byte_length AS outcome_length,outcome.digest AS outcome_digest " ++
        "FROM turn t @index(turn_session_latest) LEFT JOIN content outcome ON outcome.content_id=t.outcome_content_id " ++
        "WHERE t.session_ref=?1 AND t.turn_id>?2 ORDER BY t.turn_id" ++ chunk_limit,
    .Args = struct { session: []const u8, after: u64 = 0 },
    .Row = struct {
        turn_id: rsql.Positive,
        first_admission_id: rsql.Positive,
        input_cutoff: u64,
        operation_id: rsql.Positive,
        outcome_code: ?protocol.Bounded(protocol.max_code_bytes),
        outcome_content_id: ?rsql.Positive,
        outcome_length: ?u64,
        outcome_digest: ?[32]u8,
    },
    .cardinality = .each,
});

const Turns = struct {
    const S = full_turns;
    const failed = error.TurnReadFailed;
    const header = "],\"turns\":[";
    const State = NoState;
    const check = noCheck;
    const First = NoFirst;
    const queueFirst = noQueueFirst;
    const checkFirst = noCheckFirst;
    const streams = streamsNever;
    pub const kept_rows = 0;

    fn after(session: []const u8, row: *const S.Row) S.Args {
        return .{ .session = session, .after = row.turn_id.get() };
    }

    fn render(_: *ReadAccess, capture: *SessionReportCapture, row: *const S.Row) !void {
        if (row.input_cutoff < row.first_admission_id.get()) return error.CorruptStore;
        try checkOutcome(&row.outcome_code, row.outcome_content_id);
        try capture.appendFmt("{{\"turn\":\"{d}\",\"first_admission\":\"{d}\",\"input_cutoff\":\"{d}\",\"operation\":\"{d}\",\"outcome\":", .{
            row.turn_id.get(),
            row.first_admission_id.get(),
            row.input_cutoff,
            row.operation_id.get(),
        });
        if (row.outcome_code) |*code| {
            try capture.append("{\"code\":");
            try capture.appendJsonString(code.slice());
            try capture.append(",\"content\":");
            try appendReference(row.outcome_content_id, row.outcome_length, row.outcome_digest, capture);
            try capture.append("}");
        } else try capture.append("null");
        try capture.append("}");
    }
};

/// The Session's Operations, by `operation_id`, with their resolutions'
/// metadata.
const full_operations = rsql.Read(.{
    .sql = "SELECT o.operation_id,o.turn_id,o.resolution_code,o.resolution_content_id,resolution.byte_length AS resolution_length," ++
        "resolution.digest AS resolution_digest,o.interrupted_by_command_key,o.settings_revision,o.request_id,o.reasoning_effort " ++
        "FROM model_operation o @index(model_operation_session_history) LEFT JOIN content resolution ON resolution.content_id=o.resolution_content_id " ++
        "WHERE o.session_ref=?1 AND o.operation_id>?2 ORDER BY o.operation_id" ++ chunk_limit,
    .Args = struct { session: []const u8, after: u64 = 0 },
    .Row = struct {
        operation_id: rsql.Positive,
        turn_id: rsql.Positive,
        resolution_code: ?protocol.Bounded(protocol.max_code_bytes),
        resolution_content_id: ?rsql.Positive,
        resolution_length: ?u64,
        resolution_digest: ?[32]u8,
        interrupted_by_command_key: ?protocol.Bounded(128),
        settings_revision: rsql.Positive,
        request_id: ?protocol.Bounded(256),
        reasoning_effort: ?protocol.ReasoningEffort,
    },
    .cardinality = .each,
});

const Operations = struct {
    const S = full_operations;
    const failed = error.OperationReadFailed;
    const header = "],\"model_operations\":[";
    const State = NoState;
    const check = noCheck;
    const First = NoFirst;
    const queueFirst = noQueueFirst;
    const checkFirst = noCheckFirst;
    pub const kept_rows = 4;

    fn after(session: []const u8, row: *const S.Row) S.Args {
        return .{ .session = session, .after = row.operation_id.get() };
    }

    fn streams(row: *const S.Row) bool {
        return row.resolution_content_id != null;
    }

    fn render(a: *ReadAccess, capture: *SessionReportCapture, row: *const S.Row) !void {
        try checkOutcome(&row.resolution_code, row.resolution_content_id);
        try capture.appendFmt("{{\"operation\":\"{d}\",\"turn\":\"{d}\",\"resolution\":", .{ row.operation_id.get(), row.turn_id.get() });
        if (row.resolution_code) |*code| {
            try capture.append("{\"code\":");
            try capture.appendJsonString(code.slice());
            try capture.append(",\"content\":");
            try appendInline(a, row.resolution_content_id, row.resolution_length, row.resolution_digest, capture);
            try capture.append("}");
        } else try capture.append("null");
        try capture.append(",\"interrupted_by\":");
        try appendOptionalText(&row.interrupted_by_command_key, capture);
        try capture.appendFmt(",\"settings_revision\":\"{d}\",\"request_id\":", .{row.settings_revision.get()});
        try appendOptionalText(&row.request_id, capture);
        try capture.append(",\"reasoning_effort\":");
        try appendNullableEffort(row.reasoning_effort, capture);
        try capture.append("}");
    }
};

/// Content shown whole, or null for none.
fn appendInline(a: *ReadAccess, id: ?rsql.Positive, length: ?u64, digest: ?[32]u8, capture: *SessionReportCapture) !void {
    const value = try optionalValue(id, length, digest) orelse return capture.append("null");
    try streamInline(a, capture, value);
}

fn appendOptionalText(text: anytype, capture: *SessionReportCapture) !void {
    if (text.*) |*value| try capture.appendJsonString(value.slice()) else try capture.append("null");
}

/// The Session's calls, by Operation and ordinal, each with its contents'
/// metadata.
const full_calls = rsql.Read(.{
    .sql = "SELECT tool_call.operation_id,tool_call.call_ordinal,tool_call.item_ordinal,tool_call.rejection_code,tool_call.acceptance_position," ++
        "tool_call.name_content_id AS name_id,name_content.byte_length AS name_length,name_content.digest AS name_digest," ++
        "tool_call.call_id_content_id AS call_id,call_id_content.byte_length AS call_id_length,call_id_content.digest AS call_id_digest," ++
        "tool_call.arguments_content_id AS arguments_id,arguments_content.byte_length AS arguments_length,arguments_content.digest AS arguments_digest," ++
        "tool_call.rejection_content_id AS rejection_id,rejection_content.byte_length AS rejection_length,rejection_content.digest AS rejection_digest " ++
        "FROM model_operation operation @index(model_operation_session_history) CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=operation.operation_id " ++
        "LEFT JOIN content name_content ON name_content.content_id=tool_call.name_content_id " ++
        "LEFT JOIN content call_id_content ON call_id_content.content_id=tool_call.call_id_content_id " ++
        "LEFT JOIN content arguments_content ON arguments_content.content_id=tool_call.arguments_content_id " ++
        "LEFT JOIN content rejection_content ON rejection_content.content_id=tool_call.rejection_content_id " ++
        "WHERE operation.session_ref=?1 AND operation.operation_id>=?2 AND (operation.operation_id>?2 OR tool_call.call_ordinal>=?3) " ++
        "ORDER BY operation.operation_id,tool_call.call_ordinal" ++ chunk_limit,
    .Args = struct { session: []const u8, operation: u64 = 0, ordinal: u64 = 0 },
    .Row = struct {
        operation_id: rsql.Positive,
        call_ordinal: u64,
        item_ordinal: u64,
        rejection_code: ?protocol.Bounded(32),
        acceptance_position: ?rsql.Positive,
        name_id: rsql.Positive,
        name_length: u64,
        name_digest: [32]u8,
        call_id: rsql.Positive,
        call_id_length: u64,
        call_id_digest: [32]u8,
        arguments_id: rsql.Positive,
        arguments_length: u64,
        arguments_digest: [32]u8,
        rejection_id: ?rsql.Positive,
        rejection_length: ?u64,
        rejection_digest: ?[32]u8,
    },
    .cardinality = .each,
});

const Calls = struct {
    const S = full_calls;
    const failed = error.CallReadFailed;
    const header = "],\"tool_calls\":[";
    const State = NoState;
    const check = noCheck;
    const First = NoFirst;
    const queueFirst = noQueueFirst;
    const checkFirst = noCheckFirst;
    pub const kept_rows = 8;

    fn after(session: []const u8, row: *const S.Row) S.Args {
        return .{ .session = session, .operation = row.operation_id.get(), .ordinal = row.call_ordinal + 1 };
    }

    fn streams(_: *const S.Row) bool {
        return true;
    }

    fn render(a: *ReadAccess, capture: *SessionReportCapture, row: *const S.Row) !void {
        try capture.appendFmt("{{\"operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"item_ordinal\":\"{d}\",\"rejection\":", .{ row.operation_id.get(), row.call_ordinal, row.item_ordinal });
        try appendOptionalText(&row.rejection_code, capture);
        try capture.append(",\"acceptance_position\":");
        try appendOptionalPositive(row.acceptance_position, capture);
        try capture.append(",\"name\":");
        try streamInline(a, capture, .{ .id = row.name_id.get(), .length = row.name_length, .digest = row.name_digest });
        try capture.append(",\"call_id\":");
        try streamInline(a, capture, .{ .id = row.call_id.get(), .length = row.call_id_length, .digest = row.call_id_digest });
        try capture.append(",\"arguments\":");
        try streamInline(a, capture, .{ .id = row.arguments_id.get(), .length = row.arguments_length, .digest = row.arguments_digest });
        try capture.append(",\"rejection_result\":");
        try appendInline(a, row.rejection_id, row.rejection_length, row.rejection_digest, capture);
        try capture.append("}");
    }
};

/// The Session's Actions, by `action_id`, with their results' metadata.
const full_actions = rsql.Read(.{
    .sql = "SELECT action.action_id,action.parent_operation_id,action.call_ordinal,action.permission_revision," ++
        "CASE WHEN @same(action.resolution_code,'denied') THEN 'denied' WHEN action.authorized=1 THEN 'authorized' ELSE 'requested' END AS permission," ++
        "action.resolution_code,action.resolution_content_id,result.byte_length AS result_length,result.digest AS result_digest,action.acceptance_position " ++
        "FROM action_operation action @index(action_operation_session_order) LEFT JOIN content result ON result.content_id=action.resolution_content_id " ++
        "WHERE action.session_ref=?1 AND action.action_id>?2 ORDER BY action.action_id" ++ chunk_limit,
    .Args = struct { session: []const u8, after: u64 = 0 },
    .Row = struct {
        action_id: rsql.Positive,
        parent_operation_id: rsql.Positive,
        call_ordinal: u64,
        permission_revision: rsql.Positive,
        permission: protocol.Bounded(16),
        resolution_code: ?protocol.Bounded(max_action_resolution_code_bytes),
        resolution_content_id: ?rsql.Positive,
        result_length: ?u64,
        result_digest: ?[32]u8,
        acceptance_position: ?rsql.Positive,
    },
    .cardinality = .each,
});

const Actions = struct {
    const S = full_actions;
    const failed = error.ActionReadFailed;
    const header = "],\"actions\":[";
    const State = NoState;
    const check = noCheck;
    const First = NoFirst;
    const queueFirst = noQueueFirst;
    const checkFirst = noCheckFirst;
    pub const kept_rows = 4;

    fn after(session: []const u8, row: *const S.Row) S.Args {
        return .{ .session = session, .after = row.action_id.get() };
    }

    fn streams(row: *const S.Row) bool {
        return row.resolution_content_id != null;
    }

    fn render(a: *ReadAccess, capture: *SessionReportCapture, row: *const S.Row) !void {
        try capture.appendFmt("{{\"action\":\"{d}\",\"parent_operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"permission_revision\":\"{d}\",\"permission\":\"{s}\",\"resolution\":", .{
            row.action_id.get(),
            row.parent_operation_id.get(),
            row.call_ordinal,
            row.permission_revision.get(),
            row.permission.slice(),
        });
        try appendOptionalText(&row.resolution_code, capture);
        try capture.append(",\"result\":");
        try appendInline(a, row.resolution_content_id, row.result_length, row.result_digest, capture);
        try capture.append(",\"acceptance_position\":");
        try appendOptionalPositive(row.acceptance_position, capture);
        try capture.append("}");
    }
};

/// The Session's permission decisions, by command order, as main scanned
/// the commands.
const full_decisions = rsql.Read(.{
    .sql = "SELECT command.command_seq,decision.command_key,decision.action_id,decision.decision,command.accepted,command.code " ++
        "FROM permission_decision_command decision JOIN core_command command ON command.command_key=decision.command_key " ++
        "WHERE command.kind=5 AND command.target=?1 AND command.command_seq>?2 ORDER BY command.command_seq" ++ chunk_limit,
    .Args = struct { session: []const u8, after: u64 = 0 },
    .Row = struct {
        command_seq: rsql.Positive,
        command_key: protocol.Bounded(128),
        action_id: protocol.Bounded(20),
        decision: protocol.PermissionDecision,
        accepted: bool,
        code: protocol.Bounded(96),
    },
    .cardinality = .each,
});

const Decisions = struct {
    const S = full_decisions;
    const failed = error.PermissionReadFailed;
    const header = "],\"permission_decisions\":[";
    const State = NoState;
    const check = noCheck;
    const First = NoFirst;
    const queueFirst = noQueueFirst;
    const checkFirst = noCheckFirst;
    const streams = streamsNever;
    pub const kept_rows = 0;

    fn after(session: []const u8, row: *const S.Row) S.Args {
        return .{ .session = session, .after = row.command_seq.get() };
    }

    fn render(_: *ReadAccess, capture: *SessionReportCapture, row: *const S.Row) !void {
        try capture.append("{\"command_key\":");
        try capture.appendJsonString(row.command_key.slice());
        try capture.append(",\"action\":");
        try capture.appendJsonString(row.action_id.slice());
        try capture.appendFmt(",\"decision\":\"{s}\",\"status\":\"{s}\",\"code\":", .{ @tagName(row.decision), status(row.accepted) });
        try capture.appendJsonString(row.code.slice());
        try capture.append("}");
    }
};

fn status(accepted: bool) []const u8 {
    return if (accepted) "accepted" else "rejected";
}

/// The Session's stop commands, by command order, as main scanned them.
pub const full_stops = rsql.Read(.{
    .sql = "SELECT command.command_seq,command.command_key,command.accepted,command.code,stop.selected_turn_id,stop.admission_cutoff " ++
        "FROM core_command command LEFT JOIN session_stop stop ON stop.command_key=command.command_key " ++
        "WHERE command.kind=3 AND command.target=?1 AND command.command_seq>?2 ORDER BY command.command_seq" ++ chunk_limit,
    .Args = struct { session: []const u8, after: u64 = 0 },
    .Row = struct {
        command_seq: rsql.Positive,
        command_key: protocol.Bounded(128),
        accepted: bool,
        code: protocol.Bounded(96),
        selected_turn_id: ?rsql.Positive,
        admission_cutoff: ?u64,
    },
    .cardinality = .each,
});

const Stops = struct {
    const S = full_stops;
    const failed = error.SessionStopReadFailed;
    const header = "],\"session_stops\":[";
    const State = NoState;
    const check = noCheck;
    const First = NoFirst;
    const queueFirst = noQueueFirst;
    const checkFirst = noCheckFirst;
    const streams = streamsNever;
    pub const kept_rows = 0;

    fn after(session: []const u8, row: *const S.Row) S.Args {
        return .{ .session = session, .after = row.command_seq.get() };
    }

    fn render(_: *ReadAccess, capture: *SessionReportCapture, row: *const S.Row) !void {
        try capture.append("{\"command_key\":");
        try capture.appendJsonString(row.command_key.slice());
        try capture.appendFmt(",\"status\":\"{s}\",\"code\":", .{status(row.accepted)});
        try capture.appendJsonString(row.code.slice());
        try capture.append(",\"selected_turn\":");
        try appendOptionalPositive(row.selected_turn_id, capture);
        try capture.append(",\"admission_cutoff\":");
        if (row.admission_cutoff) |cutoff| try capture.appendFmt("\"{d}\"", .{cutoff}) else try capture.append("null");
        try capture.append("}");
    }
};

/// The Session's interruption commands, by command order, as main sorted
/// them: CROSS JOIN keeps main's plan, the Session's interruptions first.
pub const full_interruptions = rsql.Read(.{
    .sql = "SELECT command.command_seq,command.command_key,command.accepted,command.code,interruption.turn_id,interruption.operation_id " ++
        "FROM model_interruption_command interruption CROSS JOIN core_command command ON command.command_key=interruption.command_key " ++
        "WHERE interruption.session_ref=?1 AND command.command_seq>?2 ORDER BY command.command_seq" ++ chunk_limit,
    .Args = struct { session: []const u8, after: u64 = 0 },
    .Row = struct {
        command_seq: rsql.Positive,
        command_key: protocol.Bounded(128),
        accepted: bool,
        code: protocol.Bounded(96),
        turn_id: protocol.Bounded(20),
        operation_id: protocol.Bounded(20),
    },
    .cardinality = .each,
});

const Interruptions = struct {
    const S = full_interruptions;
    const failed = error.InterruptionReadFailed;
    const header = "],\"model_interruptions\":[";
    const State = NoState;
    const check = noCheck;
    const First = NoFirst;
    const queueFirst = noQueueFirst;
    const checkFirst = noCheckFirst;
    const streams = streamsNever;
    pub const kept_rows = 0;

    fn after(session: []const u8, row: *const S.Row) S.Args {
        return .{ .session = session, .after = row.command_seq.get() };
    }

    fn render(_: *ReadAccess, capture: *SessionReportCapture, row: *const S.Row) !void {
        try capture.append("{\"command_key\":");
        try capture.appendJsonString(row.command_key.slice());
        try capture.appendFmt(",\"status\":\"{s}\",\"code\":", .{status(row.accepted)});
        try capture.appendJsonString(row.code.slice());
        try capture.append(",\"turn\":");
        try capture.appendJsonString(row.turn_id.slice());
        try capture.append(",\"operation\":");
        try capture.appendJsonString(row.operation_id.slice());
        try capture.append("}");
    }
};

/// The Session's Tool Results, by Operation, then acceptance and ordinal.
pub const full_results = rsql.Read(.{
    .sql = "SELECT tool_call.operation_id,tool_call.call_ordinal,coalesce(tool_call.acceptance_position,action.acceptance_position) AS acceptance_position," ++
        "tool_call.call_id_content_id AS call_id,call_id_content.byte_length AS call_id_length,call_id_content.digest AS call_id_digest," ++
        "coalesce(tool_call.rejection_code,action.resolution_code) AS code," ++
        "coalesce(tool_call.rejection_content_id,action.resolution_content_id) AS result_id,result.byte_length AS result_length,result.digest AS result_digest " ++
        "FROM model_operation operation @index(model_operation_session_history) CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=operation.operation_id " ++
        "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
        "LEFT JOIN content call_id_content ON call_id_content.content_id=tool_call.call_id_content_id " ++
        "LEFT JOIN content result ON result.content_id=coalesce(tool_call.rejection_content_id,action.resolution_content_id) " ++
        "WHERE operation.session_ref=?1 AND coalesce(tool_call.rejection_code,action.resolution_code) IS NOT NULL " ++
        "AND operation.operation_id>=?2 AND (operation.operation_id>?2 OR coalesce(tool_call.acceptance_position,action.acceptance_position)>?3 " ++
        "OR (coalesce(tool_call.acceptance_position,action.acceptance_position)=?3 AND tool_call.call_ordinal>=?4)) " ++
        "ORDER BY operation.operation_id,coalesce(tool_call.acceptance_position,action.acceptance_position),tool_call.call_ordinal" ++ chunk_limit,
    .Args = struct { session: []const u8, operation: u64 = 0, acceptance: u64 = 0, ordinal: u64 = 0 },
    .Row = struct {
        operation_id: rsql.Positive,
        call_ordinal: u64,
        acceptance_position: rsql.Positive,
        call_id: rsql.Positive,
        call_id_length: u64,
        call_id_digest: [32]u8,
        code: protocol.Bounded(32),
        result_id: rsql.Positive,
        result_length: u64,
        result_digest: [32]u8,
    },
    .cardinality = .each,
});

const Results = struct {
    const S = full_results;
    const failed = error.CallReadFailed;
    const header = "],\"tool_results\":[";
    const State = NoState;
    const check = noCheck;
    const First = NoFirst;
    const queueFirst = noQueueFirst;
    const checkFirst = noCheckFirst;
    pub const kept_rows = 8;

    fn after(session: []const u8, row: *const S.Row) S.Args {
        return .{ .session = session, .operation = row.operation_id.get(), .acceptance = row.acceptance_position.get(), .ordinal = row.call_ordinal + 1 };
    }

    fn streams(_: *const S.Row) bool {
        return true;
    }

    fn render(a: *ReadAccess, capture: *SessionReportCapture, row: *const S.Row) !void {
        try capture.appendFmt("{{\"operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"acceptance_position\":\"{d}\",\"call_id\":", .{ row.operation_id.get(), row.call_ordinal, row.acceptance_position.get() });
        try streamInline(a, capture, .{ .id = row.call_id.get(), .length = row.call_id_length, .digest = row.call_id_digest });
        try capture.append(",\"code\":");
        try capture.appendJsonString(row.code.slice());
        try capture.append(",\"result\":");
        try streamInline(a, capture, .{ .id = row.result_id.get(), .length = row.result_length, .digest = row.result_digest });
        try capture.append("}");
    }
};

fn appendNullableEffort(value: ?protocol.ReasoningEffort, capture: *SessionReportCapture) !void {
    if (value) |effort| return capture.appendJsonString(@tagName(effort));
    try capture.append("null");
}
