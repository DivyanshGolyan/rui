//! Shared fixtures for the SQLite mechanism tests under sqlite_tests/.
//! Those tests observe VM steps, statement caches, engine passes, blob
//! handles, PRAGMAs, the schema catalog or engine-specific raw SQL.
//! tests.zig and tests/ hold the fixtures and tests every engine runs.

const tests = @import("tests.zig");
const std = @import("std");
const named_scratch = @import("../named_scratch.zig");
const platform = @import("../store_path.zig");
const protocol = @import("../protocol.zig");
const wire_request = @import("../wire_request.zig");
const model_capability = @import("../model_capability.zig");
const product_defaults = @import("../product_defaults.zig");
const tool_defs = @import("../tools.zig");
const output_format = @import("../output_format.zig");
const output_decode = @import("../output_decode.zig");
const retry_policy = @import("../retry_policy.zig");
const change_ring = @import("../change_ring.zig");
const store_core = @import("Store.zig");
const store_access = @import("access.zig");
const transition = @import("transition.zig");
const rsql = @import("rsql.zig");
const Store = store_core.Store;
const action_domain = @import("domain/action.zig");
const command_domain = @import("domain/command.zig");
const configuration_domain = @import("domain/configuration.zig");
const content_domain = @import("domain/content.zig");
const historical_domain = @import("domain/historical.zig");
const history_floor_domain = @import("domain/history_floor.zig");
const model_admission_domain = @import("domain/model_admission.zig");
const model_settlement_domain = @import("domain/model_settlement.zig");
const reads_domain = @import("domain/reads.zig");
const report_domain = @import("domain/report.zig");
const session_list_read_domain = @import("domain/session_list_read.zig");
const session_report_read_domain = @import("domain/session_report_read.zig");
const session_list_reply = @import("../session_list_reply.zig");
const store_schema = @import("schema.zig");
const sqlite = @import("sqlite.zig");
const test_poll = @import("test_poll");
const store_testing = @import("testing.zig");
const turn_domain = @import("domain/turn.zig");
const c = sqlite.c;
const AcceptedMessage = command_domain.AcceptedMessage;
const ActionAttemptBinding = action_domain.ActionAttemptBinding;
const ActionSettlement = action_domain.ActionSettlement;
const ActiveOperationFilter = action_domain.ActiveOperationFilter;
const AttemptAdmission = model_admission_domain.AttemptAdmission;
const AttemptBinding = store_core.AttemptBinding;
const ActionExecutionInput = action_domain.ActionExecutionInput;
const ConfigurationContentAction = configuration_domain.ConfigurationContentAction;
const ConfigurationUpdatePlan = configuration_domain.ConfigurationUpdatePlan;
const ConfigureReply = configuration_domain.ConfigureReply;
const ContentReader = content_domain.ContentReader;
const ContentReference = content_domain.ContentReference;
const ControlTracePhase = store_core.ControlTracePhase;
const CurrentConfiguration = configuration_domain.CurrentConfiguration;
const Faults = store_core.Faults;
const HistoricalContent = historical_domain.HistoricalContent;
const HistoricalEntry = historical_domain.HistoricalEntry;
const HistoricalEntryKind = historical_domain.HistoricalEntryKind;
const HistoricalReader = historical_domain.HistoricalReader;
const HistoricalSettings = historical_domain.HistoricalSettings;
const HistoricalView = historical_domain.HistoricalView;
const MessageReply = command_domain.MessageReply;
const ModelAdmissionKind = model_admission_domain.ModelAdmissionKind;
const ModelFailure = model_settlement_domain.ModelFailure;
const ModelInterruptionReply = command_domain.ModelInterruptionReply;
const ModelOperationKind = historical_domain.ModelOperationKind;
const OutputItemKind = historical_domain.OutputItemKind;
const OutputMetadataWriter = store_testing.OutputMetadataWriter;
const PermissionDecisionReply = command_domain.PermissionDecisionReply;
const SessionReport = report_domain.SessionReport;
const SessionStopReply = command_domain.SessionStopReply;
const SettlementTracePhase = store_core.SettlementTracePhase;
const StatementCache = sqlite.StatementCache;
const TestingAnswerPart = store_testing.TestingAnswerPart;
const TurnOutcome = turn_domain.TurnOutcome;
const ValidatedOutput = model_settlement_domain.ValidatedOutput;
const answerTestTurn = store_testing.answerTestTurn;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const completeMessage = store_testing.completeMessage;
const configureTestSession = store_testing.configureTestSession;
const empty_active_context = action_domain.empty_active_context;
const next_action_attempt_sql = action_domain.next_action_attempt_sql;
const pending_message_count_sql = command_domain.pending_message_count_sql;
const retry_admission_page_rows = model_admission_domain.retry_admission_page_rows;
const retry_admission_select_sql = model_admission_domain.retry_admission_select_sql;
const retry_exhausted_sql = model_admission_domain.retry_exhausted_sql;
const runnable_selection_sql = model_admission_domain.runnable_selection_sql;
const schema_version = store_schema.schema_version;
const session_stop_cutoff_sql = command_domain.session_stop_cutoff_sql;
const settleCompactionForTesting = store_testing.settleCompactionForTesting;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const sqlite_heap_bytes = sqlite.sqlite_heap_bytes;
const submitTestMessage = store_testing.submitTestMessage;
const testingPublicProjection = store_testing.testingPublicProjection;
const testing_absent_model_evidence = store_testing.testing_absent_model_evidence;
const tool_continuation_selection = model_admission_domain.tool_continuation_selection;

