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
const Store = store_core.Store;
const action_domain = @import("action.zig");
const command_domain = @import("command.zig");
const configuration_domain = @import("configuration.zig");
const content_domain = @import("content.zig");
const model_admission_domain = @import("model_admission.zig");
const reads_domain = @import("reads.zig");
const store_schema = @import("../schema.zig");
const sqlite = @import("../sqlite.zig");
const turn_domain = @import("turn.zig");
const c = sqlite.c;
const AttemptBinding = store_core.AttemptBinding;
const ContentReference = content_domain.ContentReference;
const ContentSource = reads_domain.ContentSource;
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

/// A Session report's work, peer facts and first Message, in one Access.
/// Not inlined, so the Access and the reads' rows take no slot in the
/// report's frame, which every report appender shares.
noinline fn appendWorkAndRowFacts(self: *Store, session_ref: []const u8, created_at: u64, capture: *SessionReportCapture) !void {
    var a = ReadAccess.within(self);
    defer a.deinit();
    try renderWorkAndRowFacts(&a, session_ref, created_at, capture);
}

/// `appendWorkAndRowFacts` within `a`, whose rounds tests count. Its rounds
/// are its reads' dependency depth: round 1 reads the work's latest Turn,
/// the latest Message from no Session and both first-Message seeks; round
/// 2 the work's second stage and, when a seek found one, the first
/// admission's row; the work's later stages follow (`readWorks`). Inline,
/// so it adds no frame to `appendWorkAndRowFacts`.
pub inline fn renderWorkAndRowFacts(a: *ReadAccess, session_ref: []const u8, created_at: u64, capture: *SessionReportCapture) !void {
    var person: person_message.Result = undefined;
    var first: FirstCandidates = undefined;
    var read: WorkRead = .{ .session = session_ref };
    // Main read the work first, so a round queues it first.
    _ = read.queue(a);
    a.read(person_message, .{ .session = session_ref }, &person);
    first.queue(a, session_ref);
    try runReport(a);
    try read.advance();
    const admission = first.admission();
    var row: first_message.Result = null;
    if (admission != 0) a.read(first_message, .{ .session = session_ref, .first = admission }, &row);
    const more = read.queue(a);
    if (more or admission != 0) try runReport(a);
    if (more) try read.advance();
    if (admission != 0 and row == null) return error.CorruptStore;
    try readWorks(a, (&read)[0..1]);
    const work: protocol.SessionWork = .fromCore(try read.work(created_at, std.math.cast(u64, try store_core.readUnixMilliseconds(a.store.io)) orelse return error.IntegerOutOfRange));
    try capture.appendShape(.{"{"} ++ protocol.SessionWork.fields, work.args());
    if (read.outcome()) |outcome| {
        try capture.append(",\"latest_outcome\":{\"code\":");
        try capture.appendJsonString(outcome.code);
        try capture.append(",\"content\":");
        if (outcome.content_id) |content_id| {
            const metadata = try content_domain.readContentMetadata(a.store, @intCast(content_id));
            try capture.appendBareContentReference(.{ .length = metadata.length, .digest = metadata.digest });
        } else {
            try capture.append("null");
        }
        try capture.append("}}");
    } else try capture.append(",\"latest_outcome\":null}");
    try capture.append(",\"peers\":");
    const peers: protocol.PeerFacts = .{ .from_person_at = if (person) |found| found.admitted_at.get() else null };
    try capture.appendShape(.{protocol.Hole{ .json = protocol.PeerFacts }}, .{peers});
    try capture.append(",\"first_message\":");
    try capture.appendShape(.{protocol.Hole{ .optional_json = protocol.FirstMessage }}, .{if (row) |*found| try firstMessage(found, admission) else null});
}

pub fn renderSessionReportLocked(
    self: *Store,
    session_ref: []const u8,
    profile: protocol.ReportProfile,
    execution: SessionReportExecution,
    capture: *SessionReportCapture,
) !void {
    var current: CurrentConfiguration = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } };
    const found = try configuration_domain.readSession(self, session_ref, &current);
    try capture.append("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_report\",\"profile\":\"");
    try capture.append(@tagName(profile));
    try capture.append("\",\"session\":");
    if (!found) {
        try capture.append("null,\"pending_messages\":\"0\",\"execution\":{\"status\":\"unavailable\",\"reason\":\"session_not_found\"}}");
        return;
    }
    const instructions = try content_domain.readContentMetadata(self, current.instructions_id orelse return error.CorruptStore);
    const output_schema = if (current.output_schema_id) |content_id|
        try content_domain.readContentMetadata(self, content_id)
    else
        null;
    const pending_messages = try command_domain.countPendingMessages(self, session_ref);
    try validateActiveTurnToolCalls(self, session_ref);
    const action_count = try countActions(self, session_ref);
    const rejected_call_count = try countRejectedCalls(self, session_ref);

    try capture.append("{\"reference\":");
    try capture.appendJsonString(session_ref);
    try capture.append(",\"workspace\":");
    try capture.appendJsonString(current.workspace.slice());
    try capture.append(",\"provider\":");
    try capture.appendJsonString(@tagName(current.provider));
    try capture.append(",\"model\":");
    try capture.appendJsonString(current.model.slice());
    const policy = model_capability.compactionPolicy(current.model.slice(), current.compaction_trigger, current.output_reservation);
    try capture.append(",\"compaction_trigger\":");
    try capture.appendFmt("\"{d}\"", .{policy.compaction_trigger});
    try capture.append(",\"context_estimate\":");
    const pressure = turn_policy.comparedPressure(try model_admission_domain.compactionFacts(self, session_ref, null, current.next_position, current.provider, current.model.slice(), policy));
    if (pressure) |value| try capture.appendFmt("\"{d}\"", .{@min(value, std.math.maxInt(i64))}) else try capture.append("null");
    try capture.appendFmt(",\"output_reservation\":\"{d}\",\"compaction_trigger_override\":", .{policy.output_reservation});
    if (current.compaction_trigger) |value| try capture.appendFmt("\"{d}\"", .{value}) else try capture.append("null");
    try capture.append(",\"output_reservation_override\":");
    if (current.output_reservation) |value| try capture.appendFmt("\"{d}\"", .{value}) else try capture.append("null");
    try capture.append(",\"reasoning_effort\":");
    try appendNullableEffort(configuration_domain.effectiveReasoningEffort(&current), capture);
    try capture.append(",\"reasoning_effort_override\":");
    try appendNullableEffort(current.reasoning_effort, capture);
    try capture.appendFmt(",\"revision\":\"{d}\",\"tools\":", .{current.revision});
    try capture.appendTools(current.tools_mask);
    try capture.append(",\"permission_mode\":");
    try capture.appendPermissionMode(current.permission_mode);
    try capture.append(",\"instructions\":");
    try capture.appendBareContentReference(.{ .length = instructions.length, .digest = instructions.digest });
    try capture.append(",\"output_schema\":");
    if (output_schema) |reference| {
        try capture.appendBareContentReference(.{ .length = reference.length, .digest = reference.digest });
    } else {
        try capture.append("null");
    }
    try capture.append(",\"label\":");
    if (current.label) |*label| try capture.appendJsonString(label.slice()) else try capture.append("null");
    try capture.appendFmt(",\"created_at\":\"{d}\"}},\"pending_messages\":\"{d}\",\"work\":", .{ current.created_at, pending_messages });
    try appendWorkAndRowFacts(self, session_ref, current.created_at, capture);
    try capture.append(",\"selected_message\":");
    try appendSelectedMessage(self, session_ref, capture);
    try capture.append(",\"recent_messages\":[");
    try appendRecentMessages(self, session_ref, capture);
    try capture.append("]");
    try capture.appendFmt(",\"actions\":{{\"count\":\"{d}\",\"unresolved\":[", .{
        action_count,
    });
    try appendUnresolvedActions(self, session_ref, capture);
    try capture.append("],\"resolved\":[");
    try appendResolvedActions(self, session_ref, capture);
    try capture.appendFmt("]}},\"rejected_calls\":{{\"count\":\"{d}\",\"items\":[", .{rejected_call_count});
    try appendRejectedCalls(self, session_ref, capture);
    try capture.append("]},\"actionable_permissions\":[");
    try appendActionablePermissions(self, session_ref, capture);
    try capture.append("]");
    if (profile == .full) {
        try capture.append(",\"full\":{\"session_revisions\":[");
        try appendSessionRevisions(self, session_ref, capture);
        try capture.append("],\"messages\":[");
        try appendMessages(self, session_ref, capture);
        try capture.append("],\"conversation\":[");
        try appendConversation(self, session_ref, capture);
        try capture.append("],\"turns\":[");
        try appendTurns(self, session_ref, capture);
        try capture.append("],\"model_operations\":[");
        try appendModelOperations(self, session_ref, capture);
        try capture.append("],\"tool_calls\":[");
        try appendToolCalls(self, session_ref, capture);
        try capture.append("],\"actions\":[");
        try appendAllActions(self, session_ref, capture);
        try capture.append("],\"permission_decisions\":[");
        try appendPermissionDecisions(self, session_ref, capture);
        try capture.append("],\"session_stops\":[");
        try appendSessionStops(self, session_ref, capture);
        try capture.append("],\"model_interruptions\":[");
        try appendModelInterruptions(self, session_ref, capture);
        try capture.append("],\"tool_results\":[");
        try appendToolResults(self, session_ref, capture);
        try capture.append("]}");
    }
    try capture.appendFmt(",\"execution\":{{\"status\":\"partial\",\"dispatch_fenced\":{s},\"custody_occupied\":\"{d}\",\"scratch_used_bytes\":\"{d}\",\"unavailable\":[\"structured_output\"]}}}}", .{
        if (execution.dispatch_fenced) "true" else "false",
        execution.custody_occupied,
        execution.scratch_used_bytes,
    });
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

