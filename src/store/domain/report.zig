//! Session reports and lists rendered as JSON, and failed-response capture.

const std = @import("std");
const attempt = @import("../../attempt.zig");
const named_scratch = @import("../../named_scratch.zig");
const protocol = @import("../../protocol.zig");
const model_capability = @import("../../model_capability.zig");
const tool_catalog = @import("../../tools.zig");
const turn_policy = @import("../../turn_policy.zig");
const session_work = @import("../../session_work.zig");
const change_ring = @import("../../change_ring.zig");
const store_core = @import("../Store.zig");
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
        if (tools_mask > tool_catalog.toolBit(.bash)) return error.CorruptStore;
        try self.append("[");
        if (tools_mask & tool_catalog.toolBit(.bash) != 0) try self.append("\"bash\"");
        try self.append("]");
    }

    fn appendPermissionMode(self: *SessionReportCapture, permission_mode: u8) !void {
        try self.appendJsonString(switch (permission_mode) {
            0 => "ask",
            1 => "bypass",
            else => return error.CorruptStore,
        });
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

pub fn failedResponseBindingLocked(self: *Store, session: []const u8, selection: protocol.FailedResponseExport) !AttemptBinding {
    const statement = try store_core.cached(self, "SELECT turn_id FROM model_operation WHERE operation_id=?1 AND session_ref=?2 AND attempt_ordinal>=?3");
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, selection.operation);
    try sqlite.bindText(statement, 2, session);
    try sqlite.bindU64(statement, 3, selection.attempt);
    switch (c.sqlite3_step(statement)) {
        c.SQLITE_DONE => return error.ContentNotFound,
        c.SQLITE_ROW => {},
        else => return error.OperationReadFailed,
    }
    return .{
        .turn_id = @intCast(try sqlite.readNullablePositiveI64(statement, 0) orelse return error.CorruptStore),
        .operation_id = selection.operation,
        .attempt_ordinal = selection.attempt,
    };
}

pub fn renderSessionListLocked(self: *Store, request: *const protocol.ListSessions, capture: *SessionReportCapture) !void {
    const generation = self.commit_generation.load(.acquire);
    // Changed rows answer while the hint still covers the token; a token
    // from another opening, or one too old, gets a full traversal.
    if (request.since) |since| {
        const through = if (request.changed) |changed| changed.through else generation;
        if (std.mem.eql(u8, &since.instance, &self.instance) and through <= generation and self.changes.covers(since.generation))
            return renderChangedSessionsLocked(self, request, since.generation, through, capture);
    }
    try renderAllSessionsLocked(self, request, generation, capture);
}

/// Every Session in scope, in creation order, eight per page. A full
/// traversal reads only the request's scope, `after` and `ceiling`.
fn renderAllSessionsLocked(self: *Store, request: *const protocol.ListSessions, generation: u64, capture: *SessionReportCapture) !void {
    var ceiling = request.ceiling;
    if (request.after == 0) {
        const maximum = try store_core.cached(self, "SELECT coalesce(max(created_seq),0) FROM session");
        defer sqlite.resetCached(maximum);
        if (c.sqlite3_step(maximum) != c.SQLITE_ROW) return error.SessionReadFailed;
        const value = c.sqlite3_column_int64(maximum, 0);
        if (value < 0) return error.CorruptStore;
        ceiling = @intCast(value);
    }
    // The page's references first, so no list cursor stays open while
    // each row's own facts are read.
    var references: [protocol.session_list_page_size]protocol.Bounded(protocol.max_session_bytes) = undefined;
    var count: usize = 0;
    var last: u64 = 0;
    var more = false;
    {
        const statement = if (request.workspace == null)
            try store_core.cached(self, "SELECT created_seq,session_ref FROM session WHERE created_seq>?1 AND created_seq<=?2 ORDER BY created_seq LIMIT 9")
        else
            try store_core.cached(self, "SELECT created_seq,session_ref FROM session INDEXED BY session_workspace_list WHERE workspace_digest=?3 AND workspace=?4 AND created_seq>?1 AND created_seq<=?2 ORDER BY created_seq LIMIT 9");
        defer sqlite.resetCached(statement);
        try sqlite.bindU64(statement, 1, request.after);
        try sqlite.bindU64(statement, 2, ceiling);
        var digest: [32]u8 = undefined;
        if (request.workspace) |*workspace| {
            digest = store_core.workspaceDigest(workspace.slice());
            try sqlite.bindBlob(statement, 3, &digest);
            try sqlite.bindText(statement, 4, workspace.slice());
        }
        while (true) {
            const step = c.sqlite3_step(statement);
            if (step == c.SQLITE_DONE) break;
            if (step != c.SQLITE_ROW) return error.SessionReadFailed;
            if (count == protocol.session_list_page_size) {
                more = true;
                break;
            }
            const id = c.sqlite3_column_int64(statement, 0);
            if (id <= 0) return error.CorruptStore;
            last = @intCast(id);
            references[count] = .{};
            try sqlite.readText(statement, 1, &references[count]);
            count += 1;
        }
    }
    var shown: [protocol.session_list_page_size][]const u8 = undefined;
    for (references[0..count], 0..) |*reference, index| shown[index] = reference.slice();
    try appendSessionRows(self, shown[0..count], capture);
    var token: [protocol.SinceToken.max_bytes]u8 = undefined;
    const since = (protocol.SinceToken{ .instance = self.instance, .generation = generation }).format(&token);
    if (more)
        try capture.appendShape(protocol.session_list_reply.full_tail, .{ protocol.ListDelta.full, since, last, ceiling })
    else
        try capture.appendShape(protocol.session_list_reply.last_tail, .{ protocol.ListDelta.full, since });
    std.debug.assert(capture.length + capture.buffered <= protocol.session_list_reply.max_bytes);
}