const output_metadata_record_bytes = output_format.output_metadata_record_bytes;

const TestingAttempt = tests.TestingAttempt;
const TestingCall = tests.TestingCall;
const TestingCommits = tests.TestingCommits;
const TestingContentReference = tests.TestingContentReference;
const TestingHistoryCursor = tests.TestingHistoryCursor;
const TestingListRow = tests.TestingListRow;
const TestingListing = tests.TestingListing;
const TestingRejectedCall = tests.TestingRejectedCall;
const TestingReportAction = tests.TestingReportAction;
const TestingResolvedAction = tests.TestingResolvedAction;
const TestingRound = tests.TestingRound;
const TestingSessionReport = tests.TestingSessionReport;
const TestingWorkShape = tests.TestingWorkShape;
const admitRetryForTesting = tests.admitRetryForTesting;
const completeModelInterruption = tests.completeModelInterruption;
const completeSessionStop = tests.completeSessionStop;
const configureTestSessionAsk = tests.configureTestSessionAsk;
const costCycleForTesting = tests.costCycleForTesting;
const denyForTesting = tests.denyForTesting;
const expectActivityOutcome = tests.expectActivityOutcome;
const expectContent = tests.expectContent;
const expectOneWork = tests.expectOneWork;
const namedStatementForTesting = tests.namedStatementForTesting;
const readTestingContent = tests.readTestingContent;
const renderTestingEntry = tests.renderTestingEntry;
const settleCallsForTesting = tests.settleCallsForTesting;
const settleCallsForTestingWithFaults = tests.settleCallsForTestingWithFaults;
const settleMessagesForTesting = tests.settleMessagesForTesting;
const settleTwoActionsForTesting = tests.settleTwoActionsForTesting;
const rejectedCallsForTesting = tests.rejectedCallsForTesting;
const testSettings = tests.testSettings;
const testingBytesContent = tests.testingBytesContent;
const testingContent = tests.testingContent;
const testingContentReference = tests.testingContentReference;
const testingFullHistory = tests.testingFullHistory;
const testingListRow = tests.testingListRow;
const testingSessionList = tests.testingSessionList;
const testingSessionReport = tests.testingSessionReport;
const testingSessionReportWithProfile = tests.testingSessionReportWithProfile;
const touchForTesting = tests.touchForTesting;

const hostToolRecordsWith = store_testing.hostToolRecordsWith;
const sortHostToolRecords = store_testing.sortHostToolRecords;

/// A tool set with one tool beyond the built-ins, between them by name.
const testing_record: tool_defs.Record = .{ .name = "test_tool", .owner = .rui, .description = "A tool only tests offer.", .input_schema = "{\"type\":\"object\"}" };
const testing_records = hostToolRecordsWith(&.{testing_record});
const testing_digests = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: [testing_records.len][32]u8 = undefined;
    for (&testing_records, &out) |*each, *digest| digest.* = tool_defs.recordDigest(each);
    break :blk out;
};
pub const testing_tool_set: tool_defs.HostToolSet = .{ .records = &testing_records, .digests = &testing_digests };