fn appendSelectedMessage(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
    // An active Turn owns the selection even if a successor is queued.
    const active = try store_core.cached(self, "SELECT m.command_key FROM turn t INDEXED BY turn_one_active_per_session " ++
        "JOIN message_admission m ON m.admission_id=t.first_admission_id " ++
        "WHERE t.session_ref=?1 AND t.outcome_code IS NULL");
    defer sqlite.resetCached(active);
    try sqlite.bindText(active, 1, session_ref);
    const active_step = c.sqlite3_step(active);
    if (active_step == c.SQLITE_ROW) {
        var key: protocol.Bounded(protocol.max_key_bytes) = .{};
        try sqlite.readText(active, 0, &key);
        return capture.appendJsonString(key.slice());
    }
    if (active_step != c.SQLITE_DONE) return error.TurnReadFailed;

    const queued = try store_core.cached(self, "SELECT command_key FROM message_admission INDEXED BY message_admission_session_pending " ++
        "WHERE session_ref=?1 AND turn_id IS NULL AND admission_id>?2 ORDER BY admission_id LIMIT 1");
    defer sqlite.resetCached(queued);
    try sqlite.bindText(queued, 1, session_ref);
    try sqlite.bindU64(queued, 2, try command_domain.latestSessionStopCutoff(self, session_ref));
    const queued_step = c.sqlite3_step(queued);
    if (queued_step == c.SQLITE_ROW) {
        var key: protocol.Bounded(protocol.max_key_bytes) = .{};
        try sqlite.readText(queued, 0, &key);
        return capture.appendJsonString(key.slice());
    }
    if (queued_step != c.SQLITE_DONE) return error.MessageAdmissionReadFailed;
    try capture.append("null");
}

fn appendRecentMessages(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
    // Traverse terminal Turns newest-first, then their admissions newest-first.
    // CROSS JOIN fixes that indexed order so LIMIT stops after ten Messages,
    // even when older history or unrelated Sessions grow.
    const statement = try store_core.cached(self, "SELECT t.turn_id,m.command_key,t.outcome_code FROM turn t INDEXED BY turn_session_latest " ++
        "CROSS JOIN message_admission m INDEXED BY message_admission_session_order " ++
        "WHERE t.session_ref=?1 AND t.outcome_code IS NOT NULL " ++
        "AND m.session_ref=t.session_ref AND m.turn_id=t.turn_id " ++
        "ORDER BY t.turn_id DESC,m.admission_id DESC LIMIT 10");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    var first = true;
    while (try nextReportRow(statement, &first, capture, error.TurnReadFailed)) {
        const id = c.sqlite3_column_int64(statement, 0);
        if (id <= 0) return error.CorruptStore;
        var key: protocol.Bounded(protocol.max_key_bytes) = .{};
        var code: protocol.Bounded(protocol.max_code_bytes) = .{};
        try sqlite.readText(statement, 1, &key);
        try sqlite.readText(statement, 2, &code);
        try capture.appendFmt("{{\"turn\":\"{d}\",\"message\":", .{id});
        try capture.appendJsonString(key.slice());
        try capture.append(",\"outcome\":");
        try capture.appendJsonString(code.slice());
        try capture.append("}");
    }
}