/// The Sessions in scope that the hint says changed in (since, through],
/// in ID order, eight per page: one pass over the ring in memory, then
/// each shown row's own read. A Session it names may be unchanged; one
/// it omits did not change.
fn renderChangedSessionsLocked(self: *Store, request: *const protocol.ListSessions, since: u64, through: u64, capture: *SessionReportCapture) !void {
    const workspace: ?u64 = if (request.workspace) |*scope| try store_core.readWorkspaceKey(self, scope.slice()) else null;
    const after: ?*const change_ring.Id = if (request.changed) |*changed| &changed.after_reference else null;
    var references: [protocol.session_list_page_size + 1]change_ring.Id = undefined;
    const changed = self.changes.changed(since, through, workspace, after, &references);
    var shown: [protocol.session_list_page_size][]const u8 = undefined;
    const count = @min(changed.len, shown.len);
    for (changed[0..count], 0..) |*id, index| shown[index] = id;
    try appendSessionRows(self, shown[0..count], capture);
    var token: [protocol.SinceToken.max_bytes]u8 = undefined;
    const next = (protocol.SinceToken{ .instance = self.instance, .generation = through }).format(&token);
    if (changed.len > count)
        try capture.appendShape(protocol.session_list_reply.changed_tail, .{ protocol.ListDelta.changed, next, through, &changed[count - 1] })
    else
        try capture.appendShape(protocol.session_list_reply.last_tail, .{ protocol.ListDelta.changed, next });
    std.debug.assert(capture.length + capture.buffered <= protocol.session_list_reply.max_bytes);
}

/// The page head and its rows, each read fresh under this lock.
fn appendSessionRows(self: *Store, references: []const []const u8, capture: *SessionReportCapture) !void {
    const now_ms = try store_core.readUnixMilliseconds(self.io);
    try capture.appendShape(protocol.session_list_reply.head, .{});
    var row: protocol.SessionRow = .{ .reference = .{ .len = 0 }, .workspace = .{ .len = 0 }, .model = .{ .len = 0 } };
    for (references, 0..) |reference, index| {
        if (index != 0) try capture.append(",");
        try readSessionRowLocked(self, reference, now_ms, &row);
        try capture.appendShape(.{protocol.Hole{ .json = protocol.SessionRow }}, .{&row});
    }
}