const testingStoreToolSet = store_testing.testingStoreToolSet;
const testingStore = store_testing.testingSqliteStore;

pub fn createMaximumCanonicalStore(tmp: *std.testing.TmpDir, path_buffer: []u8) ![]const u8 {
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const relative_length = protocol.max_store_bytes - root.len - 1;
    var relative_buffer: [protocol.max_store_bytes]u8 = undefined;
    var offset: usize = 0;
    var remaining = relative_length;
    while (remaining > 255) {
        @memset(relative_buffer[offset .. offset + 255], 'a');
        relative_buffer[offset + 255] = '/';
        offset += 256;
        remaining -= 256;
    }
    if (remaining == 0) return error.InvalidStoreTestPath;
    @memset(relative_buffer[offset .. offset + remaining], 'b');
    const relative = relative_buffer[0 .. offset + remaining];
    var directory = try tmp.dir.createDirPathOpen(std.testing.io, relative, .{
        .permissions = .fromMode(0o700),
    });
    directory.close(std.testing.io);
    const path = try std.fmt.bufPrint(path_buffer, "{s}/{s}", .{ root, relative });
    std.debug.assert(path.len == protocol.max_store_bytes);
    return path;
}

/// Test aid: statements left mid-step. Cached statements are reset and idle;
/// read blobs must close before the Store entry point returns.
pub fn busyStatements(database: *c.sqlite3) usize {
    var count: usize = 0;
    var statement = c.sqlite3_next_stmt(database, null);
    while (statement) |current| : (statement = c.sqlite3_next_stmt(database, current)) {
        if (c.sqlite3_stmt_busy(current) != 0) count += 1;
    }
    return count;
}

/// Counts SQLite VM steps from `begin` to `end`. Preparing a statement also
/// steps, so measure a call only after the same call prepared its
/// statements.
pub const TestingSteps = struct {
    steps: u64 = 0,

    pub fn begin(self: *TestingSteps, database: *c.sqlite3) void {
        c.sqlite3_progress_handler(database, 1, progress, self);
    }

    pub fn end(_: *const TestingSteps, database: *c.sqlite3) void {
        c.sqlite3_progress_handler(database, 0, null, null);
    }

    pub fn progress(context: ?*anyopaque) callconv(.c) c_int {
        const self: *TestingSteps = @ptrCast(@alignCast(context.?));
        self.steps += 1;
        return 0;
    }
};

/// Interrupts the one statement whose text is `sql` as it steps, the way an
/// I/O fault fails a read. No schema changes, so no cached plan expires.
pub const TestingStatementFault = struct {
    sql: [:0]const u8,
    running: bool = false,
    failed: u64 = 0,

    pub fn arm(self: *TestingStatementFault, database: *c.sqlite3) void {
        _ = c.sqlite3_trace_v2(database, c.SQLITE_TRACE_STMT, traced, self);
        c.sqlite3_progress_handler(database, 1, progress, self);
    }

    pub fn disarm(_: *const TestingStatementFault, database: *c.sqlite3) void {
        _ = c.sqlite3_trace_v2(database, 0, null, null);
        c.sqlite3_progress_handler(database, 0, null, null);
    }

    pub fn traced(_: c_uint, context: ?*anyopaque, statement: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self: *TestingStatementFault = @ptrCast(@alignCast(context.?));
        self.running = std.mem.eql(u8, std.mem.span(c.sqlite3_sql(@ptrCast(statement))), self.sql);
        return 0;
    }

    pub fn progress(context: ?*anyopaque) callconv(.c) c_int {
        const self: *TestingStatementFault = @ptrCast(@alignCast(context.?));
        if (!self.running) return 0;
        self.failed += 1;
        return 1;
    }
};

