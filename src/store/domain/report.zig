const std = @import("std");
const obligation = @import("session_obligation.zig");
const attempt = @import("../../attempt.zig");
const named_scratch = @import("../../named_scratch.zig");
const session_report = @import("../../session_report.zig");
const workspace_path = @import("../../workspace_path.zig");
const outcome_code = @import("../../outcome_code.zig");
const tool_presentation = @import("../../tool_presentation.zig");
const tool_name = @import("../../tool_name.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const mutation_answer = @import("../../mutation_answer.zig");
const provider_name = @import("../../provider_name.zig");
const session_archive = @import("../../session_archive.zig");
const session_id = @import("../../session_id.zig");
const session_list = @import("../../session_list.zig");
const ScratchBudget = @import("../../ScratchBudget.zig");
const model_capability = @import("../../model_capability.zig");
const tool_defs = @import("../../tool_record.zig");
const tool_set = @import("tool_set.zig");
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
const skills_domain = @import("skills.zig");
const reads_domain = @import("reads.zig");
const store_schema = @import("../schema.zig");
const turn_domain = @import("turn.zig");
const AttemptBinding = store_core.AttemptBinding;
const TurnOutcome = turn_domain.TurnOutcome;
const max_action_resolution_code_bytes = action_domain.max_action_resolution_code_bytes;
const max_permission_decision_bytes = command_domain.max_permission_decision_bytes;
pub const ReadAccess = reads_domain.ReadAccess;
const SessionText = Bounded(session_id.max_reference_bytes);
const Code = Bounded(outcome_code.max_bytes);

pub const SessionReport = struct {
    pub const read_window_bytes = 64 * 1024;

    io: std.Io,
    file: std.Io.File,
    length: u64,
    charged: u64,
    budget: ScratchBudget,

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
    budget: ScratchBudget,
    buffer: [buffer_bytes]u8 = undefined,
    buffered: usize = 0,
    length: u64 = 0,
    charged: u64 = 0,

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

    pub const AppendError = ErrorOf(append);

    pub fn sink(self: *SessionReportCapture, buffer: []u8) Sink {
        return .{ .capture = self, .interface = .{ .vtable = &.{ .drain = Sink.drain }, .buffer = buffer } };
    }

    pub const Sink = struct {
        capture: *SessionReportCapture,
        failure: ?AppendError = null,
        interface: std.Io.Writer,

        fn drain(interface: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *Sink = @alignCast(@fieldParentPtr("interface", interface));
            try self.put(interface.buffer[0..interface.end]);
            interface.end = 0;
            var written: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                try self.put(bytes);
                written += bytes.len;
            }
            for (0..splat) |_| {
                try self.put(data[data.len - 1]);
                written += data[data.len - 1].len;
            }
            return written;
        }

        fn put(self: *Sink, bytes: []const u8) std.Io.Writer.Error!void {
            self.capture.append(bytes) catch |err| {
                self.failure = err;
                return error.WriteFailed;
            };
        }
    };

    fn flush(self: *SessionReportCapture) !void {
        if (self.buffered == 0) return;
        const amount: u64 = self.buffered;
        const next_charged = std.math.add(u64, self.charged, amount) catch return error.ReportLengthOverflow;
        const next_length = std.math.add(u64, self.length, amount) catch return error.ReportLengthOverflow;
        if (!self.budget.allocate(amount)) return error.ReportScratchExhausted;
        self.charged = next_charged;
        const file = self.writer orelse unreachable;
        try file.writeStreamingAll(self.io, self.buffer[0..self.buffered]);
        self.length = next_length;
        self.buffered = 0;
    }

    pub fn seal(self: *SessionReportCapture) !SessionReport {
        try self.flush();
        const file = self.writer orelse unreachable;
        if (try file.length(self.io) != self.length) return error.ReportSealFailed;
        const report = SessionReport{
            .io = self.io,
            .file = file,
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

const failed_response_turn = rsql.Read(.{
    .sql = "SELECT turn_id FROM model_operation WHERE operation_id=?1 AND session_ref=?2 AND attempt_ordinal>=?3",
    .Args = struct { operation: u64, session: []const u8, attempt: u64 },
    .Row = struct { turn_id: rsql.Positive },
    .cardinality = .optional,
});

pub fn failedResponseBinding(a: *ReadAccess, session: []const u8, operation: u64, attempt_ordinal: u64) !AttemptBinding {
    var found: failed_response_turn.Result = undefined;
    a.read(failed_response_turn, .{ .operation = operation, .session = session, .attempt = attempt_ordinal }, &found);
    try store_access.runAs(a, error.OperationReadFailed);
    const row = found orelse return error.ContentNotFound;
    return .{ .turn_id = row.turn_id.get(), .operation_id = operation, .attempt_ordinal = attempt_ordinal };
}

pub const archive_state = rsql.Read(.{
    .sql = "SELECT " ++ command_domain.archive_state_sql ++ " AS archive_state FROM session_archive session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { archive_state: session_archive.State },
    .cardinality = .optional,
});

fn archiveStateFromIntent(intent: archive_state.Result) session_archive.State {
    return if (intent) |row| row.archive_state else .active;
}

pub fn archiveState(a: *ReadAccess, session: []const u8) !session_archive.State {
    var row: archive_state.Result = undefined;
    a.read(archive_state, .{ .session = session }, &row);
    try store_access.runAs(a, error.SessionReadFailed);
    return archiveStateFromIntent(row);
}

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

pub const FirstCandidates = struct {
    bound: first_bound.Result = null,
    unbound: first_unbound.Result = null,

    pub fn queue(first: *FirstCandidates, a: *ReadAccess, session: []const u8) void {
        a.read(first_bound, .{ .session = session }, &first.bound);
        a.read(first_unbound, .{ .session = session }, &first.unbound);
    }

    pub fn admission(first: *const FirstCandidates) u64 {
        const bound = if (first.bound) |row| row.first_admission_id.get() else std.math.maxInt(u64);
        const unbound = if (first.unbound) |row| row.admission_id.get() else std.math.maxInt(u64);
        const earlier = @min(bound, unbound);
        return if (earlier == std.math.maxInt(u64)) 0 else earlier;
    }
};

pub const person_message_sql = "SELECT admitted_at FROM message_admission @index(message_admission_person) " ++
    "WHERE session_ref=?1 AND sender_session_ref IS NULL AND source_action_id IS NULL ORDER BY admission_position DESC LIMIT 1";

pub const person_message = rsql.Read(.{
    .sql = person_message_sql,
    .Args = struct { session: []const u8 },
    .Row = struct { admitted_at: rsql.Positive },
    .cardinality = .optional,
});

pub const first_message_columns = "m.admission_id AS first_admission,m.admission_position AS first_position,m.admitted_at AS first_admitted_at," ++
    "m.sender_session_ref AS first_sender,first_content.byte_length AS first_length,first_content.digest AS first_digest,first_content.private AS first_private,first_content.form AS first_form";

pub const first_content_join = "JOIN content first_content ON first_content.content_id=m.content_id";

const FirstMessageColumns = struct {
    first_admission: ?rsql.Positive,
    first_position: ?rsql.Positive,
    first_admitted_at: ?rsql.Positive,
    first_sender: ?SessionText,
    first_length: ?u64,
    first_digest: ?[32]u8,
    first_private: ?bool,
    first_form: ?u8,
};

pub const first_message = rsql.Read(.{
    .sql = "SELECT " ++ first_message_columns ++ " FROM message_admission m " ++ first_content_join ++ " WHERE m.admission_id=?2 AND m.session_ref=?1",
    .Args = struct { session: []const u8, first: u64 },
    .Row = FirstMessageColumns,
    .cardinality = .optional,
});

pub fn sortedToolNames(names: ?[]const u8, sorted: [][]const u8) ![]const []const u8 {
    var count: usize = 0;
    if (names) |joined| {
        var each = std.mem.splitScalar(u8, joined, ',');
        while (each.next()) |name| : (count += 1) {
            if (count == sorted.len or !tool_name.valid(name)) return error.CorruptStore;
            sorted[count] = name;
        }
    }
    std.mem.sortUnstable([]const u8, sorted[0..count], {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (sorted[0..count], 0..) |name, index| {
        if (index != 0 and std.mem.eql(u8, sorted[index - 1], name)) return error.CorruptStore;
    }
    return sorted[0..count];
}

pub fn firstMessage(row: anytype, first: u64) error{ CorruptStore, InputPartsNotSupported }!?session_list.FirstMessage {
    if (first == 0) return null;
    if (row.first_private orelse return error.CorruptStore) return error.CorruptStore;
    if (try @import("../../input_parts.zig").Form.decode(row.first_form orelse return error.CorruptStore) == .parts) return error.InputPartsNotSupported;
    return .{
        .position = (row.first_position orelse return error.CorruptStore).get(),
        .admission = (row.first_admission orelse return error.CorruptStore).get(),
        .admitted_at = (row.first_admitted_at orelse return error.CorruptStore).get(),
        .sender = row.first_sender,
        .length = row.first_length orelse return error.CorruptStore,
        .digest = row.first_digest orelse return error.CorruptStore,
    };
}

const first_message_value = rsql.Read(.{
    .sql = "SELECT content_id FROM message_admission WHERE admission_id=?1",
    .Args = struct { admission: u64 },
    .Row = struct { content_id: rsql.Positive },
    .cardinality = .one,
});

pub fn verifyFirstMessage(a: *ReadAccess, row: anytype) !void {
    var found: first_message_value.Result = undefined;
    a.read(first_message_value, .{ .admission = (row.first_admission orelse return error.CorruptStore).get() }, &found);
    try store_access.runAs(a, error.CorruptStore);
    const value = try content_domain.Value.of(found.content_id.get(), row.first_form orelse return error.CorruptStore, row.first_length orelse return error.CorruptStore, row.first_digest orelse return error.CorruptStore);
    if (value.reference != .parts) return error.CorruptStore;
    try @import("content_parts.zig").verify(a, value);
}

const active_proposers_sql = "FROM turn active @index(turn_one_active_per_session) " ++
    "CROSS JOIN model_operation operation @index(model_operation_turn_history) ON operation.turn_id=active.turn_id " ++
    "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND (" ++ store_schema.resolutionIs("operation.resolution_code", .tool_proposals) ++ " " ++
    "OR EXISTS(SELECT 1 FROM model_tool_call proposal WHERE proposal.operation_id=operation.operation_id))";

const active_proposer = rsql.Read(.{
    .sql = "SELECT operation.operation_id " ++ active_proposers_sql,
    .Args = struct { session: []const u8 },
    .Row = struct { operation_id: rsql.Positive },
    .cardinality = .each,
});

const active_tool_calls = reads_domain.ToolOutcome("", "SELECT DISTINCT operation.operation_id," ++
    reads_domain.expectedCallsSql("operation.operation_id") ++ " " ++ active_proposers_sql, struct { session: []const u8 }, false);

const action_count = rsql.Read(.{
    .sql = "SELECT count(*) AS actions FROM action_operation WHERE session_ref=?1 AND acceptance_position IS NULL",
    .Args = struct { session: []const u8 },
    .Row = struct { actions: u64 },
    .cardinality = .each,
});

const rejected_call_count = rsql.Read(.{
    .sql = "SELECT count(*) AS rejected FROM turn active @index(turn_one_active_per_session) " ++
        "CROSS JOIN model_operation operation @index(model_operation_turn_history) ON operation.turn_id=active.turn_id " ++
        "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=operation.operation_id " ++
        "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND tool_call.rejection_code IS NOT NULL",
    .Args = struct { session: []const u8 },
    .Row = struct { rejected: u64 },
    .cardinality = .each,
});

pub const session_count_failures = .{
    .{ active_proposer, error.CallReadFailed },
    .{ active_tool_calls, error.CallReadFailed },
    .{ action_count, error.ActionReadFailed },
    .{ rejected_call_count, error.CallReadFailed },
    .{ command_domain.pending_messages, error.MessageAdmissionReadFailed },
};

const ActiveToolCounts = struct {
    check: reads_domain.ToolOutcomeCheck = .{},
    settled: u64 = 0,
    failed: bool = false,

    pub fn visit(counts: *ActiveToolCounts, row: *const reads_domain.ToolOutcomeRow) bool {
        if (counts.failed or !counts.check.visit(row)) return false;
        if (row.ordinal != null and row.action_id != null and row.action_resolved) {
            counts.settled = std.math.add(u64, counts.settled, 1) catch {
                counts.failed = true;
                return false;
            };
        }
        return true;
    }

    fn finish(counts: *ActiveToolCounts) error{CorruptStore}!u64 {
        if (counts.failed) return error.CorruptStore;
        try counts.check.finish();
        return counts.settled;
    }
};

test "Session Action counts reuse certified active calls across Operations and refuse damaged groups" {
    const certificate = @import("../../activity_read.zig").FieldCertificate;
    var metadata: certificate.Bytes = undefined;
    for (0..3) |index| certificate.write(&metadata, index, .{ .length = 0, .digest = @splat(0) });
    const resolved: reads_domain.ToolOutcomeRow = .{
        .scope_operation = .of(1),
        .expected = 1,
        .ordinal = 0,
        .item_kind = 3,
        .call_acceptance = null,
        .rejection_present = false,
        .action_resolved = true,
        .action_content = true,
        .action_acceptance = .of(10),
        .result_present = true,
        .operation_id = .of(1),
        .turn_id = .of(1),
        .call_ordinal = 0,
        .action_id = .of(1),
        .rejection_code = null,
        .name_content_id = .of(1),
        .call_id_content_id = .of(2),
        .arguments_content_id = .of(3),
        .consistent = true,
        .field_metadata = metadata,
        .length0 = 0,
        .digest0 = @splat(0),
        .private0 = false,
        .length1 = 0,
        .digest1 = @splat(0),
        .private1 = false,
        .length2 = 0,
        .digest2 = @splat(0),
        .private2 = false,
    };
    var unresolved = resolved;
    unresolved.scope_operation = .of(2);
    unresolved.operation_id = .of(2);
    unresolved.action_id = .of(2);
    unresolved.action_resolved = false;
    unresolved.action_content = false;
    unresolved.action_acceptance = null;
    unresolved.result_present = false;
    var later = resolved;
    later.scope_operation = .of(3);
    later.operation_id = .of(3);
    later.action_id = .of(3);
    var counted: ActiveToolCounts = .{};
    try std.testing.expect(counted.visit(&resolved));
    try std.testing.expect(counted.visit(&unresolved));
    try std.testing.expect(counted.visit(&later));
    try std.testing.expectEqual(@as(u64, 2), try counted.finish());
    var empty: ActiveToolCounts = .{};
    try std.testing.expectEqual(@as(u64, 0), try empty.finish());
    var duplicate: ActiveToolCounts = .{};
    try std.testing.expect(duplicate.visit(&resolved));
    try std.testing.expect(!duplicate.visit(&resolved));
    try std.testing.expectError(error.CorruptStore, duplicate.finish());
    var missing = resolved;
    missing.expected = 2;
    var incomplete: ActiveToolCounts = .{};
    try std.testing.expect(incomplete.visit(&missing));
    try std.testing.expect(!incomplete.visit(&unresolved));
    try std.testing.expectError(error.CorruptStore, incomplete.finish());
    inline for (.{ "consistent", "result_present", "action_resolved" }) |field| {
        var damaged = resolved;
        @field(damaged, field) = false;
        var rejected: ActiveToolCounts = .{};
        _ = rejected.visit(&damaged);
        try std.testing.expectError(error.CorruptStore, rejected.finish());
    }
    var overflow: ActiveToolCounts = .{ .settled = std.math.maxInt(u64) };
    try std.testing.expect(!overflow.visit(&resolved));
    try std.testing.expectError(error.CorruptStore, overflow.finish());
}

pub const SessionCounts = struct {
    session: []const u8,
    cutoff: reads_domain.First(command_domain.stop_cutoff.Row) = .{},
    proposer: reads_domain.First(active_proposer.Row) = .{},
    calls: ActiveToolCounts = .{},
    actions: reads_domain.First(action_count.Row) = .{},
    rejected: reads_domain.First(rejected_call_count.Row) = .{},
    pending: reads_domain.First(command_domain.pending_messages.Row) = .{},

    pub const Counted = struct { pending: u64, actions: u64, rejected: u64 };

    pub fn queue(counts: *SessionCounts, a: *ReadAccess) void {
        a.readEach(command_domain.stop_cutoff, .{ .session = counts.session }, 1, &counts.cutoff);
        a.readEach(active_proposer, .{ .session = counts.session }, 1, &counts.proposer);
    }

    pub fn stopCutoff(counts: *const SessionCounts) u64 {
        return if (counts.cutoff.row) |row| row.admission_cutoff else 0;
    }

    pub fn queuePending(counts: *SessionCounts, a: *ReadAccess) void {
        a.readEach(command_domain.pending_messages, .{ .session = counts.session, .cutoff = counts.stopCutoff() }, 1, &counts.pending);
        if (counts.proposer.row != null) a.readEach(active_tool_calls, .{ .session = counts.session }, std.math.maxInt(u64), &counts.calls);
        a.readEach(action_count, .{ .session = counts.session }, 1, &counts.actions);
        a.readEach(rejected_call_count, .{ .session = counts.session }, 1, &counts.rejected);
    }

    pub fn judge(counts: *SessionCounts) !Counted {
        const pending = counts.pending.row orelse return error.MessageAdmissionReadFailed;
        const settled = try counts.calls.finish();
        const actions = counts.actions.row orelse return error.ActionReadFailed;
        const rejected = counts.rejected.row orelse return error.CallReadFailed;
        return .{ .pending = pending.pending, .actions = std.math.add(u64, actions.actions, settled) catch return error.CorruptStore, .rejected = rejected.rejected };
    }
};

comptime {
    if (Quota.max_bytes > store_schema.content_chunk_bytes) @compileError("a quota diagnostic is more than one content chunk");
}

const work_latest = WorkLatest(struct { session: []const u8 }, "?1");

fn WorkLatest(comptime Args: type, comptime session: []const u8) type {
    return rsql.Read(.{
        .sql = "SELECT t.turn_id,t.operation_id,t.input_cutoff,t.outcome_code,t.outcome_content_id,t.outcome_at,t.outcome_position," ++
            "coalesce(o.resolution_code,o.last_failure_code) AS operation_code,o.retry_due_at_ms,o.attempt_ordinal,o.attempt_at,o.retry_scheduled_at,o.resolved_at," ++
            "(o.resolution_code IS NULL AND " ++ command_domain.currentModelOperationSql("o", "t") ++ ") AS interruptible," ++
            "(SELECT @payload(content) FROM content WHERE content_id=o.resolution_content_id AND byte_length<=" ++ std.fmt.comptimePrint("{d}", .{Quota.max_bytes}) ++
            " AND t.outcome_code NOT IN ('completed','cancelled')) AS diagnostic," ++
            "(SELECT stopped_at FROM session_stop @index(session_stop_turn) WHERE selected_turn_id=t.turn_id ORDER BY position LIMIT 1) AS stopped_at " ++
            "FROM turn t @index(turn_session_latest) JOIN model_operation o ON o.operation_id=t.operation_id " ++
            "WHERE t.session_ref=" ++ session ++ " ORDER BY t.turn_id DESC LIMIT 1",
        .Args = Args,
        .Row = WorkLatestRow,
        .cardinality = .each,
    });
}

const WorkLatestRow = struct {
    turn_id: rsql.Positive,
    operation_id: rsql.Positive,
    input_cutoff: rsql.Positive,
    outcome_code: ?Code,
    outcome_content_id: ?rsql.Positive,
    outcome_at: ?rsql.Positive,
    outcome_position: ?rsql.Positive,
    operation_code: ?Code,
    retry_due_at_ms: ?u64,
    attempt_ordinal: ?rsql.Positive,
    attempt_at: ?rsql.Positive,
    retry_scheduled_at: ?rsql.Positive,
    resolved_at: ?rsql.Positive,
    interruptible: bool,
    diagnostic: ?rsql.Blob(Quota.max_bytes),
    stopped_at: ?rsql.Positive,
};

fn firstApprovalSql(comptime session: []const u8) []const u8 {
    return "SELECT approval.action_id FROM action_operation approval " ++
        "JOIN model_operation source_operation ON source_operation.operation_id=approval.parent_operation_id " ++
        "JOIN turn source_turn ON source_turn.turn_id=source_operation.turn_id " ++
        "WHERE approval.session_ref=" ++ session ++ " AND " ++
        action_domain.permissionDecisionEligibleSql("approval", "source_turn", false) ++ " AND " ++
        action_domain.eligibleSql("approval", "source_operation", "source_turn") ++ " ORDER BY approval.action_id LIMIT 1";
}

test "optional approval index does not change MySQL prepared slots or tokens" {
    const query = comptime firstApprovalSql("?1");
    const after = comptime std.mem.indexOf(u8, query, "action_operation approval ").? + "action_operation approval ".len;
    const Plain = rsql.Read(.{
        .sql = query,
        .Args = struct { session: []const u8 },
        .Row = struct { action_id: rsql.Positive },
        .cardinality = .each,
    });
    const Hinted = rsql.Read(.{
        .sql = query[0..after] ++ "@index(action_operation_awaiting) " ++ query[after..],
        .Args = Plain.Args,
        .Row = Plain.Row,
        .cardinality = .each,
    });
    try std.testing.expect(comptime !store_schema.mysqlCanForceIndex("action_operation_awaiting"));
    try std.testing.expectEqual(Plain.mysql.slots.len, Hinted.mysql.slots.len);
    for (Plain.mysql.slots, Hinted.mysql.slots) |plain, hinted| try std.testing.expectEqualDeep(plain, hinted);
    try std.testing.expectEqual(Plain.mysql.parts.len, Hinted.mysql.parts.len);
    for (Plain.mysql.parts, Hinted.mysql.parts) |plain, hinted| {
        var a = std.mem.tokenizeAny(u8, plain, " \t\r\n");
        var b = std.mem.tokenizeAny(u8, hinted, " \t\r\n");
        while (a.next()) |token| try std.testing.expectEqualStrings(token, b.next() orelse return error.TestUnexpectedResult);
        try std.testing.expect(b.next() == null);
    }
}

const work_approval = rsql.Read(.{
    .sql = "SELECT (" ++ firstApprovalSql("?1") ++ ") AS first_action",
    .Args = struct { session: []const u8 },
    .Row = struct { first_action: ?rsql.Positive },
    .cardinality = .each,
});

const work_actions = WorkActions(struct { operation: u64, session: []const u8 }, "?1", "?2");

fn WorkActions(comptime Args: type, comptime operation: []const u8, comptime session: []const u8) type {
    return rsql.Read(.{
        .sql = "WITH action_results AS (SELECT acceptance_position,resolved_at FROM action_operation @index(action_operation_session_results) " ++
            "WHERE session_ref=" ++ session ++ " AND parent_operation_id=" ++ operation ++ " AND acceptance_position IS NOT NULL AND background_position IS NULL " ++
            "UNION ALL SELECT acceptance_position,resolved_at FROM action_operation @index(action_operation_background_results) " ++
            "WHERE session_ref=" ++ session ++ " AND parent_operation_id=" ++ operation ++ " AND background_position IS NOT NULL AND acceptance_position IS NOT NULL) " ++
            "SELECT count(*) AS total,@count_where(a.resolution_code IS NULL) AS unresolved," ++
            "@count_where(a.resolution_code IS NULL AND a.authorized=0) AS awaiting," ++
            "min(CASE WHEN a.resolution_code IS NULL AND a.authorized=0 THEN a.action_id END) AS first_awaiting," ++
            "(" ++ firstApprovalSql(session) ++ ") AS first_action," ++
            "@count_where(a.resolution_code IS NULL AND a.attempt_ordinal=1) AS running," ++
            "(SELECT resolved_at FROM action_results ORDER BY acceptance_position DESC LIMIT 1) AS latest_resolution_at," ++
            "@max_where(a.decided_at,a.resolution_code IS NULL AND r.permission_mode=0) AS latest_decision_at " ++
            "FROM action_operation a LEFT JOIN session_revision r ON r.session_ref=a.session_ref AND r.revision=a.permission_revision " ++
            "WHERE a.parent_operation_id=" ++ operation,
        .Args = Args,
        .Row = WorkActionsRow,
        .cardinality = .each,
        .compound = true,
    });
}

const WorkActionsRow = struct {
    total: u64,
    unresolved: u64,
    awaiting: u64,
    first_awaiting: ?rsql.Positive,
    first_action: ?rsql.Positive,
    running: u64,
    latest_resolution_at: ?rsql.Positive,
    latest_decision_at: ?rsql.Positive,
};

const work_oldest = WorkOldest(struct { operation: u64 }, "?1");

fn WorkOldest(comptime Args: type, comptime operation: []const u8) type {
    return rsql.Read(.{
        .sql = "SELECT a.attempt_at,tool_call.description,a.call_ordinal FROM action_operation a " ++
            "JOIN model_tool_call tool_call ON tool_call.operation_id=a.parent_operation_id AND tool_call.call_ordinal=a.call_ordinal " ++
            "WHERE a.parent_operation_id=" ++ operation ++ " AND a.resolution_code IS NULL AND a.attempt_ordinal=1 ORDER BY a.attempt_at,a.action_id LIMIT 1",
        .Args = Args,
        .Row = WorkOldestRow,
        .cardinality = .each,
    });
}

const WorkOldestRow = struct { attempt_at: rsql.Positive, description: ?Bounded(tool_presentation.max_description_bytes), call_ordinal: u64 };

const pending_session_sql = "(SELECT pending.session_ref FROM message_admission pending LEFT JOIN turn own ON own.turn_id=pending.turn_id " ++
    "WHERE pending.command_key=?1 AND own.outcome_code IS NULL)";

const pending_operation_sql = "(SELECT CASE WHEN latest.outcome_code IS NULL THEN latest.operation_id END FROM turn latest @index(turn_session_latest) " ++
    "WHERE latest.session_ref=" ++ pending_session_sql ++ " ORDER BY latest.turn_id DESC LIMIT 1)";

const PendingArgs = struct { key: []const u8 };
const pending_latest = WorkLatest(PendingArgs, pending_session_sql);
const pending_actions = WorkActions(PendingArgs, pending_operation_sql, pending_session_sql);
const pending_oldest = WorkOldest(PendingArgs, pending_operation_sql);

const work_queued = rsql.Read(.{
    .sql = "SELECT admitted_at,admission_position FROM message_admission @index(message_admission_session_pending) " ++
        "WHERE session_ref=?1 AND turn_id IS NULL AND admission_id>?2 ORDER BY admission_id LIMIT 1",
    .Args = struct { session: []const u8, cutoff: u64 },
    .Row = struct { admitted_at: rsql.Positive, admission_position: rsql.Positive },
    .cardinality = .each,
});

const work_excluded = rsql.Read(.{
    .sql = "SELECT admission_id FROM message_admission @index(message_admission_session_pending) " ++
        "WHERE session_ref=?1 AND turn_id IS NULL AND admission_id<=?2 ORDER BY admission_id DESC LIMIT 1",
    .Args = struct { session: []const u8, cutoff: u64 },
    .Row = struct { admission_id: rsql.Positive },
    .cardinality = .each,
});

const work_stop = rsql.Read(.{
    .sql = "SELECT position,stopped_at FROM session_stop @index(session_stop_exclusion) " ++
        "WHERE session_ref=?1 AND admission_cutoff>=?2 ORDER BY admission_cutoff,position LIMIT 1",
    .Args = struct { session: []const u8, admission: u64 },
    .Row = struct { position: rsql.Positive, stopped_at: rsql.Positive },
    .cardinality = .each,
});

pub const report_failures = .{
    .{ first_bound, error.SessionReadFailed },
    .{ first_unbound, error.SessionReadFailed },
    .{ person_message, error.SessionReadFailed },
    .{ first_message, error.CorruptStore },
} ++ work_failures;

pub const work_failures = .{
    .{ work_latest, error.TurnReadFailed },
    .{ work_actions, error.ActionReadFailed },
    .{ work_approval, error.ActionReadFailed },
    .{ command_domain.stop_cutoff, error.SessionStopReadFailed },
    .{ work_queued, error.MessageAdmissionReadFailed },
    .{ work_excluded, error.MessageAdmissionReadFailed },
};

pub const pending_failures = .{
    .{ pending_latest, error.TurnReadFailed },
    .{ pending_actions, error.ActionReadFailed },
};

fn runReport(a: *ReadAccess) !void {
    return store_access.runNamed(a, report_failures, error.CorruptStore);
}

pub const WorkRead = struct {
    session: []const u8,
    stage: Stage = .latest,
    count: reads_domain.RowCount = .{},
    ahead: ?[2]reads_domain.RowCount = null,
    approval: reads_domain.First(work_approval.Row) = .{},
    inputs: session_work.Inputs = .{ .now_ms = 0, .created_at = 0 },
    code: Code = .{},
    outcome_content_id: ?u64 = null,
    cause: Code = .{},
    description: ?Bounded(tool_presentation.max_description_bytes) = null,
    cutoff: u64 = 0,

    const Stage = enum { latest, actions, oldest, cutoff, queued, excluded, stop, owed, done };

    pub fn queue(w: *WorkRead, a: *ReadAccess) bool {
        if (w.stage == .latest and w.ahead != null) return false;
        switch (w.stage) {
            .latest => reads_domain.readFirst(a, work_latest, .{ .session = w.session }, w),
            .actions => reads_domain.readFirst(a, work_actions, .{ .operation = w.inputs.latest.?.operation_id, .session = w.session }, w),
            .oldest => reads_domain.readFirst(a, work_oldest, .{ .operation = w.inputs.latest.?.operation_id }, w),
            .cutoff => {
                if (w.ahead == null and w.inputs.latest != null) a.readEach(work_approval, .{ .session = w.session }, 1, &w.approval);
                reads_domain.readFirst(a, command_domain.stop_cutoff, .{ .session = w.session }, w);
            },
            .queued => reads_domain.readFirst(a, work_queued, .{ .session = w.session, .cutoff = w.cutoff }, w),
            .excluded => reads_domain.readFirst(a, work_excluded, .{ .session = w.session, .cutoff = w.cutoff }, w),
            .stop => reads_domain.readFirst(a, work_stop, .{ .session = w.session, .admission = w.inputs.excluded.?.admission }, w),
            .owed => reads_domain.readFirst(a, obligation.read, .{ .session = w.session }, w),
            .done => return false,
        }
        return true;
    }

    pub fn queuePending(w: *WorkRead, a: *ReadAccess, key: []const u8) void {
        std.debug.assert(w.stage == .latest);
        w.count = .{};
        w.ahead = @splat(.{});
        a.readEach(pending_latest, .{ .key = key }, 1, w);
        a.readEach(pending_actions, .{ .key = key }, 1, w);
        a.readEach(pending_oldest, .{ .key = key }, 1, w);
    }

    pub fn visit(w: *WorkRead, row: anytype) bool {
        return reads_domain.countRow(w.rowCount(@TypeOf(row.*)), w, row);
    }

    fn rowCount(w: *WorkRead, comptime Row: type) *reads_domain.RowCount {
        if (w.ahead) |*ahead| {
            if (Row == WorkActionsRow) return &ahead[0];
            if (Row == WorkOldestRow) return &ahead[1];
        }
        return &w.count;
    }

    pub fn advance(w: *WorkRead) !void {
        if (w.stage == .cutoff and w.ahead == null and w.inputs.latest != null) {
            const row = w.approval.row orelse return error.ActionReadFailed;
            w.inputs.first_action = optional(row.first_action);
        }
        if (w.stage == .latest) if (w.ahead) |ahead| {
            try w.step(w.count);
            if (w.stage == .actions) try w.step(ahead[0]);
            if (w.stage == .oldest) try w.step(ahead[1]);
            return;
        };
        try w.step(w.count);
    }

    fn step(w: *WorkRead, count: reads_domain.RowCount) !void {
        const found = try count.found();
        w.stage = switch (w.stage) {
            .latest => if (found and w.inputs.latest.?.terminal == null) .actions else .cutoff,
            .actions => if (!found) return error.ActionReadFailed else if (w.inputs.latest.?.actions.running != 0) .oldest else if (w.inputs.latest.?.stopped_at != null) .cutoff else .done,
            .oldest => if (!found) return error.CorruptStore else if (w.inputs.latest.?.stopped_at != null) .cutoff else .done,
            .stop => if (!found) return error.CorruptStore else .owed,
            .cutoff => .queued,
            .queued => if (found) .done else if (w.cutoff == 0) .owed else .excluded,
            .excluded => if (found) .stop else .owed,
            .owed => if (!found) return error.CorruptStore else .done,
            .done => .done,
        };
    }

    pub fn keep(w: *WorkRead, row: anytype) error{CorruptStore}!void {
        const Row = @TypeOf(row.*);
        if (Row == WorkLatestRow) return w.keepLatest(row);
        if (Row == WorkActionsRow) {
            w.inputs.first_action = optional(row.first_action);
            const turn = if (w.inputs.latest) |*latest| latest else return;
            if (turn.terminal != null) return;
            turn.actions = .{
                .total = row.total,
                .unresolved = row.unresolved,
                .awaiting = row.awaiting,
                .first_awaiting = optional(row.first_awaiting),
                .running = row.running,
                .latest_resolution_at = optional(row.latest_resolution_at),
                .latest_decision_at = optional(row.latest_decision_at),
            };
        } else if (Row == WorkOldestRow) {
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
        } else if (Row == obligation.read.Row) {
            w.inputs.owed_since = optional(row.owed_since);
        } else @compileError("WorkRead reads no " ++ @typeName(Row));
    }

    fn keepLatest(w: *WorkRead, row: *const WorkLatestRow) error{CorruptStore}!void {
        var turn: session_work.Inputs.Turn = .{
            .turn_id = row.turn_id.get(),
            .operation_id = row.operation_id.get(),
            .input_cutoff = row.input_cutoff.get(),
            .stopped_at = optional(row.stopped_at),
            .interruptible = row.interruptible,
            .op = undefined,
        };
        if (row.resolved_at) |at| {
            const resolution = row.operation_code orelse return error.CorruptStore;
            turn.op = .{ .resolved = .{ .resolution = turn_policy.Resolution.parse(resolution.slice()), .at = at.get() } };
        } else if ((row.retry_due_at_ms orelse 0) == 0) {
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

    pub fn outcome(w: *const WorkRead) ?struct { code: []const u8, content_id: ?u64 } {
        const turn = w.inputs.latest orelse return null;
        if (turn.terminal == null) return null;
        return .{ .code = w.code.slice(), .content_id = w.outcome_content_id };
    }

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

const optional = rsql.Positive.optional;

pub fn readWorks(a: *ReadAccess, works: []WorkRead) !void {
    while (true) {
        var queued = false;
        for (works) |*w| queued = w.queue(a) or queued;
        if (!queued) return;
        try runReport(a);
        for (works) |*w| try w.advance();
    }
}

pub const full_compound_value = rsql.Read(.{
    .compound = true,
    .sql = "SELECT c.content_id,c.byte_length,c.digest,c.private,c.form FROM message_admission m JOIN content c ON c.content_id=m.content_id WHERE m.session_ref=?1 AND c.form=1 " ++
        "UNION ALL SELECT c.content_id,c.byte_length,c.digest,c.private,c.form FROM conversation_entry e JOIN content c ON c.content_id=e.content_id WHERE e.session_ref=?1 AND c.form=1 " ++
        "UNION ALL SELECT c.content_id,c.byte_length,c.digest,c.private,c.form FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.session_ref=?1 AND c.form=1 " ++
        "UNION ALL SELECT c.content_id,c.byte_length,c.digest,c.private,c.form FROM action_operation a JOIN content c ON c.content_id=a.background_content_id WHERE a.session_ref=?1 AND c.form=1 LIMIT 1",
    .Args = struct { session: []const u8 },
    .Row = struct { content_id: rsql.Positive, byte_length: u64, digest: [32]u8, private: bool, form: u8 },
    .cardinality = .optional,
});

pub fn verifyFullCompound(a: *ReadAccess, row: full_compound_value.Row) !void {
    const metadata: content_domain.content_metadata.Row = .{ .byte_length = row.byte_length, .digest = row.digest, .private = row.private, .form = row.form };
    _ = try @import("content_parts.zig").publicMetadata(a, row.content_id.get(), &metadata);
    return error.CorruptStore;
}

pub fn readFull(a: *ReadAccess, session_ref: []const u8, watched: anytype) !void {
    try watched.call("fullOpen", .{session_report.FullList.session_revisions});
    try readRevisions(a, session_ref, watched);
    inline for (full_runs) |run| try readRun(a, run, session_ref, watched);
    try watched.call("fullEnd", .{});
}

pub const FullText = struct {
    a: *ReadAccess,
    failed: bool = false,

    pub fn stream(text: *FullText, value: session_report.Text, sink: anytype) !void {
        var forward: Forward(@TypeOf(sink)) = .{ .sink = sink };
        content_domain.streamVerified(text.a, value.id, .{ .length = value.length, .digest = value.digest }, &forward) catch |err| {
            if (!forward.failed) text.failed = true;
            return err;
        };
    }

    fn Forward(comptime Sink: type) type {
        return struct {
            sink: Sink,
            failed: bool = false,

            pub fn write(forward: *@This(), bytes: []const u8) !void {
                forward.sink.write(bytes) catch |err| {
                    forward.failed = true;
                    return err;
                };
            }
        };
    }
};

fn visitRow(a: *ReadAccess, watched: anytype, values: *const session_report.FullRow) RowError(@TypeOf(watched))!void {
    var text: FullText = .{ .a = a };
    watched.visitor.fullRow(values, &text) catch |err| {
        if (!text.failed) watched.failed = true;
        return err;
    };
}

fn RowError(comptime Watcher: type) type {
    const Visitor = @FieldType(@typeInfo(Watcher).pointer.child, "visitor");
    return @typeInfo(@TypeOf(@as(Visitor, undefined).fullRow(@as(*const session_report.FullRow, undefined), @as(*FullText, undefined)))).error_union.error_set;
}

fn OpenError(comptime Watcher: type) type {
    return @typeInfo(@typeInfo(Watcher).pointer.child.Result("fullOpen")).error_union.error_set;
}

pub const full_runs = .{ .{Messages}, .{ Conversation, Turns, Operations }, .{Calls}, .{Actions}, .{ Decisions, Stops, Interruptions, Results } };

pub const full_pages = blk: {
    var statements: []const type = &.{full_revisions};
    for (full_runs) |run| for (run) |L| {
        statements = statements ++ .{L.S};
    };
    break :blk statements;
};

const chunk_rows = 256;

fn takes(comptime kept_rows: u8) u16 {
    return if (kept_rows == 0) chunk_rows else kept_rows;
}

const ListStatus = struct {
    previous: ?*const ListStatus,
    done: bool = false,
    queued: bool = false,
    more: bool = false,
    kept: bool = false,
    failed: bool = false,
    empty: bool = false,

    fn finished(list: *const ListStatus) bool {
        if (list.done) return true;
        return (list.queued or list.empty) and list.previousFinished() and !list.more and !list.kept and !list.failed;
    }

    fn previousFinished(list: *const ListStatus) bool {
        return if (list.previous) |previous| previous.finished() else true;
    }
};

fn Headers(comptime Watcher: type) type {
    return struct {
        watched: Watcher,
        lists: []const session_report.FullList,
        opened: usize = 0,

        fn open(headers: *@This(), list: usize) OpenError(Watcher)!void {
            while (headers.opened <= list) : (headers.opened += 1) try headers.watched.call("fullOpen", .{headers.lists[headers.opened]});
        }
    };
}

fn checkList(comptime L: type) void {
    if (comptime listError(L)) |message| @compileError(message);
}

pub fn listError(comptime L: type) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(20_000);
        const required = [_][]const u8{ "S", "failed", "list", "kept_rows", "values" };
        const groups = [_][]const []const u8{ &.{ "State", "check" }, &.{ "First", "FirstRead", "queueFirst", "checkFirst" } };
        for (@typeInfo(L).@"struct".decl_names) |name| {
            var known = false;
            for (required) |each| known = known or std.mem.eql(u8, each, name);
            for (groups) |group| for (group) |each| {
                known = known or std.mem.eql(u8, each, name);
            };
            if (!known) return "a Full list declares only its statement, failed, list, kept_rows, values and its hooks, not " ++ name ++ ": " ++ @typeName(L);
        }
        for (required) |name| if (!declares(L, name)) return "a Full list declares pub " ++ name ++ ": " ++ @typeName(L);
        for (groups) |group| {
            const present = declares(L, group[0]);
            for (group) |name| {
                if (declares(L, name) != present) return "a Full list declares all of a group of hooks or none: " ++ name ++ " in " ++ @typeName(L);
            }
        }
        return null;
    }
}

fn declares(comptime L: type, comptime name: []const u8) bool {
    for (@typeInfo(L).@"struct".decl_names) |each| if (std.mem.eql(u8, each, name)) return true;
    return false;
}

const ErrorOf = @import("../../error_set.zig").Of;

fn ListState(comptime L: type) type {
    return if (@hasDecl(L, "State")) L.State else struct {};
}

fn ListFirst(comptime L: type) type {
    return if (@hasDecl(L, "First")) L.First else void;
}

fn CheckError(comptime L: type) type {
    return if (@hasDecl(L, "check")) ErrorOf(L.check) else error{};
}

fn CheckFirstError(comptime L: type) type {
    return if (@hasDecl(L, "checkFirst")) ErrorOf(L.checkFirst) else error{};
}

fn Chunk(comptime L: type, comptime Watcher: type) type {
    comptime {
        checkList(L);
        if (!@hasDecl(L.S, "page_walk")) @compileError("a Full list's statement is an rsql.Page: " ++ @typeName(L));
        if (L.S.take != takes(L.kept_rows)) @compileError("a Full list's Page takes takes(kept_rows) rows: " ++ @typeName(L));
    }
    return struct {
        const Row = L.S.Row;
        const Failure = error{CorruptStore} || ErrorOf(L.values) || CheckError(L) || RowError(Watcher) || OpenError(Watcher);

        a: *ReadAccess,
        watched: Watcher,
        headers: *Headers(Watcher),
        list: usize,
        first: *bool,
        state: *ListState(L),
        status: *ListStatus,
        after: L.S.Args,
        rows: u16 = 0,
        ready: ?bool = null,
        decoded: Row = undefined,
        kept: [L.kept_rows]Row = undefined,
        count: u8 = 0,
        failure: ?Failure = null,

        pub fn visit(chunk: *@This(), row: *const Row) bool {
            const ready = chunk.ready orelse chunk.status.previousFinished();
            chunk.ready = ready;
            if (!ready) return false;
            const next = L.S.next(chunk.after, row) orelse {
                chunk.failure = error.CorruptStore;
                chunk.status.failed = true;
                return false;
            };
            if (chunk.rows == L.S.take) {
                chunk.status.more = true;
                return false;
            }
            chunk.rows += 1;
            chunk.after = next;
            chunk.take(row) catch |err| {
                chunk.failure = err;
                chunk.status.failed = true;
                return false;
            };
            return true;
        }

        fn take(chunk: *@This(), row: *const Row) Failure!void {
            if (@hasDecl(L, "check")) try L.check(chunk.state, row);
            if (L.kept_rows == 0) return chunk.emit(row);
            chunk.kept[chunk.count] = row.*;
            chunk.count += 1;
            chunk.status.kept = true;
        }

        fn emit(chunk: *@This(), row: *const Row) Failure!void {
            try chunk.headers.open(chunk.list);
            chunk.first.* = false;
            const values = try L.values(chunk.a, row, chunk.state);
            try visitRow(chunk.a, chunk.watched, &values);
        }
    };
}

fn ListRun(comptime L: type, comptime Watcher: type) type {
    return struct {
        state: ListState(L) = .{},
        first: bool = true,
        after: L.S.Args,
        status: ListStatus,
        chunk: Chunk(L, Watcher) = undefined,
        first_read: ListFirst(L) = undefined,
        first_queued: bool = false,
        begun: bool = false,
    };
}

fn RunState(comptime Ls: anytype, comptime Watcher: type) type {
    var types: [Ls.len]type = undefined;
    for (Ls, 0..) |L, i| types[i] = ListRun(L, Watcher);
    const list = types;
    return @Tuple(&list);
}

fn RunError(comptime Ls: anytype, comptime Watcher: type) type {
    var set = ErrorOf(ReadAccess.run);
    for (Ls) |L| set = set || @TypeOf(L.failed) || Chunk(L, Watcher).Failure || CheckFirstError(L);
    return set;
}

pub noinline fn readRun(a: *ReadAccess, comptime Ls: anytype, session_ref: []const u8, watched: anytype) !void {
    comptime for (0..Ls.len - 1) |i| std.debug.assert(Ls[i].kept_rows == 0);
    const Watcher = @TypeOf(watched);
    const tags = comptime blk: {
        var list: [Ls.len]session_report.FullList = undefined;
        for (Ls, 0..) |L, i| list[i] = L.list;
        const result = list;
        break :blk result;
    };
    var headers: Headers(Watcher) = .{ .watched = watched, .lists = &tags };
    const lists = a.store.reportScratch(RunState(Ls, Watcher));
    inline for (0..Ls.len) |i| lists[i] = .{
        .after = .{ .session = session_ref },
        .status = .{ .previous = if (i == 0) null else &lists[i - 1].status },
    };
    var current: usize = 0;
    while (current < Ls.len) {
        var ahead = false;
        inline for (0..Ls.len) |i| if (i == current) {
            ahead = lists[i].first;
        };
        inline for (Ls, 0..) |L, i| if (i >= current) {
            const list = &lists[i];
            list.status.queued = false;
            if (!list.status.empty and (i == current or ahead)) {
                list.status.queued = true;
                list.status.more = false;
                list.status.kept = false;
                list.status.failed = false;
                if (@hasDecl(L, "First") and !list.begun and !list.first_queued) {
                    L.queueFirst(a, session_ref, &list.first_read);
                    list.first_queued = true;
                }
                list.chunk = .{ .a = a, .watched = watched, .headers = &headers, .list = i, .first = &list.first, .state = &list.state, .status = &list.status, .after = list.after };
                a.readEach(L.S, list.after, L.S.limit, &list.chunk);
            }
        };
        a.run() catch |err| return runFailure(a, Ls, Watcher, lists, current, err);
        var blocked = false;
        inline for (Ls, 0..) |L, i| if (i >= current) {
            const list = &lists[i];
            if (!list.status.queued and !list.status.empty) {
                blocked = true;
            } else if (blocked or !list.status.previousFinished()) {
                blocked = true;
                if (list.status.queued and list.chunk.ready == null) list.status.empty = true;
            } else {
                if (@hasDecl(L, "checkFirst") and !list.begun) try L.checkFirst(&list.first_read);
                list.begun = true;
                if (list.status.queued) {
                    if (list.chunk.failure) |err| return err;
                    try headers.open(i);
                    for (list.chunk.kept[0..list.chunk.count]) |*row| try list.chunk.emit(row);
                    list.after = list.chunk.after;
                } else try headers.open(i);
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

fn runFailure(a: *const ReadAccess, comptime Ls: anytype, comptime Watcher: type, lists: *RunState(Ls, Watcher), current: usize, err: RunError(Ls, Watcher)) RunError(Ls, Watcher) {
    if (err != error.StatementFailed) return err;
    var failed: ?usize = null;
    inline for (Ls, 0..) |L, i| if (failed == null and i >= current and lists[i].status.queued) {
        if (a.failedOn(L.S) or failedOnFirst(a, L)) failed = i;
    };
    const index = failed orelse return err;
    inline for (Ls, 0..) |L, i| if (i >= current and i <= index) {
        const list = &lists[i];
        if (i == index) return list.chunk.failure orelse L.failed;
        if (@hasDecl(L, "checkFirst") and !list.begun) L.checkFirst(&list.first_read) catch |check| return check;
        if (list.chunk.failure) |row| return row;
    };
    unreachable;
}

fn failedOnFirst(a: *const ReadAccess, comptime L: type) bool {
    return if (@hasDecl(L, "FirstRead")) a.failedOn(L.FirstRead) else false;
}

fn optionalText(id: ?rsql.Positive, length: ?u64, digest: ?[32]u8) error{CorruptStore}!?session_report.Text {
    const content_id = id orelse return null;
    return .{ .id = content_id.get(), .length = length orelse return error.CorruptStore, .digest = digest orelse return error.CorruptStore };
}

fn optionalReference(id: ?rsql.Positive, length: ?u64, digest: ?[32]u8) error{CorruptStore}!?session_report.Content {
    const value = try optionalText(id, length, digest) orelse return null;
    return .{ .length = value.length, .digest = value.digest };
}

fn readEarlier(a: *ReadAccess, earlier: []const session_report.Text) !void {
    for (earlier) |value| try content_domain.streamVerified(a, value.id, .{ .length = value.length, .digest = value.digest }, Discard{});
}

const Discard = struct {
    pub fn write(_: Discard, _: []const u8) error{}!void {}
};

pub const ContentOwner = struct {
    revision: u64,
    field: session_report.RevisionField,

    fn slot(owner: ContentOwner) u64 {
        return owner.revision * 2 + @as(u64, @intCast(@backingInt(owner.field)));
    }

    fn ofSlot(value: u64) ContentOwner {
        return .{ .revision = value / 2, .field = if (value % 2 == 0) .instructions else .output_schema };
    }
};

const RevisionRow = struct {
    revision: rsql.Positive,
    newest: rsql.Positive,
    command_key: Bounded(128),
    workspace: Bounded(workspace_path.max_bytes),
    provider: provider_name.Provider,
    model: Bounded(model_capability.max_model_bytes),
    compaction_trigger: ?rsql.Positive,
    output_reservation: ?u64,
    reasoning_effort: ?model_capability.ReasoningEffort,
    label: ?Bounded(tool_presentation.max_label_bytes),
    tools: ?Bounded(tool_set.max_names_bytes),
    loaded_tools: ?Bounded(tool_set.max_names_bytes),
    permission_mode: u8,
    instructions_id: rsql.Positive,
    instructions_length: u64,
    instructions_digest: [32]u8,
    output_schema_id: ?rsql.Positive,
    output_schema_length: ?u64,
    output_schema_digest: ?[32]u8,
    instructions_owner: u64,
    output_schema_owner: ?u64,
};

pub const full_revisions = rsql.Page(.{
    .arms = &.{.{
        .on = .{ .primary_key = "session_revision" },
        .alias = "r",
        .columns = "(SELECT max(revision) FROM session_revision WHERE session_ref=?1) AS newest,r.command_key,r.workspace,r.provider,r.model," ++
            "r.compaction_trigger,r.output_reservation,r.reasoning_effort,r.label," ++ tool_set.namesSql("r.tool_set_id") ++ " AS tools," ++ tool_set.namesSql(tool_set.offeredSetSql("r")) ++ " AS loaded_tools,r.permission_mode," ++
            "r.instructions_content_id AS instructions_id,instructions.byte_length AS instructions_length,instructions.digest AS instructions_digest," ++
            "r.output_schema_content_id AS output_schema_id,output_schema.byte_length AS output_schema_length,output_schema.digest AS output_schema_digest," ++
            owner_column("instructions") ++ " AS instructions_owner," ++ owner_column("output_schema") ++ " AS output_schema_owner",
        .joins = "LEFT JOIN content instructions ON instructions.content_id=r.instructions_content_id " ++
            "LEFT JOIN content output_schema ON output_schema.content_id=r.output_schema_content_id",
    }},
    .Row = RevisionRow,
    .take = 2,
});

fn owner_column(comptime field: []const u8) []const u8 {
    const as_instructions = "(SELECT min(revision)*2 FROM session_revision @index(session_revision_instructions) WHERE session_ref=?1 AND instructions_content_id=r." ++ field ++ "_content_id)";
    const as_output_schema = "(SELECT min(revision)*2+1 FROM session_revision @index(session_revision_output_schema) WHERE session_ref=?1 AND output_schema_content_id=r." ++ field ++ "_content_id)";
    const own = if (std.mem.eql(u8, field, "instructions")) as_instructions else as_output_schema;
    const other = if (std.mem.eql(u8, field, "instructions")) as_output_schema else as_instructions;
    return "min(" ++ own ++ ",coalesce(" ++ other ++ "," ++ own ++ "))";
}

const RevisionContent = struct {
    value: session_report.Text,
    owner: ContentOwner,
    owned: bool,

    fn of(value: session_report.Text, owner: ContentOwner, here: ContentOwner) RevisionContent {
        return .{ .value = value, .owner = owner, .owned = owner.slot() == here.slot() };
    }

    fn values(content: *const RevisionContent) session_report.RevisionContent {
        return .{ .text = content.value, .owner = if (content.owned) null else .{ .revision = content.owner.revision, .field = content.owner.field } };
    }
};

const RevisionTail = struct {
    instructions: RevisionContent,
    output_schema: ?RevisionContent,

    fn visit(tail: *const RevisionTail, a: *ReadAccess, watched: anytype) !void {
        try visitRow(a, watched, &.{ .revision_contents = .{
            .instructions = tail.instructions.values(),
            .output_schema = if (tail.output_schema) |*content| content.values() else null,
        } });
    }

    fn streams(tail: *const RevisionTail) bool {
        const instructions = tail.instructions.owned and tail.instructions.value.length != 0;
        const output_schema = if (tail.output_schema) |content| content.owned and content.value.length != 0 else false;
        return instructions or output_schema;
    }
};

fn RevisionChunk(comptime Watcher: type) type {
    return struct {
        a: *ReadAccess,
        watched: Watcher,
        after: full_revisions.Args,
        rows: u16 = 0,
        more: bool = false,
        tail: ?RevisionTail = null,
        failure: ?Failure = null,
        decoded: RevisionRow = undefined,
        tools: [tool_defs.max_tools][]const u8 = undefined,
        loaded_tools: [tool_defs.max_tools][]const u8 = undefined,

        const Failure = error{CorruptStore} || RowError(Watcher);

        pub fn visit(chunk: *@This(), row: *const RevisionRow) bool {
            const next = full_revisions.next(chunk.after, row) orelse {
                chunk.failure = error.CorruptStore;
                return false;
            };
            if (chunk.rows == full_revisions.take) {
                chunk.more = true;
                return false;
            }
            const tail = chunk.take(row) catch |err| {
                chunk.failure = err;
                return false;
            };
            chunk.rows += 1;
            chunk.after = next;
            if (!tail.streams()) {
                tail.visit(chunk.a, chunk.watched) catch |err| {
                    chunk.failure = err;
                    return false;
                };
                return true;
            }
            chunk.tail = tail;
            chunk.more = row.revision.get() < row.newest.get();
            return false;
        }

        fn take(chunk: *@This(), row: *const RevisionRow) Failure!RevisionTail {
            const revision = row.revision.get();
            const instructions_here: ContentOwner = .{ .revision = revision, .field = .instructions };
            const output_schema_here: ContentOwner = .{ .revision = revision, .field = .output_schema };
            const instructions: session_report.Text = .{ .id = row.instructions_id.get(), .length = row.instructions_length, .digest = row.instructions_digest };
            const output_schema = try optionalText(row.output_schema_id, row.output_schema_length, row.output_schema_digest);
            const instructions_owner = try ownerOf(row.instructions_owner, instructions_here);
            const output_schema_content: ?RevisionContent = if (output_schema) |value|
                .of(value, try ownerOf(row.output_schema_owner orelse return error.CorruptStore, output_schema_here), output_schema_here)
            else
                null;
            try visitRow(chunk.a, chunk.watched, &.{ .revision = try chunk.settings(row) });
            return .{ .instructions = .of(instructions, instructions_owner, instructions_here), .output_schema = output_schema_content };
        }

        fn ownerOf(slot: u64, here: ContentOwner) error{CorruptStore}!ContentOwner {
            if (slot > here.slot()) return error.CorruptStore;
            return .ofSlot(slot);
        }

        fn settings(chunk: *@This(), row: *const RevisionRow) error{CorruptStore}!session_report.Revision {
            if (row.label) |*label| try configuration_domain.checkLabel(label.slice());
            return .{
                .revision = row.revision.get(),
                .command_key = row.command_key.slice(),
                .workspace = row.workspace.slice(),
                .provider = row.provider,
                .model = row.model.slice(),
                .compaction_trigger = optional(row.compaction_trigger),
                .output_reservation = row.output_reservation,
                .reasoning_effort = row.reasoning_effort,
                .label = if (row.label) |*label| label.slice() else null,
                .tools = try sortedToolNames(if (row.tools) |*names| names.slice() else null, &chunk.tools),
                .loaded_tools = try sortedToolNames(if (row.loaded_tools) |*names| names.slice() else null, &chunk.loaded_tools),
                .permission_mode = try configuration_domain.permissionMode(row.permission_mode),
            };
        }
    };
}

noinline fn readRevisions(a: *ReadAccess, session_ref: []const u8, watched: anytype) !void {
    var after: full_revisions.Args = .{ .session = session_ref };
    const chunk = a.store.reportScratch(RevisionChunk(@TypeOf(watched)));
    while (true) {
        chunk.* = .{ .a = a, .watched = watched, .after = after };
        a.readEach(full_revisions, after, full_revisions.limit, chunk);
        const ran = store_access.runAs(a, error.SessionReadFailed);
        if (chunk.failure) |err| return err;
        try ran;
        if (chunk.tail) |*tail| try tail.visit(a, watched);
        if (!chunk.more) return;
        after = chunk.after;
    }
}

pub const full_messages = rsql.Page(.{
    .arms = &.{.{
        .on = .{ .index = "message_admission_position" },
        .alias = "m",
        .columns = "m.admission_id,m.command_key,m.content_id,input.byte_length AS content_length,input.digest AS content_digest," ++
            "m.turn_id,t.operation_id,o.attempt_ordinal,t.outcome_code,t.outcome_content_id,outcome.byte_length AS outcome_length,outcome.digest AS outcome_digest," ++
            "CASE WHEN m.turn_id IS NULL THEN (SELECT stopped.command_key FROM session_stop stopped " ++
            "WHERE stopped.session_ref=m.session_ref AND stopped.admission_cutoff>=m.admission_id " ++
            "ORDER BY stopped.admission_cutoff,stopped.position LIMIT 1) END AS excluding_stop",
        .joins = "LEFT JOIN content input ON input.content_id=m.content_id " ++
            "LEFT JOIN turn t ON t.turn_id=m.turn_id LEFT JOIN model_operation o ON o.operation_id=t.operation_id " ++
            "LEFT JOIN content outcome ON outcome.content_id=t.outcome_content_id",
    }},
    .Row = struct {
        admission_position: rsql.Positive,
        admission_id: rsql.Positive,
        command_key: Bounded(128),
        content_id: rsql.Positive,
        content_length: u64,
        content_digest: [32]u8,
        turn_id: ?rsql.Positive,
        operation_id: ?rsql.Positive,
        attempt_ordinal: ?rsql.Positive,
        outcome_code: ?Bounded(outcome_code.max_bytes),
        outcome_content_id: ?rsql.Positive,
        outcome_length: ?u64,
        outcome_digest: ?[32]u8,
        excluding_stop: ?Bounded(128),
    },
    .take = takes(Messages.kept_rows),
});

const unpositioned_message = rsql.Read(.{
    .sql = "SELECT 1 AS found FROM message_admission @index(message_admission_unpositioned) WHERE session_ref=?1 AND admission_position IS NULL LIMIT 1",
    .Args = struct { session: []const u8 },
    .Row = struct { found: bool },
    .cardinality = .optional,
});

pub const Messages = struct {
    pub const S = full_messages;
    pub const failed = error.MessageReadFailed;
    pub const list = session_report.FullList.messages;
    pub const kept_rows = 4;
    pub const First = unpositioned_message.Result;
    pub const FirstRead = unpositioned_message;
    pub const State = struct { admission: u64 = 0 };

    pub fn queueFirst(a: *ReadAccess, session: []const u8, found: *First) void {
        a.read(unpositioned_message, .{ .session = session }, found);
    }

    pub fn checkFirst(found: *const First) error{CorruptStore}!void {
        if (found.* != null) return error.CorruptStore;
    }

    pub fn check(state: *State, row: *const S.Row) error{CorruptStore}!void {
        if (row.admission_id.get() <= state.admission) return error.CorruptStore;
        state.admission = row.admission_id.get();
    }

    pub fn values(a: *ReadAccess, row: *const S.Row, _: *ListState(@This())) !session_report.FullRow {
        const projection = try command_domain.projectMessage(row, if (row.excluding_stop) |*stop| stop.slice() else null);
        const content: session_report.Text = .{ .id = row.content_id.get(), .length = row.content_length, .digest = row.content_digest };
        return .{ .message = .{
            .admission = projection.admission_id,
            .command_key = row.command_key.slice(),
            .content = content,
            .application = switch (projection.state) {
                .applied => |applied| .{ .applied = .{
                    .turn = applied.binding.turn_id,
                    .outcome = if (row.outcome_code) |*code| .{
                        .code = code.slice(),
                        .content = optionalReference(row.outcome_content_id, row.outcome_length, row.outcome_digest) catch |err| {
                            try readEarlier(a, &.{content});
                            return err;
                        },
                    } else null,
                } },
                .pending => .pending,
                .excluded => .{ .excluded = row.excluding_stop.?.slice() },
            },
        } };
    }
};

fn checkOutcome(code: anytype, content_id: ?rsql.Positive) error{CorruptStore}!void {
    if (code.* == null and content_id != null) return error.CorruptStore;
}

const full_conversation = rsql.Page(.{
    .arms = &.{.{
        .on = .{ .primary_key = "conversation_entry" },
        .alias = "e",
        .columns = "e.session_position,e.entry_kind,e.turn_id,coalesce(e.source_admission_id,e.source_skill_admission_id) AS source_admission_id,e.source_revision,e.source_catalog_position,e.source_skill_position,e.source_operation_id," ++
            "c.byte_length AS content_length,c.digest AS content_digest," ++ reads_domain.publicEntryColumns("(e.entry_kind=2 AND (e.source_catalog_position IS NULL OR " ++ skills_domain.instructionConsistentSql("e") ++ ")) OR " ++
            "(e.entry_kind=4 AND t.session_ref=e.session_ref AND EXISTS(SELECT 1 FROM message_skill skill JOIN message_admission owner ON owner.admission_id=skill.admission_id " ++
            "WHERE skill.admission_id=e.source_skill_admission_id AND skill.position=e.source_skill_position AND skill.content_id=e.content_id " ++
            "AND owner.session_ref=e.session_ref AND owner.turn_id=e.turn_id)) OR "),
        .joins = reads_domain.public_entry_joins,
    }},
    .Row = struct {
        entry_ordinal: rsql.Positive,
        session_position: rsql.Positive,
        entry_kind: u8,
        turn_id: ?rsql.Positive,
        source_admission_id: ?rsql.Positive,
        source_revision: ?rsql.Positive,
        source_catalog_position: ?rsql.Positive,
        source_skill_position: ?rsql.Positive,
        source_operation_id: ?rsql.Positive,
        content_length: u64,
        content_digest: [32]u8,
        consistent: bool,
    },
    .take = takes(Conversation.kept_rows),
});

const conversation_sources = rsql.Read(.{
    .sql = "SELECT " ++ skills_domain.sourcesConsistentSql("?1", "1=1") ++ " AS catalogs_consistent,NOT EXISTS(" ++
        reads_domain.missing_assistant_entry.sql ++ ") AS assistants_consistent",
    .Args = struct { session: []const u8, lower: u64, upper: u64 },
    .Row = struct { catalogs_consistent: bool, assistants_consistent: bool },
    .cardinality = .one,
});

pub const Conversation = struct {
    pub const S = full_conversation;
    pub const failed = error.ConversationReadFailed;
    pub const list = session_report.FullList.conversation;
    pub const kept_rows = 0;
    pub const First = conversation_sources.Row;
    pub const FirstRead = conversation_sources;

    pub fn queueFirst(a: *ReadAccess, session: []const u8, missing: *First) void {
        a.read(conversation_sources, .{ .session = session, .lower = 0, .upper = std.math.maxInt(i64) }, missing);
    }

    pub fn checkFirst(missing: *const First) error{CorruptStore}!void {
        if (!missing.catalogs_consistent or !missing.assistants_consistent) return error.CorruptStore;
    }

    pub fn values(_: *ReadAccess, row: *const S.Row, _: *ListState(@This())) error{CorruptStore}!session_report.FullRow {
        if (row.entry_kind < 1 or row.entry_kind > 4 or !row.consistent) return error.CorruptStore;
        return .{ .conversation = .{
            .ordinal = row.entry_ordinal.get(),
            .position = row.session_position.get(),
            .kind = @fromBackingInt(@intCast(row.entry_kind - 1)),
            .turn = optional(row.turn_id),
            .source_admission = optional(row.source_admission_id),
            .source_revision = optional(row.source_revision),
            .source_catalog_position = optional(row.source_catalog_position),
            .source_skill_position = optional(row.source_skill_position),
            .source_operation = optional(row.source_operation_id),
            .content = .{ .length = row.content_length, .digest = row.content_digest },
        } };
    }
};

const full_turns = rsql.Page(.{
    .arms = &.{.{
        .on = .{ .index = "turn_session_latest" },
        .alias = "t",
        .columns = "t.first_admission_id,t.input_cutoff,t.operation_id,t.outcome_code,t.outcome_content_id," ++
            "outcome.byte_length AS outcome_length,outcome.digest AS outcome_digest",
        .joins = "LEFT JOIN content outcome ON outcome.content_id=t.outcome_content_id",
    }},
    .Row = struct {
        turn_id: rsql.Positive,
        first_admission_id: rsql.Positive,
        input_cutoff: u64,
        operation_id: rsql.Positive,
        outcome_code: ?Bounded(outcome_code.max_bytes),
        outcome_content_id: ?rsql.Positive,
        outcome_length: ?u64,
        outcome_digest: ?[32]u8,
    },
    .take = takes(Turns.kept_rows),
});

const Turns = struct {
    pub const S = full_turns;
    pub const failed = error.TurnReadFailed;
    pub const list = session_report.FullList.turns;
    pub const kept_rows = 0;

    pub fn values(_: *ReadAccess, row: *const S.Row, _: *ListState(@This())) error{CorruptStore}!session_report.FullRow {
        if (row.input_cutoff < row.first_admission_id.get()) return error.CorruptStore;
        try checkOutcome(&row.outcome_code, row.outcome_content_id);
        return .{ .turn = .{
            .turn = row.turn_id.get(),
            .first_admission = row.first_admission_id.get(),
            .input_cutoff = row.input_cutoff,
            .operation = row.operation_id.get(),
            .outcome = if (row.outcome_code) |*code| .{
                .code = code.slice(),
                .content = try optionalReference(row.outcome_content_id, row.outcome_length, row.outcome_digest),
            } else null,
        } };
    }
};

const full_operations = rsql.Page(.{
    .arms = &.{.{
        .on = .{ .index = "model_operation_session_history" },
        .alias = "o",
        .columns = "o.turn_id,o.resolution_code,o.resolution_content_id,resolution.byte_length AS resolution_length," ++
            "resolution.digest AS resolution_digest,o.interrupted_by_command_key,o.settings_revision,o.request_id,o.reasoning_effort," ++
            tool_set.namesSql("o.tool_set_id") ++ " AS offered_tools",
        .joins = "LEFT JOIN content resolution ON resolution.content_id=o.resolution_content_id",
    }},
    .Row = struct {
        operation_id: rsql.Positive,
        turn_id: rsql.Positive,
        resolution_code: ?Bounded(outcome_code.max_bytes),
        resolution_content_id: ?rsql.Positive,
        resolution_length: ?u64,
        resolution_digest: ?[32]u8,
        interrupted_by_command_key: ?Bounded(128),
        settings_revision: rsql.Positive,
        request_id: ?Bounded(256),
        reasoning_effort: ?model_capability.ReasoningEffort,
        offered_tools: ?Bounded(tool_set.max_offered_names_bytes),
    },
    .take = takes(Operations.kept_rows),
});

const Operations = struct {
    pub const S = full_operations;
    pub const failed = error.OperationReadFailed;
    pub const list = session_report.FullList.model_operations;
    // Keep names with each retained row until resolution content can stream after the query.
    // Two retained rows and the decode row fit the Store's existing report scratch.
    pub const kept_rows = 2;
    pub const State = struct { names: [tool_name.max_offered_tools][]const u8 = undefined };

    pub fn check(_: *State, row: *const S.Row) error{CorruptStore}!void {
        try checkOutcome(&row.resolution_code, row.resolution_content_id);
    }

    pub fn values(_: *ReadAccess, row: *const S.Row, state: *State) error{CorruptStore}!session_report.FullRow {
        return .{ .operation = .{
            .operation = row.operation_id.get(),
            .turn = row.turn_id.get(),
            .resolution = if (row.resolution_code) |*code| .{
                .code = code.slice(),
                .content = try optionalText(row.resolution_content_id, row.resolution_length, row.resolution_digest),
            } else null,
            .interrupted_by = optionalSlice(&row.interrupted_by_command_key),
            .settings_revision = row.settings_revision.get(),
            .offered_tools = try sortedToolNames(if (row.offered_tools) |*names| names.slice() else null, &state.names),
            .request_id = optionalSlice(&row.request_id),
            .reasoning_effort = row.reasoning_effort,
        } };
    }
};

fn optionalSlice(text: anytype) ?[]const u8 {
    return if (text.*) |*value| value.slice() else null;
}

const call_contents = "LEFT JOIN content name_content ON name_content.content_id=tool_call.name_content_id " ++
    "LEFT JOIN content call_id_content ON call_id_content.content_id=tool_call.call_id_content_id " ++
    "LEFT JOIN content arguments_content ON arguments_content.content_id=tool_call.arguments_content_id " ++
    "LEFT JOIN content rejection_content ON rejection_content.content_id=tool_call.rejection_content_id";

pub const full_calls = rsql.Page(.{
    .arms = &.{.{
        .on = .{ .index = "model_tool_call_session_order" },
        .alias = "tool_call",
        .columns = "tool_call.item_ordinal,tool_call.rejection_code,tool_call.acceptance_position," ++
            "tool_call.name_content_id AS name_id,name_content.byte_length AS name_length,name_content.digest AS name_digest," ++
            "tool_call.call_id_content_id AS call_id,call_id_content.byte_length AS call_id_length,call_id_content.digest AS call_id_digest," ++
            "tool_call.arguments_content_id AS arguments_id,arguments_content.byte_length AS arguments_length,arguments_content.digest AS arguments_digest," ++
            "tool_call.rejection_content_id AS rejection_id,rejection_content.byte_length AS rejection_length,rejection_content.digest AS rejection_digest",
        .joins = call_contents,
    }},
    .Row = struct {
        operation_id: rsql.Positive,
        call_ordinal: u64,
        item_ordinal: u64,
        rejection_code: ?Bounded(32),
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
    .take = takes(Calls.kept_rows),
});

const Calls = struct {
    pub const S = full_calls;
    pub const failed = error.CallReadFailed;
    pub const list = session_report.FullList.tool_calls;
    pub const kept_rows = 8;

    pub fn values(a: *ReadAccess, row: *const S.Row, _: *ListState(@This())) !session_report.FullRow {
        const name: session_report.Text = .{ .id = row.name_id.get(), .length = row.name_length, .digest = row.name_digest };
        const call_id: session_report.Text = .{ .id = row.call_id.get(), .length = row.call_id_length, .digest = row.call_id_digest };
        const arguments: session_report.Text = .{ .id = row.arguments_id.get(), .length = row.arguments_length, .digest = row.arguments_digest };
        return .{ .call = .{
            .operation = row.operation_id.get(),
            .call_ordinal = row.call_ordinal,
            .item_ordinal = row.item_ordinal,
            .rejection = optionalSlice(&row.rejection_code),
            .acceptance_position = optional(row.acceptance_position),
            .name = name,
            .call_id = call_id,
            .arguments = arguments,
            .rejection_result = optionalText(row.rejection_id, row.rejection_length, row.rejection_digest) catch |err| {
                try readEarlier(a, &.{ name, call_id, arguments });
                return err;
            },
        } };
    }
};

const full_actions = rsql.Page(.{
    .arms = &.{.{
        .on = .{ .index = "action_operation_session_order" },
        .alias = "action",
        .columns = "action.parent_operation_id,action.call_ordinal,action.permission_revision," ++
            "CASE WHEN @same(action.resolution_code,'denied') THEN 'denied' WHEN action.authorized=1 THEN 'authorized' ELSE 'requested' END AS permission," ++
            "action.resolution_code,action.resolution_content_id,result.byte_length AS result_length,result.digest AS result_digest,action.acceptance_position",
        .joins = "LEFT JOIN content result ON result.content_id=action.resolution_content_id",
    }},
    .Row = struct {
        action_id: rsql.Positive,
        parent_operation_id: rsql.Positive,
        call_ordinal: u64,
        permission_revision: rsql.Positive,
        permission: Bounded(16),
        resolution_code: ?Bounded(max_action_resolution_code_bytes),
        resolution_content_id: ?rsql.Positive,
        result_length: ?u64,
        result_digest: ?[32]u8,
        acceptance_position: ?rsql.Positive,
    },
    .take = takes(Actions.kept_rows),
});

const Actions = struct {
    pub const S = full_actions;
    pub const failed = error.ActionReadFailed;
    pub const list = session_report.FullList.actions;
    pub const kept_rows = 4;

    pub fn values(_: *ReadAccess, row: *const S.Row, _: *ListState(@This())) error{CorruptStore}!session_report.FullRow {
        return .{
            .action = .{
                .action = row.action_id.get(),
                .parent_operation = row.parent_operation_id.get(),
                .call_ordinal = row.call_ordinal,
                .permission_revision = row.permission_revision.get(),
                .permission = std.meta.stringToEnum(session_report.Permission, row.permission.slice()) orelse return error.CorruptStore,
                .resolution = optionalSlice(&row.resolution_code),
                .result = try optionalText(row.resolution_content_id, row.result_length, row.result_digest),
                .acceptance_position = optional(row.acceptance_position),
            },
        };
    }
};

const full_decisions = rsql.Page(.{
    .arms = &.{.{
        .on = .{ .index = "core_command_target_order" },
        .alias = "command",
        .fixed = &.{.{ .column = "kind", .value = "5" }},
        .columns = "decision.command_key,decision.action_id,decision.decision,command.accepted,command.code",
        .joins = "LEFT JOIN permission_decision_command decision ON decision.command_key=command.command_key",
    }},
    .Row = struct {
        command_seq: rsql.Positive,
        command_key: Bounded(128),
        action_id: Bounded(20),
        decision: mutation_answer.PermissionDecision,
        accepted: bool,
        code: Bounded(96),
    },
    .take = takes(Decisions.kept_rows),
});

const Decisions = struct {
    pub const S = full_decisions;
    pub const failed = error.PermissionReadFailed;
    pub const list = session_report.FullList.permission_decisions;
    pub const kept_rows = 0;

    pub fn values(_: *ReadAccess, row: *const S.Row, _: *ListState(@This())) error{}!session_report.FullRow {
        return .{ .decision = .{
            .command_key = row.command_key.slice(),
            .action = row.action_id.slice(),
            .decision = row.decision,
            .accepted = row.accepted,
            .code = row.code.slice(),
        } };
    }
};

pub const full_stops = rsql.Page(.{
    .arms = &.{.{
        .on = .{ .index = "core_command_target_order" },
        .alias = "command",
        .fixed = &.{.{ .column = "kind", .value = "3" }},
        .columns = "command.command_key,command.accepted,command.code,stop.selected_turn_id,stop.admission_cutoff",
        .joins = "LEFT JOIN session_stop stop ON stop.command_key=command.command_key",
    }},
    .Row = struct {
        command_seq: rsql.Positive,
        command_key: Bounded(128),
        accepted: bool,
        code: Bounded(96),
        selected_turn_id: ?rsql.Positive,
        admission_cutoff: ?u64,
    },
    .take = takes(Stops.kept_rows),
});

const Stops = struct {
    pub const S = full_stops;
    pub const failed = error.SessionStopReadFailed;
    pub const list = session_report.FullList.session_stops;
    pub const kept_rows = 0;

    pub fn values(_: *ReadAccess, row: *const S.Row, _: *ListState(@This())) error{}!session_report.FullRow {
        return .{ .stop = .{
            .command_key = row.command_key.slice(),
            .accepted = row.accepted,
            .code = row.code.slice(),
            .selected_turn = optional(row.selected_turn_id),
            .admission_cutoff = row.admission_cutoff,
        } };
    }
};

pub const full_interruptions = rsql.Page(.{
    .arms = &.{.{
        .on = .{ .index = "core_command_target_order" },
        .alias = "command",
        .fixed = &.{.{ .column = "kind", .value = "4" }},
        .columns = "command.command_key,command.accepted,command.code,interruption.turn_id,interruption.operation_id",
        .joins = "LEFT JOIN model_interruption_command interruption ON interruption.command_key=command.command_key " ++
            "AND interruption.session_ref=command.target",
    }},
    .Row = struct {
        command_seq: rsql.Positive,
        command_key: Bounded(128),
        accepted: bool,
        code: Bounded(96),
        turn_id: Bounded(20),
        operation_id: Bounded(20),
    },
    .take = takes(Interruptions.kept_rows),
});

const Interruptions = struct {
    pub const S = full_interruptions;
    pub const failed = error.InterruptionReadFailed;
    pub const list = session_report.FullList.model_interruptions;
    pub const kept_rows = 0;
    pub const State = struct {};

    pub fn check(_: *State, row: *const S.Row) error{CorruptStore}!void {
        if (row.turn_id.slice().len == 0) return error.CorruptStore;
    }

    pub fn values(_: *ReadAccess, row: *const S.Row, _: *ListState(@This())) error{}!session_report.FullRow {
        return .{ .interruption = .{
            .command_key = row.command_key.slice(),
            .accepted = row.accepted,
            .code = row.code.slice(),
            .turn = row.turn_id.slice(),
            .operation = row.operation_id.slice(),
        } };
    }
};

pub const full_results = rsql.Page(.{
    .arms = &.{
        .{
            .on = .{ .index = "model_tool_call_session_results" },
            .alias = "tool_call",
            .columns = "tool_call.call_ordinal,tool_call.call_id_content_id AS call_id,call_id_content.byte_length AS call_id_length," ++
                "call_id_content.digest AS call_id_digest,tool_call.rejection_code AS code,tool_call.rejection_content_id AS result_id," ++
                "result.byte_length AS result_length,result.digest AS result_digest",
            .joins = "LEFT JOIN content call_id_content ON call_id_content.content_id=tool_call.call_id_content_id " ++
                "LEFT JOIN content result ON result.content_id=tool_call.rejection_content_id",
        },
        .{
            .on = .{ .index = "action_operation_session_results" },
            .alias = "action",
            .columns = "action.call_ordinal,tool_call.call_id_content_id AS call_id,call_id_content.byte_length AS call_id_length," ++
                "call_id_content.digest AS call_id_digest,action.resolution_code AS code,action.resolution_content_id AS result_id," ++
                "result.byte_length AS result_length,result.digest AS result_digest",
            .joins = "LEFT JOIN model_tool_call tool_call ON tool_call.operation_id=action.parent_operation_id AND tool_call.call_ordinal=action.call_ordinal " ++
                "LEFT JOIN content call_id_content ON call_id_content.content_id=tool_call.call_id_content_id " ++
                "LEFT JOIN content result ON result.content_id=action.resolution_content_id",
        },
        .{
            .on = .{ .index = "action_operation_background_results" },
            .alias = "action",
            .columns = "action.call_ordinal,tool_call.call_id_content_id AS call_id,call_id_content.byte_length AS call_id_length," ++
                "call_id_content.digest AS call_id_digest,'background' AS code,action.background_content_id AS result_id," ++
                "result.byte_length AS result_length,result.digest AS result_digest",
            .joins = "LEFT JOIN model_tool_call tool_call ON tool_call.operation_id=action.parent_operation_id AND tool_call.call_ordinal=action.call_ordinal " ++
                "LEFT JOIN content call_id_content ON call_id_content.content_id=tool_call.call_id_content_id " ++
                "LEFT JOIN content result ON result.content_id=action.background_content_id",
        },
    },
    .Row = struct {
        operation_id: rsql.Positive,
        acceptance_position: rsql.Positive,
        call_ordinal: u64,
        call_id: rsql.Positive,
        call_id_length: u64,
        call_id_digest: [32]u8,
        code: Bounded(32),
        result_id: rsql.Positive,
        result_length: u64,
        result_digest: [32]u8,
    },
    .take = takes(Results.kept_rows),
});

const Results = struct {
    pub const S = full_results;
    pub const failed = error.CallReadFailed;
    pub const list = session_report.FullList.tool_results;
    pub const kept_rows = 8;

    pub fn values(_: *ReadAccess, row: *const S.Row, _: *ListState(@This())) error{}!session_report.FullRow {
        return .{ .result = .{
            .operation = row.operation_id.get(),
            .call_ordinal = row.call_ordinal,
            .acceptance_position = row.acceptance_position.get(),
            .call_id = .{ .id = row.call_id.get(), .length = row.call_id_length, .digest = row.call_id_digest },
            .code = row.code.slice(),
            .result = .{ .id = row.result_id.get(), .length = row.result_length, .digest = row.result_digest },
        } };
    }
};