/// One list row: the Session's settings, then a fixed number of seeks
/// into its own indexed rows, none of which grows with its history.
pub fn readSessionRowLocked(self: *Store, session_ref: []const u8, now_ms: i64, row: *protocol.SessionRow) !void {
    // Every field of `row` is written below, so the previous row's
    // values need no reset.
    {
        // The settings land straight in the row: no configuration copy.
        const statement = try store_core.cached(self, "SELECT workspace,provider,model,tools_mask,permission_mode,label,created_at,revision,next_position FROM session WHERE session_ref=?1");
        defer sqlite.resetCached(statement);
        try sqlite.bindText(statement, 1, session_ref);
        switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => {},
            c.SQLITE_DONE => return error.CorruptStore,
            else => return error.SessionReadFailed,
        }
        try sqlite.readText(statement, 0, &row.workspace);
        row.provider = try sqlite.readProvider(statement, 1);
        try sqlite.readText(statement, 2, &row.model);
        row.bash = try sqlite.readToolsMask(statement, 3) & tool_catalog.toolBit(.bash) != 0;
        row.permission_mode = if (try sqlite.readPermissionMode(statement, 4) == 0) .ask else .bypass;
        row.label = try sqlite.readNullableLabel(statement, 5);
        row.created_at = @intCast(try sqlite.readNullablePositiveI64(statement, 6) orelse return error.CorruptStore);
        row.revision = try sqlite.readPositiveU64(statement, 7);
        row.end = try sqlite.readPositiveU64(statement, 8) - 1;
    }
    row.first_message = try readFirstMessageLocked(self, session_ref);
    row.work = .fromCore((try readWorkLocked(self, session_ref, row.created_at, now_ms)).work);
    row.peers = try readPeerFactsLocked(self, session_ref);
    try row.reference.set(session_ref);
}

/// One seek: the latest Message with no Session sender.
fn readPeerFactsLocked(self: *Store, session_ref: []const u8) !protocol.PeerFacts {
    const statement = try store_core.cached(self, "SELECT admitted_at FROM message_admission INDEXED BY message_admission_person " ++
        "WHERE session_ref=?1 AND sender_session_ref IS NULL ORDER BY admission_position DESC LIMIT 1");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    return switch (c.sqlite3_step(statement)) {
        c.SQLITE_DONE => .{},
        c.SQLITE_ROW => .{ .from_person_at = @intCast(try sqlite.readNullablePositiveI64(statement, 0) orelse return error.CorruptStore) },
        else => error.SessionReadFailed,
    };
}

/// A Turn binds queued Messages in admission order, so the first Turn's
/// first admission precedes every other bound one. The only other
/// candidate is the oldest Message never bound: queued, or excluded by a
/// stop. Two seeks, then the earlier admission's own row.
fn readFirstMessageLocked(self: *Store, session_ref: []const u8) !?protocol.FirstMessage {
    var first: ?u64 = null;
    inline for (.{
        "SELECT first_admission_id FROM turn INDEXED BY turn_session_latest WHERE session_ref=?1 ORDER BY turn_id LIMIT 1",
        "SELECT admission_id FROM message_admission INDEXED BY message_admission_session_pending WHERE session_ref=?1 AND turn_id IS NULL ORDER BY admission_id LIMIT 1",
    }) |sql| {
        const statement = try store_core.cached(self, sql);
        defer sqlite.resetCached(statement);
        try sqlite.bindText(statement, 1, session_ref);
        switch (c.sqlite3_step(statement)) {
            c.SQLITE_DONE => {},
            c.SQLITE_ROW => {
                const admission: u64 = @intCast(try sqlite.readNullablePositiveI64(statement, 0) orelse return error.CorruptStore);
                first = if (first) |earlier| @min(earlier, admission) else admission;
            },
            else => return error.SessionReadFailed,
        }
    }
    const admission = first orelse return null;
    const statement = try store_core.cached(self, "SELECT admission_position,admitted_at,sender_session_ref,content_id FROM message_admission WHERE admission_id=?1 AND session_ref=?2");
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, admission);
    try sqlite.bindText(statement, 2, session_ref);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    const metadata = try content_domain.readPublicContentMetadata(self, try sqlite.readNullablePositiveI64(statement, 3) orelse return error.CorruptStore);
    return .{
        .position = @intCast(try sqlite.readNullablePositiveI64(statement, 0) orelse return error.CorruptStore),
        .admission = admission,
        .admitted_at = @intCast(try sqlite.readNullablePositiveI64(statement, 1) orelse return error.CorruptStore),
        .sender = try reads_domain.readPeer(self, statement, 2),
        .content = .{ .length = metadata.length, .digest = metadata.digest },
    };
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
    try appendCurrentWork(self, session_ref, current.created_at, capture);
    try capture.append(",\"peers\":");
    try capture.appendShape(.{protocol.Hole{ .json = protocol.PeerFacts }}, .{try readPeerFactsLocked(self, session_ref)});
    try capture.append(",\"first_message\":");
    try capture.appendShape(.{protocol.Hole{ .optional_json = protocol.FirstMessage }}, .{try readFirstMessageLocked(self, session_ref)});
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