/// Every claimed Session position is used exactly once: the claims, from
/// every table that saves one, are exactly 1 through `next_position - 1`.
pub fn expectDenseSessionPositions(storage: *Store, session: []const u8) !void {
    // Each compound keeps within the Store's four-term limit.
    const statement = try sqlite.prepare(storage.sqliteDatabase(), "WITH messages(position) AS (" ++
        "SELECT admission_position FROM message_admission WHERE session_ref=?1 AND admission_position IS NOT NULL " ++
        "UNION ALL SELECT sender_position FROM message_admission WHERE sender_session_ref=?1 " ++
        "UNION ALL SELECT sender_position FROM sent_rejection WHERE sender_session_ref=?1 " ++
        "UNION ALL SELECT session_position FROM conversation_entry WHERE session_ref=?1 AND entry_kind!=3), " ++
        "model(position) AS (SELECT admission_position FROM model_operation WHERE session_ref=?1 " ++
        "UNION ALL SELECT session_position FROM model_output_item WHERE session_ref=?1 " ++
        "UNION ALL SELECT tool_call.acceptance_position FROM model_tool_call tool_call JOIN model_operation op ON op.operation_id=tool_call.operation_id " ++
        "WHERE op.session_ref=?1 AND tool_call.acceptance_position IS NOT NULL), " ++
        "settled(position) AS (SELECT acceptance_position FROM action_operation WHERE session_ref=?1 AND acceptance_position IS NOT NULL " ++
        "UNION ALL SELECT outcome_position FROM turn WHERE session_ref=?1 AND outcome_position IS NOT NULL " ++
        "UNION ALL SELECT position FROM session_stop WHERE session_ref=?1 " ++
        "UNION ALL SELECT position FROM session_forward WHERE target_ref=?1 AND position IS NOT NULL), " ++
        "claimed(position) AS (SELECT position FROM messages UNION ALL SELECT position FROM model UNION ALL SELECT position FROM settled) " ++
        "SELECT count(*),count(DISTINCT position),coalesce(min(position),1),coalesce(max(position),0)," ++
        "(SELECT next_position FROM session WHERE session_ref=?1) FROM claimed");
    defer _ = c.sqlite3_finalize(statement);
    try sqlite.bindText(statement, 1, session);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
    const count = c.sqlite3_column_int64(statement, 0);
    try std.testing.expectEqual(count, c.sqlite3_column_int64(statement, 1));
    try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(statement, 2));
    try std.testing.expectEqual(count, c.sqlite3_column_int64(statement, 3));
    try std.testing.expectEqual(count + 1, c.sqlite3_column_int64(statement, 4));
}

pub const ConstraintProbe = enum { accepted, check_violation, other_failure };

/// Runs one write inside a rolled-back savepoint and reports whether SQLite
/// accepted it or rejected it on a CHECK rather than another constraint.
pub fn probeConstraint(database: *c.sqlite3, sql: [:0]const u8) !ConstraintProbe {
    try sqlite.exec(database, "SAVEPOINT constraint_probe");
    defer sqlite.exec(database, "ROLLBACK TO constraint_probe; RELEASE constraint_probe") catch unreachable;
    const statement = try sqlite.prepare(database, sql);
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) == c.SQLITE_DONE) return .accepted;
    return if (c.sqlite3_extended_errcode(database) == c.SQLITE_CONSTRAINT_CHECK) .check_violation else .other_failure;
}

pub fn expectModelRevisions(storage: *Store, session: []const u8, phase: []const u8) !void {
    for (0..6) |variant| {
        const before = try storage.inspectSessionForTesting(session);
        var key_buffer: [128]u8 = undefined;
        var update: wire_request.ConfigureCommand = .{};
        try update.key.set(try std.fmt.bufPrint(&key_buffer, "binding-{s}-{d}", .{ phase, variant }));
        try update.session.set(session);
        if (variant & 1 != 0 or variant == 4) {
            update.configuration.provider.state = .value;
            try update.configuration.provider.value.set(if (variant == 4) "anthropic" else "codex");
        }
        if (variant & 2 != 0 or variant == 5) {
            update.configuration.model.state = .value;
            try update.configuration.model.value.set(if (variant == 5) "model-b" else "model-a");
        }
        if (variant == 4) {
            update.configuration.tools.state = .value;
            update.configuration.tools.count = 0;
            update.configuration.permission_mode.state = .value;
            try update.configuration.permission_mode.value.set("bypass");
        }
        const reply = try storage.configure(&update, .{});
        if (variant != 4) {
            try std.testing.expect(reply == .accepted);
            try std.testing.expectEqual(before.revision + 1, reply.accepted.revision);
        } else {
            try std.testing.expect(reply == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_provider, reply.rejected.code);
        }
        const after = try storage.inspectSessionForTesting(session);
        try std.testing.expectEqual(before.revision + @as(u64, if (variant != 4) 1 else 0), after.revision);
        try std.testing.expectEqual(protocol.Provider.codex, after.provider.?);
        try std.testing.expectEqualStrings(if (update.configuration.model.state == .value) update.configuration.model.value.slice() else before.model.slice(), after.model.slice());
        if (variant == 5) {
            try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(storage, "SELECT count(*) FROM session_change WHERE session_ref=?1 AND revision=?2 AND field='model'", .{ session, after.revision }));
        }
        try std.testing.expectEqual(before.tool_set_id, after.tool_set_id);
        try std.testing.expectEqualStrings(before.permission_mode.slice(), after.permission_mode.slice());
        try std.testing.expectEqualDeep(before.instructions, after.instructions);
        try std.testing.expectEqualDeep(before.output_schema, after.output_schema);
    }
}