fn appendActionablePermissions(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
    const statement = try store_core.cached(
        self,
        "SELECT action.action_id,action.permission_revision FROM turn active INDEXED BY turn_one_active_per_session " ++
            "JOIN action_operation action ON action.parent_operation_id=active.operation_id " ++
            "WHERE active.session_ref=?1 AND active.outcome_code IS NULL " ++
            "AND action.resolution_code IS NULL AND action.authorized=0 ORDER BY action.action_id",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    var first = true;
    while (try nextReportRow(statement, &first, capture, error.ActionReadFailed)) {
        const action_id = c.sqlite3_column_int64(statement, 0);
        const revision = c.sqlite3_column_int64(statement, 1);
        if (action_id <= 0 or revision <= 0) return error.CorruptStore;
        try capture.appendFmt("{{\"action\":\"{d}\",\"permission_revision\":\"{d}\"}}", .{ action_id, revision });
    }
}

fn appendUnresolvedActions(
    self: *Store,
    session_ref: []const u8,
    capture: *SessionReportCapture,
) !void {
    const statement = try store_core.cached(
        self,
        "SELECT a.action_id,a.parent_operation_id,a.call_ordinal,a.permission_revision,a.authorized,revision.permission_mode," ++
            "call_id.byte_length,call_id.digest,arguments.byte_length,arguments.digest " ++
            "FROM turn active INDEXED BY turn_one_active_per_session " ++
            "CROSS JOIN action_operation a ON a.parent_operation_id=active.operation_id " ++
            "CROSS JOIN session_revision revision ON revision.session_ref=a.session_ref AND revision.revision=a.permission_revision " ++
            "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=a.parent_operation_id " ++
            "AND tool_call.call_ordinal=a.call_ordinal CROSS JOIN content call_id " ++
            "ON call_id.content_id=tool_call.call_id_content_id CROSS JOIN content arguments " ++
            "ON arguments.content_id=tool_call.arguments_content_id " ++
            "WHERE active.session_ref=?1 " ++
            "AND active.outcome_code IS NULL AND a.resolution_code IS NULL ORDER BY a.action_id",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    var first = true;
    while (true) {
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return;
        if (result != c.SQLITE_ROW) return error.ActionReadFailed;
        const action_id = c.sqlite3_column_int64(statement, 0);
        const parent = c.sqlite3_column_int64(statement, 1);
        const ordinal = c.sqlite3_column_int64(statement, 2);
        const revision = c.sqlite3_column_int64(statement, 3);
        const authorized = c.sqlite3_column_int(statement, 4);
        const permission_mode = c.sqlite3_column_int(statement, 5);
        const call_id_length = c.sqlite3_column_int64(statement, 6);
        const arguments_length = c.sqlite3_column_int64(statement, 8);
        // The insert authorizes every Action proposed under `bypass`.
        if (action_id <= 0 or parent <= 0 or ordinal < 0 or revision <= 0 or
            call_id_length < 0 or arguments_length < 0 or (permission_mode == 1 and authorized == 0))
        {
            return error.CorruptStore;
        }
        if (!first) try capture.append(",");
        first = false;
        try capture.appendFmt("{{\"action\":\"{d}\",\"parent_operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"tool\":\"bash\",\"permission_revision\":\"{d}\",\"authorization\":\"{s}\",\"call_id\":", .{
            action_id,
            parent,
            ordinal,
            revision,
            if (authorized == 0) "pending" else if (permission_mode == 1) "bypass" else "allow_once",
        });
        try capture.appendContentReference(.{
            .length = @intCast(call_id_length),
            .digest = try sqlite.readDigest(statement, 7),
        });
        try capture.append(",\"arguments\":");
        try capture.appendContentReference(.{
            .length = @intCast(arguments_length),
            .digest = try sqlite.readDigest(statement, 9),
        });
        try reads_domain.appendToolPresentation(self, @intCast(parent), @intCast(ordinal), null, capture);
        try capture.append("}");
    }
}

fn appendResolvedActions(
    self: *Store,
    session_ref: []const u8,
    capture: *SessionReportCapture,
) !void {
    const statement = try store_core.cached(
        self,
        "SELECT a.action_id,a.parent_operation_id,a.call_ordinal,a.resolution_code,a.acceptance_position," ++
            "result.byte_length,result.digest FROM turn active INDEXED BY turn_one_active_per_session " ++
            "CROSS JOIN model_operation operation INDEXED BY model_operation_turn_history " ++
            "ON operation.turn_id=active.turn_id " ++
            "CROSS JOIN action_operation a ON a.parent_operation_id=operation.operation_id " ++
            "CROSS JOIN content result ON result.content_id=a.resolution_content_id " ++
            "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND a.resolution_code IS NOT NULL " ++
            "ORDER BY a.action_id",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    var first = true;
    var last_parent: i64 = 0;
    var publication: ?u64 = null;
    while (true) {
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return;
        if (result != c.SQLITE_ROW) return error.ActionReadFailed;
        const action_id = c.sqlite3_column_int64(statement, 0);
        const parent = c.sqlite3_column_int64(statement, 1);
        const ordinal = c.sqlite3_column_int64(statement, 2);
        const position = c.sqlite3_column_int64(statement, 4);
        const length = c.sqlite3_column_int64(statement, 5);
        if (action_id <= 0 or parent <= 0 or ordinal < 0 or position <= 0 or length < 0) return error.CorruptStore;
        if (parent != last_parent) {
            publication = (try readToolOutcomeFacts(self, @intCast(parent), false)).position;
            last_parent = parent;
        }
        var code: protocol.Bounded(32) = .{};
        try sqlite.readText(statement, 3, &code);
        if (!first) try capture.append(",");
        first = false;
        try capture.appendFmt("{{\"action\":\"{d}\",\"parent_operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"code\":", .{
            action_id,
            parent,
            ordinal,
        });
        try capture.appendJsonString(code.slice());
        try capture.appendFmt(",\"acceptance_position\":\"{d}\",\"result\":", .{position});
        try capture.appendContentReference(.{
            .length = @intCast(length),
            .digest = try sqlite.readDigest(statement, 6),
        });
        try reads_domain.appendToolPresentation(self, @intCast(parent), @intCast(ordinal), publication, capture);
        try capture.append("}");
    }
}

fn appendRejectedCalls(
    self: *Store,
    session_ref: []const u8,
    capture: *SessionReportCapture,
) !void {
    const statement = try store_core.cached(
        self,
        "SELECT tool_call.operation_id,tool_call.call_ordinal,tool_call.rejection_code,tool_call.acceptance_position," ++
            "rejection.byte_length,rejection.digest," ++
            "name.byte_length,name.digest," ++
            "call_id.byte_length,call_id.digest,arguments.byte_length,arguments.digest " ++
            "FROM turn active INDEXED BY turn_one_active_per_session " ++
            "CROSS JOIN model_operation operation INDEXED BY model_operation_turn_history " ++
            "ON operation.turn_id=active.turn_id " ++
            "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=operation.operation_id " ++
            "CROSS JOIN content name ON name.content_id=tool_call.name_content_id " ++
            "CROSS JOIN content call_id ON call_id.content_id=tool_call.call_id_content_id " ++
            "CROSS JOIN content arguments ON arguments.content_id=tool_call.arguments_content_id " ++
            "CROSS JOIN content rejection ON rejection.content_id=tool_call.rejection_content_id " ++
            "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND tool_call.rejection_code IS NOT NULL " ++
            "ORDER BY tool_call.operation_id,tool_call.call_ordinal",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    var first = true;
    var last_parent: i64 = 0;
    var publication: ?u64 = null;
    while (true) {
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return;
        if (result != c.SQLITE_ROW) return error.CallReadFailed;
        const operation_id = c.sqlite3_column_int64(statement, 0);
        const call_ordinal = c.sqlite3_column_int64(statement, 1);
        const acceptance_position = c.sqlite3_column_int64(statement, 3);
        const rejection_length = c.sqlite3_column_int64(statement, 4);
        if (operation_id <= 0 or call_ordinal < 0 or acceptance_position <= 0 or rejection_length < 0) return error.CorruptStore;
        if (operation_id != last_parent) {
            publication = (try readToolOutcomeFacts(self, @intCast(operation_id), false)).position;
            last_parent = operation_id;
        }
        var code: protocol.Bounded(32) = .{};
        try sqlite.readText(statement, 2, &code);
        if (!first) try capture.append(",");
        first = false;
        try capture.appendFmt("{{\"parent_operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"code\":", .{
            operation_id,
            call_ordinal,
        });
        try capture.appendJsonString(code.slice());
        try capture.appendFmt(",\"acceptance_position\":\"{d}\",\"result\":", .{acceptance_position});
        try capture.appendContentReference(.{
            .length = @intCast(rejection_length),
            .digest = try sqlite.readDigest(statement, 5),
        });
        inline for (.{
            .{ "name", 6, 7 },
            .{ "call_id", 8, 9 },
            .{ "arguments", 10, 11 },
        }) |field| {
            const length = c.sqlite3_column_int64(statement, field[1]);
            if (length < 0) return error.CorruptStore;
            try capture.append(",\"");
            try capture.append(field[0]);
            try capture.append("\":");
            try capture.appendContentReference(.{
                .length = @intCast(length),
                .digest = try sqlite.readDigest(statement, field[2]),
            });
        }
        try reads_domain.appendToolPresentation(self, @intCast(operation_id), @intCast(call_ordinal), publication, capture);
        try capture.append("}");
    }
}

/// Inline, as main's compiler chose: outlined, its 968-byte frame sits
/// between the report's frame and `appendRevisionContent` on the intake
/// worker's and main thread's deepest chains.
inline fn appendSessionRevisions(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
    const statement = try store_core.cached(
        self,
        "WITH occurrence(revision,field_order,content_id) AS MATERIALIZED (" ++
            "SELECT revision,0,instructions_content_id FROM session_revision WHERE session_ref=?1 UNION ALL " ++
            "SELECT revision,1,output_schema_content_id FROM session_revision WHERE session_ref=?1 AND output_schema_content_id IS NOT NULL)," ++
            "ownership AS MATERIALIZED (SELECT revision,field_order,content_id," ++
            "first_value(revision) OVER (PARTITION BY content_id ORDER BY revision,field_order) owner_revision," ++
            "first_value(field_order) OVER (PARTITION BY content_id ORDER BY revision,field_order) owner_field FROM occurrence) " ++
            "SELECT revision_row.revision,revision_row.command_key,revision_row.workspace,revision_row.model," ++
            "revision_row.tools_mask,revision_row.permission_mode,revision_row.instructions_content_id,revision_row.output_schema_content_id," ++
            "instructions.owner_revision,instructions.owner_field,output_schema.owner_revision,output_schema.owner_field,revision_row.provider,revision_row.compaction_trigger,revision_row.output_reservation,revision_row.reasoning_effort,revision_row.label " ++
            "FROM session_revision revision_row JOIN ownership instructions ON instructions.revision=revision_row.revision AND instructions.field_order=0 " ++
            "LEFT JOIN ownership output_schema ON output_schema.revision=revision_row.revision AND output_schema.field_order=1 " ++
            "WHERE revision_row.session_ref=?1 ORDER BY revision_row.revision",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    var first = true;
    while (try nextReportRow(statement, &first, capture, error.SessionReadFailed)) {
        const revision = c.sqlite3_column_int64(statement, 0);
        const tools = c.sqlite3_column_int(statement, 4);
        const permission = c.sqlite3_column_int(statement, 5);
        const instructions_id = c.sqlite3_column_int64(statement, 6);
        if (revision <= 0 or tools < 0 or tools > tool_catalog.all_tools_mask or permission < 0 or permission > 1 or instructions_id <= 0) return error.CorruptStore;
        try capture.appendFmt("{{\"revision\":\"{d}\",\"command_key\":", .{revision});
        try appendColumnString(statement, 1, 128, capture);
        try capture.append(",\"workspace\":");
        try appendColumnString(statement, 2, protocol.max_workspace_bytes, capture);
        try capture.append(",\"provider\":");
        const provider = try sqlite.boundedColumnText(statement, 12, protocol.max_provider_bytes);
        try capture.appendJsonString(@tagName(std.meta.stringToEnum(protocol.Provider, provider) orelse return error.CorruptStore));
        try capture.append(",\"model\":");
        try appendColumnString(statement, 3, protocol.max_model_bytes, capture);
        try capture.append(",\"compaction_trigger\":");
        try appendNullablePositiveInteger(statement, 13, capture);
        try capture.append(",\"output_reservation\":");
        try appendNullableNonnegativeInteger(statement, 14, capture);
        try capture.append(",\"reasoning_effort\":");
        try appendNullableEffort(try sqlite.readNullableEffort(statement, 15), capture);
        try capture.append(",\"label\":");
        if (c.sqlite3_column_type(statement, 16) == c.SQLITE_NULL) {
            try capture.append("null");
        } else {
            // Read in place: a label buffer would take a slot in the report's frame.
            const label = try sqlite.boundedColumnText(statement, 16, protocol.max_label_bytes);
            try configuration_domain.checkLabel(label);
            try capture.appendJsonString(label);
        }
        try capture.append(",\"tools\":");
        try capture.appendTools(@intCast(tools));
        try capture.append(",\"permission_mode\":");
        try capture.appendPermissionMode(@intCast(permission));
        try capture.append(",\"instructions\":");
        try appendRevisionContent(
            self,
            instructions_id,
            revision,
            .instructions,
            c.sqlite3_column_int64(statement, 8),
            c.sqlite3_column_int(statement, 9),
            capture,
        );
        try capture.append(",\"output_schema\":");
        if (try sqlite.readNullablePositiveI64(statement, 7)) |content_id| {
            if (c.sqlite3_column_type(statement, 10) == c.SQLITE_NULL or c.sqlite3_column_type(statement, 11) == c.SQLITE_NULL) return error.CorruptStore;
            try appendRevisionContent(
                self,
                content_id,
                revision,
                .output_schema,
                c.sqlite3_column_int64(statement, 10),
                c.sqlite3_column_int(statement, 11),
                capture,
            );
        } else {
            if (c.sqlite3_column_type(statement, 10) != c.SQLITE_NULL or c.sqlite3_column_type(statement, 11) != c.SQLITE_NULL) return error.CorruptStore;
            try capture.append("null");
        }
        try capture.append("}");
    }
}

fn appendRevisionContent(
    self: *Store,
    content_id: i64,
    revision: i64,
    field: RevisionContentField,
    owner_revision: i64,
    owner_field_value: c_int,
    capture: *SessionReportCapture,
) !void {
    if (content_id <= 0 or revision <= 0 or owner_revision <= 0 or owner_revision > revision) return error.CorruptStore;
    const owner_field: RevisionContentField = switch (owner_field_value) {
        0 => .instructions,
        1 => .output_schema,
        else => return error.CorruptStore,
    };
    if (owner_revision == revision and @backingInt(owner_field) > @backingInt(field)) return error.CorruptStore;
    if (owner_revision == revision and owner_field == field) return appendInlineContent(self, content_id, capture);
    const metadata = try content_domain.readContentMetadata(self, content_id);
    try capture.appendOwnedContentReference(
        .{ .length = metadata.length, .digest = metadata.digest },
        owner_revision,
        owner_field,
    );
}

fn appendMessages(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
    const statement = try store_core.cached(
        self,
        "SELECT m.session_ref,m.content_id,m.admission_id,m.command_key,m.turn_id,t.operation_id,o.attempt_ordinal," ++
            "t.outcome_code,t.outcome_content_id " ++
            "FROM message_admission m LEFT JOIN turn t ON t.turn_id=m.turn_id " ++
            "LEFT JOIN model_operation o ON o.operation_id=t.operation_id " ++
            "WHERE m.session_ref=?1 ORDER BY m.admission_id",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    const stops = try store_core.cached(
        self,
        "SELECT stopped.command_key,stopped.admission_cutoff FROM session_stop stopped " ++
            "JOIN core_command command ON command.command_key=stopped.command_key " ++
            "WHERE stopped.session_ref=?1 ORDER BY command.command_seq",
    );
    defer sqlite.resetCached(stops);
    try sqlite.bindText(stops, 1, session_ref);
    var stop_result = c.sqlite3_step(stops);
    if (stop_result != c.SQLITE_ROW and stop_result != c.SQLITE_DONE) return error.SessionStopReadFailed;
    var first = true;
    while (try nextReportRow(statement, &first, capture, error.MessageReadFailed)) {
        const admission_id = c.sqlite3_column_int64(statement, 2);
        if (admission_id <= 0) return error.CorruptStore;
        var excluding_key: protocol.Bounded(128) = .{};
        var excluding_stop: ?[]const u8 = null;
        if (c.sqlite3_column_type(statement, 4) == c.SQLITE_NULL) {
            while (stop_result == c.SQLITE_ROW) {
                const cutoff = c.sqlite3_column_int64(stops, 1);
                if (cutoff < 0) return error.CorruptStore;
                if (cutoff >= admission_id) {
                    try sqlite.readText(stops, 0, &excluding_key);
                    excluding_stop = excluding_key.slice();
                    break;
                }
                stop_result = c.sqlite3_step(stops);
                if (stop_result != c.SQLITE_ROW and stop_result != c.SQLITE_DONE) return error.SessionStopReadFailed;
            }
        }
        const projection = try command_domain.readMessageProjectionRow(statement, excluding_stop);
        if (!projection.session.eql(session_ref)) return error.CorruptStore;
        try capture.appendFmt("{{\"admission\":\"{d}\",\"command_key\":", .{projection.admission_id});
        try capture.appendJsonString(projection.command_key.slice());
        try capture.append(",\"content\":");
        try appendInlineContent(self, projection.content_id, capture);
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
                if (applied.outcome_content_id) |content_id| {
                    const metadata = try content_domain.readContentMetadata(self, content_id);
                    try capture.appendBareContentReference(.{ .length = metadata.length, .digest = metadata.digest });
                } else try capture.append("null");
                try capture.append("}");
            } else try capture.append("null"),
            .pending, .excluded => try capture.append("null"),
        }
        try capture.append("}");
    }
}

fn appendConversation(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
    try reads_domain.validateAssistantEntries(self, session_ref, 0, std.math.maxInt(i64));
    const statement = try store_core.cached(
        self,
        "SELECT entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,content_id " ++
            "FROM conversation_entry WHERE session_ref=?1 ORDER BY entry_ordinal",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    var first = true;
    while (try nextReportRow(statement, &first, capture, error.ConversationReadFailed)) {
        const ordinal = c.sqlite3_column_int64(statement, 0);
        const position = c.sqlite3_column_int64(statement, 1);
        const kind = c.sqlite3_column_int(statement, 2);
        const turn_id = c.sqlite3_column_int64(statement, 3);
        const content_id = c.sqlite3_column_int64(statement, 7);
        if (ordinal <= 0 or position <= 0 or kind < 1 or kind > 3 or turn_id <= 0 or content_id <= 0) return error.CorruptStore;
        if (kind != 2 and (try reads_domain.publicConversationContentLocked(self, session_ref, @intCast(position), 0)).id != content_id) return error.CorruptStore;
        try capture.appendFmt("{{\"ordinal\":\"{d}\",\"position\":\"{d}\",\"kind\":\"{s}\",\"turn\":\"{d}\",\"source_admission\":", .{ ordinal, position, switch (kind) {
            1 => "message",
            2 => "settings",
            3 => "assistant",
            else => unreachable,
        }, turn_id });
        try appendNullablePositiveInteger(statement, 4, capture);
        try capture.append(",\"source_revision\":");
        try appendNullablePositiveInteger(statement, 5, capture);
        try capture.append(",\"source_operation\":");
        try appendNullablePositiveInteger(statement, 6, capture);
        try capture.append(",\"content\":");
        const metadata = try content_domain.readContentMetadata(self, content_id);
        try capture.appendBareContentReference(.{ .length = metadata.length, .digest = metadata.digest });
        try capture.append("}");
    }
}

fn appendTurns(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
    const statement = try store_core.cached(self, "SELECT turn_id,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id FROM turn WHERE session_ref=?1 ORDER BY turn_id");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    var first = true;
    while (try nextReportRow(statement, &first, capture, error.TurnReadFailed)) {
        const turn_id = c.sqlite3_column_int64(statement, 0);
        const first_admission = c.sqlite3_column_int64(statement, 1);
        const cutoff = c.sqlite3_column_int64(statement, 2);
        const operation = c.sqlite3_column_int64(statement, 3);
        if (turn_id <= 0 or first_admission <= 0 or cutoff < first_admission or operation <= 0) return error.CorruptStore;
        try capture.appendFmt("{{\"turn\":\"{d}\",\"first_admission\":\"{d}\",\"input_cutoff\":\"{d}\",\"operation\":\"{d}\",\"outcome\":", .{ turn_id, first_admission, cutoff, operation });
        try appendReferencedOutcome(self, statement, 4, 5, capture);
        try capture.append("}");
    }
}

fn appendModelOperations(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
    const statement = try store_core.cached(self, "SELECT operation_id,turn_id,resolution_code,resolution_content_id,interrupted_by_command_key,settings_revision,request_id,reasoning_effort FROM model_operation WHERE session_ref=?1 ORDER BY operation_id");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    var first = true;
    while (try nextReportRow(statement, &first, capture, error.OperationReadFailed)) {
        const operation = c.sqlite3_column_int64(statement, 0);
        const turn_id = c.sqlite3_column_int64(statement, 1);
        if (operation <= 0 or turn_id <= 0) return error.CorruptStore;
        try capture.appendFmt("{{\"operation\":\"{d}\",\"turn\":\"{d}\",\"resolution\":", .{ operation, turn_id });
        try appendInlineOutcome(self, statement, 2, 3, capture);
        try capture.append(",\"interrupted_by\":");
        try appendNullableColumnString(statement, 4, 128, capture);
        const revision = c.sqlite3_column_int64(statement, 5);
        if (revision <= 0) return error.CorruptStore;
        try capture.appendFmt(",\"settings_revision\":\"{d}\"", .{revision});
        try capture.append(",\"request_id\":");
        try appendNullableColumnString(statement, 6, 256, capture);
        try capture.append(",\"reasoning_effort\":");
        try appendNullableEffort(try sqlite.readNullableEffort(statement, 7), capture);
        try capture.append("}");
    }
}

fn appendToolCalls(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
    const statement = try store_core.cached(
        self,
        "SELECT tool_call.operation_id,tool_call.call_ordinal,tool_call.item_ordinal,tool_call.rejection_code,tool_call.acceptance_position," ++
            "tool_call.name_content_id,tool_call.call_id_content_id,tool_call.arguments_content_id,tool_call.rejection_content_id " ++
            "FROM model_tool_call tool_call JOIN model_operation operation ON operation.operation_id=tool_call.operation_id " ++
            "WHERE operation.session_ref=?1 ORDER BY tool_call.operation_id,tool_call.call_ordinal",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    var first = true;
    while (try nextReportRow(statement, &first, capture, error.CallReadFailed)) {
        const operation = c.sqlite3_column_int64(statement, 0);
        const ordinal = c.sqlite3_column_int64(statement, 1);
        const item = c.sqlite3_column_int64(statement, 2);
        if (operation <= 0 or ordinal < 0 or item < 0) return error.CorruptStore;
        try capture.appendFmt("{{\"operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"item_ordinal\":\"{d}\",\"rejection\":", .{ operation, ordinal, item });
        try appendNullableColumnString(statement, 3, 32, capture);
        try capture.append(",\"acceptance_position\":");
        try appendNullablePositiveInteger(statement, 4, capture);
        inline for (.{ .{ "name", 5 }, .{ "call_id", 6 }, .{ "arguments", 7 } }) |field| {
            try capture.append(",\"");
            try capture.append(field[0]);
            try capture.append("\":");
            const content_id = c.sqlite3_column_int64(statement, field[1]);
            if (content_id <= 0) return error.CorruptStore;
            try appendInlineContent(self, content_id, capture);
        }
        try capture.append(",\"rejection_result\":");
        if (try sqlite.readNullablePositiveI64(statement, 8)) |content_id| try appendInlineContent(self, content_id, capture) else try capture.append("null");
        try capture.append("}");
    }
}

fn appendAllActions(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
    const statement = try store_core.cached(self, "SELECT action_id,parent_operation_id,call_ordinal,permission_revision," ++
        "CASE WHEN resolution_code IS 'denied' THEN 'denied' WHEN authorized=1 THEN 'authorized' ELSE 'requested' END,resolution_code,resolution_content_id,acceptance_position FROM action_operation WHERE session_ref=?1 ORDER BY action_id");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    var first = true;
    while (try nextReportRow(statement, &first, capture, error.ActionReadFailed)) {
        const action = c.sqlite3_column_int64(statement, 0);
        const parent = c.sqlite3_column_int64(statement, 1);
        const ordinal = c.sqlite3_column_int64(statement, 2);
        const revision = c.sqlite3_column_int64(statement, 3);
        var permission: protocol.Bounded(16) = .{};
        try sqlite.readText(statement, 4, &permission);
        if (action <= 0 or parent <= 0 or ordinal < 0 or revision <= 0) return error.CorruptStore;
        try capture.appendFmt("{{\"action\":\"{d}\",\"parent_operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"permission_revision\":\"{d}\",\"permission\":\"{s}\",\"resolution\":", .{ action, parent, ordinal, revision, permission.slice() });
        try appendNullableColumnString(statement, 5, max_action_resolution_code_bytes, capture);
        try capture.append(",\"result\":");
        if (try sqlite.readNullablePositiveI64(statement, 6)) |content_id| try appendInlineContent(self, content_id, capture) else try capture.append("null");
        try capture.append(",\"acceptance_position\":");
        try appendNullablePositiveInteger(statement, 7, capture);
        try capture.append("}");
    }
}

fn appendPermissionDecisions(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
    const statement = try store_core.cached(self, "SELECT decision.command_key,decision.action_id,decision.decision,command.accepted,command.code FROM permission_decision_command decision JOIN core_command command ON command.command_key=decision.command_key WHERE command.kind=5 AND command.target=?1 ORDER BY command.command_seq");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    var first = true;
    while (try nextReportRow(statement, &first, capture, error.PermissionReadFailed)) {
        try capture.append("{\"command_key\":");
        try appendColumnString(statement, 0, 128, capture);
        try capture.append(",\"action\":");
        try appendColumnString(statement, 1, 20, capture);
        var decision_text: protocol.Bounded(max_permission_decision_bytes) = .{};
        try sqlite.readText(statement, 2, &decision_text);
        const decision = std.meta.stringToEnum(protocol.PermissionDecision, decision_text.slice()) orelse return error.CorruptStore;
        try capture.appendFmt(",\"decision\":\"{s}\",\"status\":\"{s}\",\"code\":", .{
            @tagName(decision),
            if (c.sqlite3_column_int(statement, 3) == 0) "rejected" else "accepted",
        });
        try appendColumnString(statement, 4, 96, capture);
        try capture.append("}");
    }
}

fn appendSessionStops(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
    const statement = try store_core.cached(self, "SELECT command.command_key,command.accepted,command.code,stop.selected_turn_id,stop.admission_cutoff FROM core_command command LEFT JOIN session_stop stop ON stop.command_key=command.command_key WHERE command.kind=3 AND command.target=?1 ORDER BY command.command_seq");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    var first = true;
    while (try nextReportRow(statement, &first, capture, error.SessionStopReadFailed)) {
        try capture.append("{\"command_key\":");
        try appendColumnString(statement, 0, 128, capture);
        try capture.appendFmt(",\"status\":\"{s}\",\"code\":", .{if (c.sqlite3_column_int(statement, 1) == 0) "rejected" else "accepted"});
        try appendColumnString(statement, 2, 96, capture);
        try capture.append(",\"selected_turn\":");
        try appendNullablePositiveInteger(statement, 3, capture);
        try capture.append(",\"admission_cutoff\":");
        try appendNullableNonnegativeInteger(statement, 4, capture);
        try capture.append("}");
    }
}

fn appendModelInterruptions(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
    const statement = try store_core.cached(self, "SELECT command.command_key,command.accepted,command.code,interruption.turn_id,interruption.operation_id FROM model_interruption_command interruption JOIN core_command command ON command.command_key=interruption.command_key WHERE interruption.session_ref=?1 ORDER BY command.command_seq");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    var first = true;
    while (try nextReportRow(statement, &first, capture, error.InterruptionReadFailed)) {
        try capture.append("{\"command_key\":");
        try appendColumnString(statement, 0, 128, capture);
        try capture.appendFmt(",\"status\":\"{s}\",\"code\":", .{if (c.sqlite3_column_int(statement, 1) == 0) "rejected" else "accepted"});
        try appendColumnString(statement, 2, 96, capture);
        try capture.append(",\"turn\":");
        try appendColumnString(statement, 3, 20, capture);
        try capture.append(",\"operation\":");
        try appendColumnString(statement, 4, 20, capture);
        try capture.append("}");
    }
}

fn appendToolResults(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
    const statement = try store_core.cached(
        self,
        "SELECT tool_call.operation_id,tool_call.call_ordinal,coalesce(tool_call.acceptance_position,action.acceptance_position)," ++
            "tool_call.call_id_content_id,coalesce(tool_call.rejection_code,action.resolution_code)," ++
            "coalesce(tool_call.rejection_content_id,action.resolution_content_id) FROM model_tool_call tool_call " ++
            "JOIN model_operation operation ON operation.operation_id=tool_call.operation_id " ++
            "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
            "WHERE operation.session_ref=?1 AND coalesce(tool_call.rejection_code,action.resolution_code) IS NOT NULL " ++
            "ORDER BY tool_call.operation_id,coalesce(tool_call.acceptance_position,action.acceptance_position)",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    var first = true;
    while (try nextReportRow(statement, &first, capture, error.CallReadFailed)) {
        const operation = c.sqlite3_column_int64(statement, 0);
        const ordinal = c.sqlite3_column_int64(statement, 1);
        const position = c.sqlite3_column_int64(statement, 2);
        const call_id = c.sqlite3_column_int64(statement, 3);
        const result = c.sqlite3_column_int64(statement, 5);
        if (operation <= 0 or ordinal < 0 or position <= 0 or call_id <= 0 or result <= 0) return error.CorruptStore;
        try capture.appendFmt("{{\"operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"acceptance_position\":\"{d}\",\"call_id\":", .{ operation, ordinal, position });
        try appendInlineContent(self, call_id, capture);
        try capture.append(",\"code\":");
        try appendColumnString(statement, 4, 32, capture);
        try capture.append(",\"result\":");
        try appendInlineContent(self, result, capture);
        try capture.append("}");
    }
}

fn appendReferencedOutcome(self: *Store, statement: *c.sqlite3_stmt, code_index: c_int, content_id_index: c_int, capture: *SessionReportCapture) !void {
    if (c.sqlite3_column_type(statement, code_index) == c.SQLITE_NULL) {
        if (c.sqlite3_column_type(statement, content_id_index) != c.SQLITE_NULL) return error.CorruptStore;
        return capture.append("null");
    }
    try capture.append("{\"code\":");
    try appendColumnString(statement, code_index, 96, capture);
    try capture.append(",\"content\":");
    if (try sqlite.readNullablePositiveI64(statement, content_id_index)) |content_id| {
        const metadata = try content_domain.readContentMetadata(self, content_id);
        try capture.appendBareContentReference(.{ .length = metadata.length, .digest = metadata.digest });
    } else try capture.append("null");
    try capture.append("}");
}

fn appendInlineOutcome(self: *Store, statement: *c.sqlite3_stmt, code_index: c_int, content_id_index: c_int, capture: *SessionReportCapture) !void {
    if (c.sqlite3_column_type(statement, code_index) == c.SQLITE_NULL) {
        if (c.sqlite3_column_type(statement, content_id_index) != c.SQLITE_NULL) return error.CorruptStore;
        return capture.append("null");
    }
    try capture.append("{\"code\":");
    try appendColumnString(statement, code_index, 96, capture);
    try capture.append(",\"content\":");
    if (try sqlite.readNullablePositiveI64(statement, content_id_index)) |content_id| try appendInlineContent(self, content_id, capture) else try capture.append("null");
    try capture.append("}");
}

fn appendInlineContent(self: *Store, content_id: i64, capture: *SessionReportCapture) !void {
    const metadata = try content_domain.readContentMetadata(self, content_id);
    var source: ContentSource = .{ .store = self, .end = metadata.length };
    source.reader.open(.{ .store = self, .content_id = content_id, .reference = .{ .length = metadata.length, .digest = metadata.digest } });
    defer source.reader.close();
    try capture.appendFmt("{{\"type\":\"text\",\"bytes\":\"{d}\",\"sha256\":\"", .{metadata.length});
    try capture.append(&std.fmt.bytesToHex(metadata.digest, .lower));
    try capture.append("\",\"text\":\"");
    while (try source.nextWindow()) |bytes| try capture.appendJsonStringBytes(bytes);
    try capture.append("\"}");
}

pub fn countActions(self: *Store, session_ref: []const u8) !u64 {
    const statement = try store_core.cached(
        self,
        "SELECT count(*) FROM turn active INDEXED BY turn_one_active_per_session " ++
            "CROSS JOIN model_operation operation INDEXED BY model_operation_turn_history " ++
            "ON operation.turn_id=active.turn_id " ++
            "CROSS JOIN action_operation action ON action.parent_operation_id=operation.operation_id " ++
            "WHERE active.session_ref=?1 AND active.outcome_code IS NULL",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.ActionReadFailed;
    const value = c.sqlite3_column_int64(statement, 0);
    if (value < 0) return error.CorruptStore;
    return @intCast(value);
}

pub fn countRejectedCalls(self: *Store, session_ref: []const u8) !u64 {
    const statement = try store_core.cached(
        self,
        "SELECT count(*) FROM turn active INDEXED BY turn_one_active_per_session " ++
            "CROSS JOIN model_operation operation INDEXED BY model_operation_turn_history " ++
            "ON operation.turn_id=active.turn_id " ++
            "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=operation.operation_id " ++
            "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND tool_call.rejection_code IS NOT NULL",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CallReadFailed;
    const value = c.sqlite3_column_int64(statement, 0);
    if (value < 0) return error.CorruptStore;
    return @intCast(value);
}

pub fn validateActiveTurnToolCalls(self: *Store, session_ref: []const u8) !void {
    const statement = try store_core.cached(
        self,
        "SELECT operation.operation_id FROM turn active INDEXED BY turn_one_active_per_session " ++
            "CROSS JOIN model_operation operation INDEXED BY model_operation_turn_history " ++
            "ON operation.turn_id=active.turn_id " ++
            "WHERE active.session_ref=?1 " ++
            "AND active.outcome_code IS NULL AND " ++ store_schema.resolutionIs("operation.resolution_code", .tool_proposals) ++ " " ++
            "ORDER BY operation.operation_id",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    while (true) switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {
            const operation_id = c.sqlite3_column_int64(statement, 0);
            if (operation_id <= 0) return error.CorruptStore;
            _ = try readToolOutcomeFacts(self, @intCast(operation_id), false);
        },
        c.SQLITE_DONE => return,
        else => return error.CallReadFailed,
    };
}

const ToolOutcomeFacts = struct {
    position: ?u64,
    call_count: u64,
};

/// Validates the immutable function-call cardinality and every canonical
/// classification row. When terminal outcomes are required, it also
/// proves that each accepted call has a canonical result.
pub fn readToolOutcomeFacts(
    self: *Store,
    operation_id: u64,
    require_terminal: bool,
) !ToolOutcomeFacts {
    const statement = try store_core.cached(
        self,
        "SELECT (SELECT count(*) FROM model_output_item expected " ++
            "WHERE expected.operation_id=?1 AND expected.item_kind=3),count(tool_call.operation_id)," ++
            "coalesce(sum(CASE WHEN item.operation_id IS NOT NULL AND item.item_kind=3 " ++
            "AND name.content_id IS NOT NULL AND call_id.content_id IS NOT NULL " ++
            "AND arguments.content_id IS NOT NULL AND ((tool_call.rejection_code IS NOT NULL " ++
            "AND rejection.content_id IS NOT NULL AND tool_call.acceptance_position IS NOT NULL " ++
            "AND action.action_id IS NULL) OR (tool_call.rejection_code IS NULL AND action.action_id IS NOT NULL " ++
            "AND ((action.resolution_code IS NULL AND action.resolution_content_id IS NULL " ++
            "AND action.acceptance_position IS NULL) OR (action.resolution_code IS NOT NULL " ++
            "AND result.content_id IS NOT NULL AND action.acceptance_position IS NOT NULL)))) THEN 1 ELSE 0 END),0)," ++
            "coalesce(sum(CASE WHEN tool_call.rejection_code IS NOT NULL AND rejection.content_id IS NOT NULL " ++
            "AND tool_call.acceptance_position IS NOT NULL OR tool_call.rejection_code IS NULL " ++
            "AND action.resolution_code IS NOT NULL AND result.content_id IS NOT NULL " ++
            "AND action.acceptance_position IS NOT NULL THEN 1 ELSE 0 END),0)," ++
            "max(coalesce(tool_call.acceptance_position,action.acceptance_position)) " ++
            "FROM model_tool_call tool_call LEFT JOIN model_output_item item ON item.operation_id=tool_call.operation_id " ++
            "AND item.item_ordinal=tool_call.item_ordinal " ++
            "LEFT JOIN content name ON name.content_id=tool_call.name_content_id " ++
            "LEFT JOIN content call_id ON call_id.content_id=tool_call.call_id_content_id " ++
            "LEFT JOIN content arguments ON arguments.content_id=tool_call.arguments_content_id " ++
            "LEFT JOIN content rejection ON rejection.content_id=tool_call.rejection_content_id " ++
            "LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id " ++
            "AND action.call_ordinal=tool_call.call_ordinal LEFT JOIN content result " ++
            "ON result.content_id=action.resolution_content_id WHERE tool_call.operation_id=?1",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, operation_id);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CallReadFailed;
    const expected = c.sqlite3_column_int64(statement, 0);
    const calls = c.sqlite3_column_int64(statement, 1);
    const valid = c.sqlite3_column_int64(statement, 2);
    const terminal = c.sqlite3_column_int64(statement, 3);
    if (expected <= 0 or calls != expected or valid != expected or
        (require_terminal and terminal != expected)) return error.CorruptStore;
    const position = try sqlite.readNullablePositiveI64(statement, 4);
    if (require_terminal and position == null) return error.CorruptStore;
    const sources = try store_core.cached(self, "SELECT item.session_ref,item.session_position FROM model_tool_call tool_call " ++
        "LEFT JOIN model_output_item item ON item.operation_id=tool_call.operation_id AND item.item_ordinal=tool_call.item_ordinal " ++
        "WHERE tool_call.operation_id=?1 ORDER BY tool_call.call_ordinal");
    defer sqlite.resetCached(sources);
    try sqlite.bindU64(sources, 1, operation_id);
    while (true) {
        const step = c.sqlite3_step(sources);
        if (step == c.SQLITE_DONE) break;
        if (step != c.SQLITE_ROW) return error.CallReadFailed;
        var session: protocol.Bounded(protocol.max_session_bytes) = .{};
        try sqlite.readText(sources, 0, &session);
        const source_position = try sqlite.readNullablePositiveI64(sources, 1) orelse return error.CorruptStore;
        _ = try reads_domain.proposalLocked(self, session.slice(), @intCast(source_position));
    }
    return .{
        .position = if (terminal == expected) (if (position) |value| @intCast(value) else null) else null,
        .call_count = @intCast(calls),
    };
}

fn nextReportRow(statement: *c.sqlite3_stmt, first: *bool, capture: *SessionReportCapture, read_error: anyerror) !bool {
    const result = c.sqlite3_step(statement);
    if (result == c.SQLITE_DONE) return false;
    if (result != c.SQLITE_ROW) return read_error;
    if (!first.*) try capture.append(",");
    first.* = false;
    return true;
}

fn appendColumnString(statement: *c.sqlite3_stmt, index: c_int, comptime capacity: usize, capture: *SessionReportCapture) !void {
    try capture.appendJsonString(try sqlite.boundedColumnText(statement, index, capacity));
}

fn appendNullableColumnString(statement: *c.sqlite3_stmt, index: c_int, comptime capacity: usize, capture: *SessionReportCapture) !void {
    if (c.sqlite3_column_type(statement, index) == c.SQLITE_NULL) return capture.append("null");
    try appendColumnString(statement, index, capacity, capture);
}

fn appendNullablePositiveInteger(statement: *c.sqlite3_stmt, index: c_int, capture: *SessionReportCapture) !void {
    if (c.sqlite3_column_type(statement, index) == c.SQLITE_NULL) return capture.append("null");
    const value = c.sqlite3_column_int64(statement, index);
    if (value <= 0) return error.CorruptStore;
    try capture.appendFmt("\"{d}\"", .{value});
}

fn appendNullableNonnegativeInteger(statement: *c.sqlite3_stmt, index: c_int, capture: *SessionReportCapture) !void {
    if (c.sqlite3_column_type(statement, index) == c.SQLITE_NULL) return capture.append("null");
    const value = c.sqlite3_column_int64(statement, index);
    if (value < 0) return error.CorruptStore;
    try capture.appendFmt("\"{d}\"", .{value});
}

fn appendNullableEffort(value: ?protocol.ReasoningEffort, capture: *SessionReportCapture) !void {
    if (value) |effort| return capture.appendJsonString(@tagName(effort));
    try capture.append("null");
}