fn appendCurrentWork(self: *Store, session_ref: []const u8, created_at: u64, capture: *SessionReportCapture) !void {
    const read = try readWorkLocked(self, session_ref, created_at, try store_core.readUnixMilliseconds(self.io));
    const work: protocol.SessionWork = .fromCore(read.work);
    try capture.appendShape(.{"{"} ++ protocol.SessionWork.fields, work.args());
    const outcome = read.outcome orelse return capture.append(",\"latest_outcome\":null}");
    try capture.append(",\"latest_outcome\":{\"code\":");
    try capture.appendJsonString(outcome.code.slice());
    try capture.append(",\"content\":");
    if (outcome.content_id) |content_id| {
        const metadata = try content_domain.readContentMetadata(self, content_id);
        try capture.appendBareContentReference(.{ .length = metadata.length, .digest = metadata.digest });
    } else {
        try capture.append("null");
    }
    try capture.append("}}");
}

const WorkRead = struct {
    work: session_work.Work,
    /// The latest Turn's outcome, once it has one.
    outcome: ?struct { code: protocol.Bounded(protocol.max_code_bytes), content_id: ?i64 } = null,
};

/// The Session's work now: a fixed set of seeks under the caller's lock,
/// none of which reads history, then `session_work.derive`. List rows,
/// activity pages, Current and Message progress all read work here.
pub fn readWorkLocked(self: *Store, session_ref: []const u8, created_at: u64, now_ms: i64) !WorkRead {
    var inputs: session_work.Inputs = .{ .now_ms = @intCast(now_ms), .created_at = created_at };
    var read: WorkRead = .{ .work = undefined };
    var cause: protocol.Bounded(protocol.max_code_bytes) = .{};
    var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    // The quota diagnostic is read only for a failed outcome, and only
    // while it is small enough to be one.
    const latest = try store_core.cached(
        self,
        "SELECT t.turn_id,t.operation_id,t.input_cutoff,t.outcome_code,t.outcome_content_id,t.outcome_at,t.outcome_position," ++
            "o.resolution_code,o.retry_due_at_ms,o.last_failure_code,o.attempt_ordinal,o.attempt_at,o.retry_scheduled_at,o.resolved_at," ++
            "(SELECT payload FROM content WHERE content_id=o.resolution_content_id AND byte_length<=512 AND t.outcome_code NOT IN ('completed','cancelled'))," ++
            "(SELECT stopped_at FROM session_stop INDEXED BY session_stop_turn WHERE selected_turn_id=t.turn_id ORDER BY position LIMIT 1) " ++
            "FROM turn t INDEXED BY turn_session_latest JOIN model_operation o ON o.operation_id=t.operation_id " ++
            "WHERE t.session_ref=?1 ORDER BY t.turn_id DESC LIMIT 1",
    );
    defer sqlite.resetCached(latest);
    try sqlite.bindText(latest, 1, session_ref);
    switch (c.sqlite3_step(latest)) {
        c.SQLITE_DONE => {},
        c.SQLITE_ROW => {
            var turn: session_work.Inputs.Turn = .{
                .turn_id = try sqlite.readPositive(latest, 0),
                .operation_id = try sqlite.readPositive(latest, 1),
                .input_cutoff = try sqlite.readPositive(latest, 2),
                .stopped_at = try sqlite.readOptionalPositive(latest, 15),
                .op = undefined,
            };
            if (c.sqlite3_column_type(latest, 7) != c.SQLITE_NULL) {
                var resolution: protocol.Bounded(protocol.max_code_bytes) = .{};
                try sqlite.readText(latest, 7, &resolution);
                turn.op = .{ .resolved = .{ .resolution = turn_policy.Resolution.parse(resolution.slice()), .at = try sqlite.readPositive(latest, 13) } };
            } else if (c.sqlite3_column_int64(latest, 8) == 0) {
                turn.op = .{ .in_flight = .{ .attempt_at = try sqlite.readPositive(latest, 11) } };
            } else {
                if (c.sqlite3_column_type(latest, 9) == c.SQLITE_NULL) return error.CorruptStore;
                try sqlite.readText(latest, 9, &cause);
                turn.op = .{ .waiting = .{
                    .scheduled_at = try sqlite.readPositive(latest, 12),
                    .due_at_ms = try sqlite.readPositive(latest, 8),
                    .cause = cause.slice(),
                    .attempt = try sqlite.readPositive(latest, 10),
                } };
            }
            if (c.sqlite3_column_type(latest, 3) != c.SQLITE_NULL) {
                var code: protocol.Bounded(protocol.max_code_bytes) = .{};
                try sqlite.readText(latest, 3, &code);
                const content_id = try sqlite.readNullablePositiveI64(latest, 4);
                read.outcome = .{ .code = code, .content_id = content_id };
                turn.terminal = .{
                    .outcome = switch (try TurnOutcome.decode(code.slice(), content_id)) {
                        .completed => .completed,
                        .cancelled => .cancelled,
                        .retry_exhausted, .resource_exceeded, .failed => .failed,
                    },
                    .code = read.outcome.?.code.slice(),
                    .at = try sqlite.readPositive(latest, 5),
                    .position = try sqlite.readPositive(latest, 6),
                    .diagnostic = if (c.sqlite3_column_type(latest, 14) == c.SQLITE_BLOB) sqlite.columnBytes(latest, 14) else null,
                };
            } else {
                turn.actions = try readWorkActions(self, turn.operation_id, &description);
            }
            inputs.latest = turn;
        },
        else => return error.TurnReadFailed,
    }
    if (inputs.latest == null or inputs.latest.?.terminal != null) try readWorkQueue(self, session_ref, &inputs);
    read.work = try session_work.derive(inputs);
    return read;
}