/// Gives `session` Bash, has its model propose two calls, and attempts
/// the first; the second stays unattempted.
pub fn attemptBashForTesting(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8) !ActionAttemptBinding {
    var tools: wire_request.ConfigureCommand = .{};
    try tools.key.set("bash-tools");
    try tools.session.set(session);
    tools.configuration.tools = try .of(&.{"bash"});
    tools.configuration.permission_mode.state = .value;
    try tools.configuration.permission_mode.value.set("bypass");
    try std.testing.expect(try storage.configure(&tools, .{}) == .accepted);
    try submitTestMessage(storage, tmp, "bash-seed", "bash-seed", session, "run two");
    try settleTwoActionsForTesting(storage, tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding, "bash-calls");
    return (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
}

/// Counts the statements the Store starts from `begin` to `end`: not a
/// trigger's program, nor the test-only touch oracle's read.
pub const TestingStatements = struct {
    count: u64 = 0,

    pub fn begin(self: *TestingStatements, database: *c.sqlite3) void {
        _ = c.sqlite3_trace_v2(database, c.SQLITE_TRACE_STMT, traced, self);
    }

    pub fn end(_: *const TestingStatements, database: *c.sqlite3) void {
        _ = c.sqlite3_trace_v2(database, 0, null, null);
    }

    pub fn traced(_: c_uint, context: ?*anyopaque, _: ?*anyopaque, text: ?*anyopaque) callconv(.c) c_int {
        const self: *TestingStatements = @ptrCast(@alignCast(context.?));
        const sql = std.mem.span(@as([*:0]const u8, @ptrCast(text.?)));
        if (!std.mem.startsWith(u8, sql, "--") and std.mem.indexOf(u8, sql, "touched_oracle") == null) self.count += 1;
        return 0;
    }
};

/// The Store id store_meta holds in the database at `path`.
pub fn storeId(path: []const u8) ![2 * store_schema.store_id_bytes]u8 {
    const raw = try openRaw(path);
    defer _ = c.sqlite3_close(raw);
    const statement = try sqlite.prepare(raw, "SELECT meta_value FROM store_meta WHERE meta_key='store_id'");
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.NoStoreId;
    const text = c.sqlite3_column_text(statement, 0) orelse return error.NoStoreId;
    const id = text[0..@intCast(c.sqlite3_column_bytes(statement, 0))];
    if (!store_schema.isStoreId(id)) return error.NoStoreId;
    return id[0 .. 2 * store_schema.store_id_bytes].*;
}

/// The statements and VM steps the Store's statements ran since the last
/// call, without the test-only touch oracle's.
pub fn statementWorkSince(database: *c.sqlite3) [2]i64 {
    var work: [2]i64 = .{ 0, 0 };
    var statement = c.sqlite3_next_stmt(database, null);
    while (statement) |each| : (statement = c.sqlite3_next_stmt(database, each)) {
        const runs = c.sqlite3_stmt_status(each, c.SQLITE_STMTSTATUS_RUN, 1);
        const steps = c.sqlite3_stmt_status(each, c.SQLITE_STMTSTATUS_VM_STEP, 1);
        if (std.mem.indexOf(u8, std.mem.span(c.sqlite3_sql(each)), "touched_oracle") != null) continue;
        work[0] += runs;
        work[1] += steps;
    }
    return work;
}

pub fn openRaw(path: []const u8) !*c.sqlite3 {
    var raw: ?*c.sqlite3 = null;
    var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
    if (c.sqlite3_open(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{path}, 0), &raw) != c.SQLITE_OK) {
        if (raw) |database| _ = c.sqlite3_close(database);
        return error.StoreOpenFailed;
    }
    return raw.?;
}

/// Every SQLite table's rows but store_meta's, in key order: a line per
/// row, and each value as its type and its bytes.
pub fn writeRows(database: *c.sqlite3, out: *std.Io.Writer) !void {
    inline for (store_schema.tables) |table| {
        if (comptime std.mem.eql(u8, table.name, "store_meta") or !table.engines.on(.sqlite)) continue;
        const order = comptime blk: {
            var text: []const u8 = "";
            for (table.primary_key, 0..) |column, position| text = text ++ (if (position == 0) "" else ",") ++ column;
            break :blk text;
        };
        const statement = try sqlite.prepare(database, "SELECT * FROM " ++ table.name ++ " ORDER BY " ++ order);
        defer _ = c.sqlite3_finalize(statement);
        try out.print("{s}\n", .{table.name});
        while (true) {
            switch (c.sqlite3_step(statement)) {
                c.SQLITE_DONE => break,
                c.SQLITE_ROW => {},
                else => return error.StatementFailed,
            }
            for (0..@intCast(c.sqlite3_column_count(statement))) |column| {
                const index: c_int = @intCast(column);
                switch (c.sqlite3_column_type(statement, index)) {
                    c.SQLITE_NULL => try out.writeAll(" null"),
                    c.SQLITE_INTEGER => try out.print(" {d}", .{c.sqlite3_column_int64(statement, index)}),
                    c.SQLITE_TEXT => {
                        const text = c.sqlite3_column_text(statement, index) orelse return error.OutOfMemory;
                        const length: usize = @intCast(c.sqlite3_column_bytes(statement, index));
                        try out.print(" t{d}:{s}", .{ length, text[0..length] });
                    },
                    c.SQLITE_BLOB => {
                        const length: usize = @intCast(c.sqlite3_column_bytes(statement, index));
                        const blob: [*]const u8 = if (length == 0) "" else @ptrCast(c.sqlite3_column_blob(statement, index).?);
                        try out.print(" x{d}:{x}", .{ length, blob[0..length] });
                    },
                    else => return error.UnexpectedColumnType,
                }
            }
            try out.writeByte('\n');
        }
    }
}

/// A fresh Store at `path` that then gets `expected_rows`, which must meet
/// its foreign keys, and opens once more.
pub fn freshStoreWithExpectedRows(path: []const u8, root: []const u8) !void {
    var storage: Store = undefined;
    try storage.open(std.testing.io, path, root);
    try storage.close();
    {
        const raw = try openRaw(path);
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw, "PRAGMA foreign_keys=OFF");
        // The rows hold the tool set the open saved, under their own ids.
        try sqlite.exec(raw, "DELETE FROM host_tool_set; DELETE FROM tool_set_member; DELETE FROM tool_set; DELETE FROM tool_record; DELETE FROM content");
        try sqlite.exec(raw, store_testing.expected_rows);
        const violations = try sqlite.prepare(raw, "PRAGMA foreign_key_check");
        defer _ = c.sqlite3_finalize(violations);
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(violations));
    }
    try storage.open(std.testing.io, path, root);
    try storage.close();
}

/// The testing tool set with an MCP server's tool beside it.
pub const mcp_record: tool_defs.Record = .{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a page from the docs server.", .input_schema = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"}}}" };
pub const mcp_records = hostToolRecordsWith(&.{ mcp_record, testing_record });
const mcp_digests = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: [mcp_records.len][32]u8 = undefined;
    for (&mcp_records, &out) |*each, *digest| digest.* = tool_defs.recordDigest(each);
    break :blk out;
};
pub const mcp_tool_set: tool_defs.HostToolSet = .{ .records = &mcp_records, .digests = &mcp_digests };

pub fn expectOnlyForwardsThenIdle(storage: *Store) !void {
    while (try storage.nextCoreWork()) |work| {
        try std.testing.expect(work == .forward);
        try std.testing.expect(try storage.deliverSessionForward(work.forward, .{}));
    }
}