/// One aggregate over the Operation's Actions, bounded by its calls, and
/// the oldest running Action's call ordinal and saved description.
fn readWorkActions(self: *Store, operation_id: u64, description: *protocol.Bounded(protocol.max_tool_description_bytes)) !session_work.Inputs.Actions {
    const group = try store_core.cached(
        self,
        "SELECT count(*),count(*) FILTER (WHERE a.resolution_code IS NULL)," ++
            "count(*) FILTER (WHERE a.resolution_code IS NULL AND a.authorized=0)," ++
            "min(CASE WHEN a.resolution_code IS NULL AND a.authorized=0 THEN a.action_id END)," ++
            "count(*) FILTER (WHERE a.resolution_code IS NULL AND a.attempt_ordinal=1)," ++
            // The last resolution is the one at the greatest position.
            "(SELECT resolved_at FROM action_operation WHERE parent_operation_id=?1 AND resolution_code IS NOT NULL ORDER BY acceptance_position DESC LIMIT 1)," ++
            // Under an `ask` revision only an `allow_once` decision
            // authorizes; under `bypass` the proposal did.
            "max(a.decided_at) FILTER (WHERE a.resolution_code IS NULL AND r.permission_mode=0) " ++
            "FROM action_operation a LEFT JOIN session_revision r ON r.session_ref=a.session_ref AND r.revision=a.permission_revision " ++
            "WHERE a.parent_operation_id=?1",
    );
    defer sqlite.resetCached(group);
    try sqlite.bindU64(group, 1, operation_id);
    if (c.sqlite3_step(group) != c.SQLITE_ROW) return error.ActionReadFailed;
    var actions: session_work.Inputs.Actions = .{
        .total = try sqlite.readCount(group, 0),
        .unresolved = try sqlite.readCount(group, 1),
        .awaiting = try sqlite.readCount(group, 2),
        .first_awaiting = try sqlite.readOptionalPositive(group, 3),
        .running = try sqlite.readCount(group, 4),
        .latest_resolution_at = try sqlite.readOptionalPositive(group, 5),
        .latest_decision_at = try sqlite.readOptionalPositive(group, 6),
    };
    if (actions.running == 0) return actions;
    const oldest = try store_core.cached(
        self,
        "SELECT a.attempt_at,tool_call.description,a.call_ordinal FROM action_operation a " ++
            "JOIN model_tool_call tool_call ON tool_call.operation_id=a.parent_operation_id AND tool_call.call_ordinal=a.call_ordinal " ++
            "WHERE a.parent_operation_id=?1 AND a.resolution_code IS NULL AND a.attempt_ordinal=1 ORDER BY a.attempt_at,a.action_id LIMIT 1",
    );
    defer sqlite.resetCached(oldest);
    try sqlite.bindU64(oldest, 1, operation_id);
    if (c.sqlite3_step(oldest) != c.SQLITE_ROW) return error.CorruptStore;
    const described = c.sqlite3_column_type(oldest, 1) != c.SQLITE_NULL;
    if (described) try sqlite.readText(oldest, 1, description);
    actions.oldest_running = .{ .at = try sqlite.readPositive(oldest, 0), .call = try sqlite.readCount(oldest, 2), .description = if (described) description.slice() else null };
    return actions;
}

/// Without an active Turn: the oldest eligible queued Message, else the
/// newest stop-excluded one and the earliest stop that excluded it.
fn readWorkQueue(self: *Store, session_ref: []const u8, inputs: *session_work.Inputs) !void {
    const cutoff = try command_domain.latestSessionStopCutoff(self, session_ref);
    const queued = try store_core.cached(
        self,
        "SELECT admitted_at,admission_position FROM message_admission INDEXED BY message_admission_session_pending " ++
            "WHERE session_ref=?1 AND turn_id IS NULL AND admission_id>?2 ORDER BY admission_id LIMIT 1",
    );
    defer sqlite.resetCached(queued);
    try sqlite.bindText(queued, 1, session_ref);
    try sqlite.bindU64(queued, 2, cutoff);
    switch (c.sqlite3_step(queued)) {
        c.SQLITE_ROW => {
            inputs.oldest_pending = .{ .at = try sqlite.readPositive(queued, 0), .position = try sqlite.readPositive(queued, 1) };
            return;
        },
        c.SQLITE_DONE => {},
        else => return error.MessageAdmissionReadFailed,
    }
    if (cutoff == 0) return;
    const excluded = try store_core.cached(
        self,
        "SELECT admission_id FROM message_admission INDEXED BY message_admission_session_pending " ++
            "WHERE session_ref=?1 AND turn_id IS NULL AND admission_id<=?2 ORDER BY admission_id DESC LIMIT 1",
    );
    defer sqlite.resetCached(excluded);
    try sqlite.bindText(excluded, 1, session_ref);
    try sqlite.bindU64(excluded, 2, cutoff);
    const admission = switch (c.sqlite3_step(excluded)) {
        c.SQLITE_ROW => try sqlite.readPositive(excluded, 0),
        c.SQLITE_DONE => return,
        else => return error.MessageAdmissionReadFailed,
    };
    const stop = try store_core.cached(
        self,
        "SELECT position,stopped_at FROM session_stop INDEXED BY session_stop_exclusion " ++
            "WHERE session_ref=?1 AND admission_cutoff>=?2 ORDER BY admission_cutoff,position LIMIT 1",
    );
    defer sqlite.resetCached(stop);
    try sqlite.bindText(stop, 1, session_ref);
    try sqlite.bindU64(stop, 2, admission);
    if (c.sqlite3_step(stop) != c.SQLITE_ROW) return error.CorruptStore;
    inputs.excluded = .{ .admission = admission, .stop_position = try sqlite.readPositive(stop, 0), .stop_at = try sqlite.readPositive(stop, 1) };
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

fn appendSessionRevisions(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
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
        if (revision <= 0 or tools < 0 or tools > tool_catalog.toolBit(.bash) or permission < 0 or permission > 1 or instructions_id <= 0) return error.CorruptStore;
        try capture.appendFmt("{{\"revision\":\"{d}\",\"command_key\":", .{revision});
        try appendColumnString(statement, 1, 128, capture);
        try capture.append(",\"workspace\":");
        try appendColumnString(statement, 2, protocol.max_workspace_bytes, capture);
        try capture.append(",\"provider\":");
        try capture.appendJsonString(@tagName(try sqlite.readProvider(statement, 12)));
        try capture.append(",\"model\":");
        try appendColumnString(statement, 3, protocol.max_model_bytes, capture);
        try capture.append(",\"compaction_trigger\":");
        try appendNullablePositiveInteger(statement, 13, capture);
        try capture.append(",\"output_reservation\":");
        try appendNullableNonnegativeInteger(statement, 14, capture);
        try capture.append(",\"reasoning_effort\":");
        try appendNullableEffort(try sqlite.readNullableEffort(statement, 15), capture);
        try capture.append(",\"label\":");
        if (try sqlite.readNullableLabel(statement, 16)) |*label| try capture.appendJsonString(label.slice()) else try capture.append("null");
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
