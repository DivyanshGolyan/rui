//! The Store's tests that observe a SQLite mechanism: VM steps, the
//! statement cache, engine passes, blob handles, PRAGMAs and the schema
//! catalog, or raw SQL the engine fixtures do not cover. tests.zig holds
//! the tests every engine runs; tests/ci/store_conformance.py split them.

const tests = @import("tests.zig");
const std = @import("std");
const named_scratch = @import("../named_scratch.zig");
const platform = @import("../platform.zig");
const protocol = @import("../protocol.zig");
const protocol_reply = @import("../protocol_reply.zig");
const model_capability = @import("../model_capability.zig");
const product_defaults = @import("../product_defaults.zig");
const tool_catalog = @import("../tools.zig");
const output_format = @import("../output_format.zig");
const output_decode = @import("../output_decode.zig");
const retry_policy = @import("../retry_policy.zig");
const change_ring = @import("../change_ring.zig");
const store_core = @import("Store.zig");
const store_access = @import("access.zig");
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
const BashExecutionInput = action_domain.BashExecutionInput;
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

/// A catalog with one tool beyond the built-ins, between them by name.
const testing_record: tool_catalog.Record = .{ .name = "test_tool", .owner = .rui, .description = "A tool only tests offer.", .input_schema = "{\"type\":\"object\"}" };
const testing_records = [_]tool_catalog.Record{ tool_catalog.bash_record, tool_catalog.message_agent_record, tool_catalog.start_agent_record, testing_record, tool_catalog.web_search_record };
const testing_digests = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: [testing_records.len][32]u8 = undefined;
    for (&testing_records, &out) |*each, *digest| digest.* = tool_catalog.recordDigest(each);
    break :blk out;
};
const testing_catalog: tool_catalog.Catalog = .{ .records = &testing_records, .digests = &testing_digests };

fn testingStoreCatalog(storage: *Store, tmp: *std.testing.TmpDir, io: std.Io, catalog: ?*const tool_catalog.Catalog) !void {
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    return storage.openWithOptions(io, database, root, .{ .catalog = catalog });
}

fn testingStore(storage: *Store, tmp: *std.testing.TmpDir, io: std.Io) !void {
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    return storage.open(io, database, root) catch |err| {
        std.debug.print("testing Store open failed: {s}\n", .{@errorName(err)});
        return err;
    };
}

test "Store open failures return typed errors without unwinding panics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    // A database path below a missing directory cannot be created; the open
    // must fail as a typed error rather than unwrapping a null handle.
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/missing-dir/store.sqlite3", .{root});
    var refused: Store = undefined;
    try std.testing.expectError(error.StoreOpenFailed, refused.open(std.testing.io, database, root));
}

fn createMaximumCanonicalStore(tmp: *std.testing.TmpDir, path_buffer: []u8) ![]const u8 {
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
fn busyStatements(database: *c.sqlite3) usize {
    var count: usize = 0;
    var statement = c.sqlite3_next_stmt(database, null);
    while (statement) |current| : (statement = c.sqlite3_next_stmt(database, current)) {
        if (c.sqlite3_stmt_busy(current) != 0) count += 1;
    }
    return count;
}

/// Imports `bytes` as public content in a transaction of its own, as
/// identities are taken only inside one.
fn importCommittedForTesting(storage: *Store, bytes: []const u8) !void {
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    var a: store_access.Access(.write, error{}) = .open(&entry);
    defer a.deinit();
    var value: content_domain.Import = .ofBytes(bytes, false);
    content_domain.lookup(&a, &value);
    try a.run();
    _ = try content_domain.importBytes(&a, &value, bytes);
    try a.commit();
}

/// Counts SQLite VM steps from `begin` to `end`. Preparing a statement also
/// steps, so measure a call only after the same call prepared its
/// statements.
const TestingSteps = struct {
    steps: u64 = 0,

    fn begin(self: *TestingSteps, database: *c.sqlite3) void {
        c.sqlite3_progress_handler(database, 1, progress, self);
    }

    fn end(_: *const TestingSteps, database: *c.sqlite3) void {
        c.sqlite3_progress_handler(database, 0, null, null);
    }

    fn progress(context: ?*anyopaque) callconv(.c) c_int {
        const self: *TestingSteps = @ptrCast(@alignCast(context.?));
        self.steps += 1;
        return 0;
    }
};

test "creating a Session takes the same work however many Sessions exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const Creation = struct {
        fn steps(store: *Store, key: []const u8) !u64 {
            var counter: TestingSteps = .{};
            counter.begin(store.sqliteDatabase());
            defer counter.end(store.sqliteDatabase());
            _ = try configureTestSession(store, key);
            return counter.steps;
        }
    };
    _ = try configureTestSession(&storage, "creation-steps-prepare");
    const few = try Creation.steps(&storage, "creation-steps-few");
    // Above the Host's next created_seq, which these rows bypass.
    try store_testing.sqlite_only.withoutForeignKeys(&storage, "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<2000) " ++
        "INSERT INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tool_set_id,permission_mode," ++
        "output_schema_content_id,revision,next_position,created_at,created_seq,workspace_digest,workspace_key) " ++
        "SELECT printf('%06d',value),'/','codex','openai-responses/1','model-a',1,1,0,NULL,1,1,1,value+1000000,zeroblob(32),value+1000000 FROM sequence", .{});
    // Changing foreign_keys expires prepared statements: prepare them again.
    _ = try configureTestSession(&storage, "creation-steps-prepare-again");
    try std.testing.expectEqual(few, try Creation.steps(&storage, "creation-steps-many"));
}

test "a Workspace's changed page reads only its own Sessions, however many others changed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var root: [protocol.max_store_bytes]u8 = undefined;
    const workspace = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    var nested = try tmp.dir.createDirPathOpen(std.testing.io, "other", .{});
    defer nested.close(std.testing.io);
    var other_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const other = other_buffer[0..try nested.realPath(std.testing.io, &other_buffer)];
    const Page = struct {
        fn configure(store: *Store, key: []const u8, session: []const u8, place: []const u8) !change_ring.Id {
            var command = try completeConfiguration(key, session, place, "model");
            const configured = store.configure(&command, .{});
            try std.testing.expect(configured == .accepted);
            return configured.accepted.session.slice()[0..protocol.session_id_bytes].*;
        }

        /// Steps for the page, which names only `watched`.
        fn steps(store: *Store, dir: *std.testing.TmpDir, request: protocol.ListSessions, watched: *const change_ring.Id) !u64 {
            _ = try TestingListing.read(store, dir, request);
            var counter: TestingSteps = .{};
            counter.begin(store.sqliteDatabase());
            defer counter.end(store.sqliteDatabase());
            const page = try TestingListing.read(store, dir, request);
            try std.testing.expectEqual(protocol.ListDelta.changed, page.delta);
            try page.expectReferences(&.{watched.*});
            try std.testing.expect(page.next == null);
            return counter.steps;
        }
    };
    const watched = try Page.configure(&storage, "scoped-watched", "", workspace);
    var request: protocol.ListSessions = .{ .workspace = .{}, .since = .{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) } };
    try request.workspace.?.set(workspace);
    _ = try Page.configure(&storage, "scoped-watched-again", &watched, workspace);
    const alone = try Page.steps(&storage, &tmp, request, &watched);
    // The rest of the ring: a distinct Session in another Workspace per
    // entry, each changed after the token.
    for (1..change_ring.capacity) |index| {
        var key: [32]u8 = undefined;
        _ = try Page.configure(&storage, try std.fmt.bufPrint(&key, "scoped-other-{d}", .{index}), "", other);
    }
    try std.testing.expect(storage.changes.covers(request.since.?.generation));
    try std.testing.expectEqual(alone, try Page.steps(&storage, &tmp, request, &watched));
}

/// Interrupts the one statement whose text is `sql` as it steps, the way an
/// I/O fault fails a read. No schema changes, so no cached plan expires.
const TestingStatementFault = struct {
    sql: [:0]const u8,
    running: bool = false,
    failed: u64 = 0,

    fn arm(self: *TestingStatementFault, database: *c.sqlite3) void {
        _ = c.sqlite3_trace_v2(database, c.SQLITE_TRACE_STMT, traced, self);
        c.sqlite3_progress_handler(database, 1, progress, self);
    }

    fn disarm(_: *const TestingStatementFault, database: *c.sqlite3) void {
        _ = c.sqlite3_trace_v2(database, 0, null, null);
        c.sqlite3_progress_handler(database, 0, null, null);
    }

    fn traced(_: c_uint, context: ?*anyopaque, statement: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self: *TestingStatementFault = @ptrCast(@alignCast(context.?));
        self.running = std.mem.eql(u8, std.mem.span(c.sqlite3_sql(@ptrCast(statement))), self.sql);
        return 0;
    }

    fn progress(context: ?*anyopaque) callconv(.c) c_int {
        const self: *TestingStatementFault = @ptrCast(@alignCast(context.?));
        if (!self.running) return 0;
        self.failed += 1;
        return 1;
    }
};

test "a statement that fails after an entry point touched its Session fails and fences it" {
    const Route = enum { configure, message };
    for (std.enums.values(Route)) |route| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "key-fault-config");
        // Each route faults a write that follows its touch: a configure
        // reads the Workspace key in its first round, before it touches
        // anything, and a Message reads its Session's head there too.
        var fault: TestingStatementFault = .{ .sql = switch (route) {
            .configure => configuration_domain.update_session_sql,
            .message => command_domain.admit_message_sql,
        } };
        switch (route) {
            .configure => {
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                var relabel = try completeConfiguration("key-fault-relabel", session.slice(), try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
                relabel.configuration.label.state = .value;
                try relabel.configuration.label.value.set("Relabelled");
                fault.arm(storage.sqliteDatabase());
                defer fault.disarm(storage.sqliteDatabase());
                try std.testing.expectEqual(std.meta.Tag(ConfigureReply).infrastructure_failure, std.meta.activeTag(storage.configure(&relabel, .{})));
            },
            .message => {
                const file = try tmp.dir.createFile(std.testing.io, "key-fault-message", .{ .read = true });
                try file.writeStreamingAll(std.testing.io, "work");
                try file.sync(std.testing.io);
                var command = try completeMessage("key-fault-message", session.slice(), file, "work");
                defer command.removeTemporaryContent(std.testing.io) catch unreachable;
                fault.arm(storage.sqliteDatabase());
                defer fault.disarm(storage.sqliteDatabase());
                try std.testing.expectEqual(std.meta.Tag(MessageReply).infrastructure_failure, std.meta.activeTag(storage.submitMessageWithModel(&command, null, .{})));
            },
        }
        try std.testing.expect(fault.failed > 0);
        try std.testing.expect(storage.isFenced());
        // Nothing of the failed command committed.
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM core_command WHERE command_key IN ('key-fault-relabel','key-fault-message')", .{}));
    }
}

/// Takes one value of every Identity in a transaction it rolls back,
/// checking that each is one past the largest committed value of a
/// column that has rows, and returns them.
fn takeEveryIdentityForTesting(storage: *Store) ![std.enums.values(store_core.Identity).len]u64 {
    const maxima = [_][:0]const u8{
        "SELECT max(turn_id) FROM turn",
        "SELECT max(operation_id) FROM model_operation",
        "SELECT max(action_id) FROM action_operation",
        "SELECT max(content_id) FROM content",
        "SELECT max(created_seq) FROM session",
        "SELECT max(command_seq) FROM core_command",
        "SELECT max(admission_id) FROM message_admission",
        "SELECT max(tool_record_id) FROM tool_record",
        "SELECT max(tool_set_id) FROM tool_set",
    };
    var taken: [maxima.len]u64 = undefined;
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    try store_core.begin(storage);
    inline for (comptime std.enums.values(store_core.Identity), maxima, &taken) |column, maximum, *value| {
        const committed = try store_testing.sqliteQueryU64(storage.sqliteDatabase(), maximum, .{});
        try std.testing.expect(committed > 0);
        value.* = try store_core.takeIdentity(storage, column);
        try std.testing.expectEqual(committed + 1, value.*);
    }
    try store_core.rollbackAfterError(storage, .{});
    return taken;
}

test "a rolled-back transaction's identities are handed out again, a committed one's never" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    // Entry points commit rows in every column.
    const first_session = try configureTestSessionAsk(&storage, "identity-config");
    try submitTestMessage(&storage, &tmp, "identity-message", "identity-message", first_session.slice(), "propose");
    try settleTwoActionsForTesting(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding, "identity-first");

    const rolled_back = try takeEveryIdentityForTesting(&storage);
    try std.testing.expectEqual(rolled_back, try takeEveryIdentityForTesting(&storage));

    // Committing the given-back values in every column: none is handed out
    // again. A Host offering one more tool saves its record at open.
    try storage.close();
    try testingStoreCatalog(&storage, &tmp, std.testing.io, &testing_catalog);
    const second_session = try configureTestSessionAsk(&storage, "identity-later");
    // New text, so content commits a new row too.
    try submitTestMessage(&storage, &tmp, "identity-later-message", "identity-later-message", second_session.slice(), "propose again");
    try settleTwoActionsForTesting(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding, "identity-second");
    // A new tool set commits.
    var tools: protocol.ConfigureCommand = .{};
    try tools.key.set("identity-later-tools");
    tools.session = second_session;
    tools.configuration.tools = try .of(&.{ "bash", "test_tool" });
    try std.testing.expect(storage.configure(&tools, .{}) == .accepted);
    const after = try takeEveryIdentityForTesting(&storage);
    for (rolled_back, after) |given_back, next| try std.testing.expect(next > given_back);
}

test "a round queues one statement any number of times, an engine pass before each rebinding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    var a: store_access.Access(.write, error{TestingGuard}) = .open(&entry);
    defer a.deinit();
    // Before engine passes the second queuing was StatementQueuedTwice.
    var digests: [9][32]u8 = undefined;
    var ids: [9]u64 = undefined;
    for (&digests, &ids, 0..) |*digest, *id, index| {
        digest.* = protocol.contentDigest(&.{@intCast(index)});
        id.* = try a.identity(.content_id);
        a.write(TestingRound.insert_content, .{ .content_id = id.*, .digest = digest.*, .length = index + 1 });
    }
    const before = storage.testing_content_work.rounds;
    try a.run();
    try std.testing.expectEqual(1, storage.testing_content_work.rounds - before);
    try std.testing.expectEqual(9, a.passes);
    // Each binding stepped before the next replaced it: nine rows, in order.
    for (ids, 0..) |id, index| {
        var lengths: [64]u8 = undefined;
        const sql = try std.fmt.bufPrintSentinel(&lengths, "SELECT byte_length FROM content WHERE content_id={d}", .{id}, 0);
        try std.testing.expectEqual(index + 1, try store_testing.sqliteQueryU64(storage.sqliteDatabase(), sql, .{}));
    }
    try a.abandon(.{});
}

test "a full queue takes an engine pass and the round still counts once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    var a: store_access.Access(.write, error{TestingGuard}) = .open(&entry);
    defer a.deinit();
    // Before engine passes the ninth entry was RoundFull.
    const digest = protocol.contentDigest("ninefold");
    const id = try a.identity(.content_id);
    a.write(TestingRound.insert_content, .{ .content_id = id, .digest = digest, .length = 8 });
    for (0..8) |index| a.writeContent(id, "ninefold"[index..][0..1]);
    const before = storage.testing_content_work.rounds;
    try a.run();
    try std.testing.expectEqual(1, storage.testing_content_work.rounds - before);
    try std.testing.expectEqual(2, a.passes);
    try a.abandon(.{});
}

test "a guard that fails in an engine pass fails the next run, and nothing after it steps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "pass-guard");
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    var a: store_access.Access(.write, error{TestingGuard}) = .open(&entry);
    defer a.deinit();
    var loaded: TestingRound.head.Result = undefined;
    a.read(TestingRound.head, .{ .session_ref = session.slice() }, &loaded);
    try a.run();
    const before = try store_testing.sqlite_only.queryU64(&storage, "SELECT created_at FROM session WHERE session_ref=?1", .{session.slice()});
    // Revision 99 matches no row, so the guard fails when the pass steps it.
    a.write(TestingRound.date_session, .{ .session = loaded.head, .revision = 99 });
    a.write(TestingRound.date_session, .{ .session = loaded.head, .revision = 1 });
    try std.testing.expectEqual(2, a.passes);
    try std.testing.expectError(error.TestingGuard, a.run());
    try std.testing.expectEqual(before, try store_testing.sqlite_only.queryU64(&storage, "SELECT created_at FROM session WHERE session_ref=?1", .{session.slice()}));
    try a.abandon(.{});
}

test "abandoning an Access that has ended runs nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    for ([_]bool{ false, true }) |committed| {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var a: store_access.Access(.write, error{}) = .open(&entry);
        defer a.deinit();
        const id = try a.identity(.content_id);
        const digest = protocol.contentDigest("ended");
        a.write(TestingRound.insert_content, .{ .content_id = id, .digest = digest, .length = 5 });
        if (committed) try a.commit() else {
            try a.run();
            try a.abandon(.{});
        }
        var statements: TestingStatements = .{};
        statements.begin(storage.sqliteDatabase());
        try a.abandon(.{});
        statements.end(storage.sqliteDatabase());
        try std.testing.expectEqual(@as(u64, 0), statements.count);
    }
    try std.testing.expect(!storage.isFenced());
}

test "the tables that carry Sessions are exactly the ones the touch oracle watches" {
    inline for (store_schema.tables) |table| {
        const watched = comptime for (sqlite.touch_oracle_tables) |watched_table| {
            if (std.mem.eql(u8, watched_table, table.name)) break true;
        } else false;
        try std.testing.expectEqual(watched, comptime store_schema.carriesSessions(table.name));
    }
}

test "a list row reads the same steps however long its Session's history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    // One Session, measured at two lengths of the same shape: answered
    // Turns, each followed by a queued Message a stop excluded, then a last
    // answered Turn. Alone in the Store, its index probes have the same
    // neighbours both times.
    const Round = struct {
        const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};

        fn run(store: *Store, dir: *std.testing.TmpDir, session: []const u8, comptime name: []const u8) !void {
            try answerTestTurn(store, dir, session, name ++ "-answer", &answer);
            try submitTestMessage(store, dir, name ++ "-queued-file", name ++ "-queued", session, "excluded");
            var stop = try completeSessionStop(name ++ "-stop", session);
            try std.testing.expect(store.stopSession(&stop, .{}) == .accepted);
        }
    };
    // The Session is the list's only row, so the page's steps are its row's.
    const Counter = struct {
        fn rowSteps(store: *Store, dir: *std.testing.TmpDir, session: []const u8) !u64 {
            var used = std.atomic.Value(u64).init(0);
            std.testing.allocator.free(try testingSessionList(store, dir, .{}, &used, 78));
            var counter: TestingSteps = .{};
            counter.begin(store.sqliteDatabase());
            const bytes = testingSessionList(store, dir, .{}, &used, 79);
            counter.end(store.sqliteDatabase());
            std.testing.allocator.free(try bytes);
            var listed = try testingListRow(store, dir, session);
            defer listed.deinit();
            try std.testing.expectEqualStrings("finished", listed.get(&.{ "work", "state", "kind" }).string);
            try std.testing.expect(listed.get(&.{"first_message"}) != .null);
            return counter.steps;
        }
    };
    const session = try configureTestSession(&storage, "row-steps");
    try Round.run(&storage, &tmp, session.slice(), "row-steps-0");
    try answerTestTurn(&storage, &tmp, session.slice(), "row-steps-short", &Round.answer);
    const short = try Counter.rowSteps(&storage, &tmp, session.slice());
    inline for (1..33) |round| try Round.run(&storage, &tmp, session.slice(), std.fmt.comptimePrint("row-steps-{d}", .{round}));
    try answerTestTurn(&storage, &tmp, session.slice(), "row-steps-long", &Round.answer);
    try std.testing.expect(short > 0);
    try std.testing.expectEqual(short, try Counter.rowSteps(&storage, &tmp, session.slice()));
}

/// The position of the person's Message next to `request`'s cursor, on a
/// one-row page of `admission` rows, or null.
fn personStep(storage: *Store, request: protocol.ActivityPage) !?u64 {
    const page = try store_core.activityPageForTesting(storage, request);
    if (page.count == 0) return null;
    try std.testing.expect(page.count == 1 and page.items[0].value == .admission);
    return page.items[0].position;
}

test "a person's Message next to a position is a one-row page of admission rows, at a fixed end" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "person-config");
    const peer = try configureTestSession(&storage, "person-peer");
    var request: protocol.ActivityPage = .{ .direction = .backward, .kinds = .initOne(.admission), .limit = 1 };
    try request.session.set(session.slice());
    try std.testing.expectEqual(@as(?u64, null), try personStep(&storage, request));
    for ([_][]const u8{ "one", "two", "three" }) |text| try submitTestMessage(&storage, &tmp, text, text, session.slice(), text);
    // Another Session sent the newest one: it is a received row, not the
    // person's, and every step passes over it.
    try submitTestMessage(&storage, &tmp, "from-peer", "from-peer", session.slice(), "peer");
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        try store_testing.sqlite_only.exec(&storage, "UPDATE message_admission SET sender_session_ref=?1,sender_position=1000000 WHERE command_key='from-peer'", .{peer.slice()});
        try touchForTesting(&storage, session.slice());
        try touchForTesting(&storage, peer.slice());
    }
    var positions: [3]u64 = undefined;
    inline for (0..3) |index| positions[index] = try store_testing.sqliteQueryU64(storage.sqliteDatabase(), std.fmt.comptimePrint("SELECT admission_position FROM message_admission WHERE sender_session_ref IS NULL ORDER BY admission_id LIMIT 1 OFFSET {d}", .{index}), .{});
    const page = try store_core.activityPageForTesting(&storage, request);
    try std.testing.expect(page.more);
    try std.testing.expectEqual(positions[2], page.items[0].position);
    try std.testing.expectEqual(protocol.contentDigest("three"), page.items[0].value.admission.content.digest);
    try std.testing.expectEqual(@as(u64, 5), page.items[0].value.admission.content.length);
    request.end = page.end;
    // Older from each one, then newer back: each step names its neighbour.
    for ([_]?u64{ positions[1], positions[0], null }, [_]u64{ positions[2], positions[1], positions[0] }) |expected, from| {
        request.position = from;
        try std.testing.expectEqual(expected, try personStep(&storage, request));
    }
    request.direction = .forward;
    try submitTestMessage(&storage, &tmp, "four", "four", session.slice(), "four");
    for ([_]?u64{ positions[1], positions[2], null }, positions) |expected, from| {
        request.position = from;
        try std.testing.expectEqual(expected, try personStep(&storage, request));
    }
    // A later Message waits beyond the end it was read at.
    request.end = null;
    request.position = positions[2];
    try std.testing.expect((try personStep(&storage, request)).? > positions[2]);
    // The peer's Message is the page's received row.
    var received: protocol.ActivityPage = .{ .direction = .backward, .kinds = .initOne(.received) };
    try received.session.set(session.slice());
    const peers = try store_core.activityPageForTesting(&storage, received);
    try std.testing.expect(peers.count == 1 and peers.items[0].value == .received);
    try std.testing.expectEqualStrings(peer.slice(), peers.items[0].value.received.sender.?.session.slice());
    // Both kinds read the one admission source, each row once, by its sender.
    received.kinds = .initMany(&.{ .admission, .received });
    const both = try store_core.activityPageForTesting(&storage, received);
    try std.testing.expect(both.count == 5 and !both.more);
    var counts: [2]usize = .{ 0, 0 };
    for (both.items[0..both.count]) |item| counts[@intFromBool(item.value == .received)] += 1;
    try std.testing.expectEqual([2]usize{ 4, 1 }, counts);
    // A cursor may name the received row; an admission page steps past it.
    received.kinds = .initOne(.admission);
    received.end = both.end;
    received.position = peers.items[0].position;
    received.ordinal = peers.items[0].ordinal;
    const before = try store_core.activityPageForTesting(&storage, received);
    try std.testing.expect(before.count > 0 and before.items[0].position < peers.items[0].position);
    try std.testing.expect(!storage.isFenced());
}

test "Current selects active then queued work and bounds recent Message identities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "selection-config");

    for (0..12) |index| {
        var file: [48]u8 = undefined;
        var key: [48]u8 = undefined;
        try submitTestMessage(&storage, &tmp, try std.fmt.bufPrint(&file, "selection-file-{d}", .{index}), try std.fmt.bufPrint(&key, "selection-message-{d}", .{index}), session.slice(), "input");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
    }
    try expectDenseSessionPositions(&storage, session.slice());
    {
        const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer report.deinit();
        try std.testing.expect(report.value.object.get("selected_message").? == .null);
        const recent = report.value.object.get("recent_messages").?.array.items;
        try std.testing.expectEqual(@as(usize, 10), recent.len);
        for (recent, 0..) |item, index| {
            var expected: [48]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "selection-message-{d}", .{11 - index}), item.object.get("message").?.string);
            try std.testing.expectEqualStrings("provider_http_422", item.object.get("outcome").?.string);
        }
    }
    try submitTestMessage(&storage, &tmp, "selection-next-file", "selection-next", session.slice(), "next");
    try std.testing.expectEqual(protocol.MessageProgressStatus.runnable, (try storage.observeCommand("selection-next")).message.?.progress.?.status);
    try std.testing.expect((try storage.observeCommand("selection-message-11")).message.?.progress == null);
    {
        const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer report.deinit();
        try std.testing.expectEqualStrings("selection-next", report.value.object.get("selected_message").?.string);
    }
    _ = (try storage.admitNextModelAttempt(.{})).?;
    try submitTestMessage(&storage, &tmp, "selection-queued-file", "selection-queued", session.slice(), "queued");
    const queued = (try storage.observeCommand("selection-queued")).message.?;
    try std.testing.expect(queued.queue.?.state == .queued);
    try std.testing.expectEqual(protocol.MessageProgressStatus.in_flight, queued.progress.?.status);
    try std.testing.expect(queued.progress.?.action_id == null);
    {
        const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer report.deinit();
        try std.testing.expectEqualStrings("selection-next", report.value.object.get("selected_message").?.string);
        try std.testing.expectEqualStrings("1", report.value.object.get("pending_messages").?.string);
    }
}

test "contradictory work inputs fence the Store" {
    for ([_][:0]const u8{
        // A failure code on an active Turn: its settlement closes the Turn.
        "UPDATE model_operation SET resolution_code='provider_http_500',retry_due_at_ms=NULL,attempt_at=NULL,resolved_at=1",
        // An Action beside an Operation still in flight.
        "INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,authorized,resolution_code) " ++
            "SELECT 999,operation_id,0,session_ref,1,1,0,NULL FROM model_operation",
        // A waiting retry without the failure that caused it.
        "UPDATE model_operation SET retry_due_at_ms=9223372036854775807,attempt_at=NULL,retry_scheduled_at=1,last_failure_code=NULL",
    }) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "contradiction-config");
        try submitTestMessage(&storage, &tmp, "contradiction-file", "contradiction-message", session.slice(), "x");
        _ = (try storage.admitNextModelAttempt(.{})).?;
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        try sqlite.exec(storage.sqliteDatabase(), fault);
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
        var request: protocol.ActivityPage = .{};
        try request.session.set(session.slice());
        try std.testing.expectError(error.CorruptStore, store_core.activityPageForTesting(&storage, request));
        try std.testing.expect(storage.isFenced());
    }
}

test "Action settlement atomically yields to an earlier Session stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const allocated_session_0 = try configureTestSessionAsk(&storage, "settlement-stop-config");
    try submitTestMessage(
        &storage,
        &tmp,
        "settlement-stop-message",
        "settlement-stop-message",
        allocated_session_0.slice(),
        "execute",
    );
    const model_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{.{
        .item_id = "settlement-stop-item",
        .name = "bash",
        .encoded_call_id = "settlement-stop-call",
        .decoded_call_id = "settlement-stop-call",
        .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
        .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
    }};
    try settleCallsForTesting(&storage, &tmp, model_binding, "settlement-stop-metadata", &calls);
    const action_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT action_id FROM action_operation", .{});
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
    try allow.key.set("settlement-stop-allow");
    try allow.session.set(allocated_session_0.slice());
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    const action_binding = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;

    var stop = try completeSessionStop("settlement-stop", allocated_session_0.slice());
    const pending_stop = storage.stopSession(&stop, .{});
    try std.testing.expect(pending_stop == .accepted);
    try std.testing.expectEqual(protocol.SessionStopCompletion.pending, pending_stop.accepted.completion);
    try std.testing.expectEqual(
        protocol.SessionStopCompletion.pending,
        (try storage.observeCommand("settlement-stop")).session_stop.?.completion,
    );
    try std.testing.expectEqual(
        ActionSettlement.session_stop,
        try storage.settleActionAttempt(action_binding, .succeeded, "Bash succeeded.", .{}),
    );
    try std.testing.expectEqual(
        protocol.SessionStopCompletion.completed,
        (try storage.observeCommand("settlement-stop")).session_stop.?.completion,
    );
    const completed_replay = storage.stopSession(&stop, .{});
    try std.testing.expect(completed_replay == .accepted);
    try std.testing.expect(completed_replay.accepted.replayed);
    try std.testing.expectEqual(protocol.SessionStopCompletion.completed, completed_replay.accepted.completion);

    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code='cancelled'", .{}));
    const result_content_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT resolution_content_id FROM action_operation", .{});
    const result_metadata = try testingContentReference(&storage, result_content_id);
    try expectContent(&storage, result_metadata, "Cancelled by Session stop.");
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM turn WHERE session_ref=?1 AND outcome_code='cancelled'", .{allocated_session_0.slice()}));
    try expectDenseSessionPositions(&storage, allocated_session_0.slice());
}

test "canonical report and Action read failures fence later commands" {
    var report_tmp = std.testing.tmpDir(.{});
    defer report_tmp.cleanup();
    var report_store: Store = undefined;
    try testingStore(&report_store, &report_tmp, std.testing.io);
    defer report_store.close() catch unreachable;
    const allocated_session_0 = try configureTestSession(&report_store, "report-corrupt-config");
    try sqlite.exec(report_store.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    try store_testing.sqlite_only.exec(&report_store, "UPDATE session SET instructions_content_id=9223372036854775807 WHERE session_ref=?1", .{allocated_session_0.slice()});
    try sqlite.exec(report_store.sqliteDatabase(), "PRAGMA foreign_keys=ON");
    var report_root: [protocol.max_store_bytes]u8 = undefined;
    const report_root_length = try report_tmp.dir.realPath(std.testing.io, &report_root);
    var report_used = std.atomic.Value(u64).init(0);
    try std.testing.expectError(error.CorruptStore, report_store.captureSessionReport(allocated_session_0.slice(), .{
        .scratch_path = report_root[0..report_root_length],
        .scratch_budget = .{ .used = &report_used, .limit = 1024 * 1024 },
        .request_number = 1,
        .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 },
    }));
    try std.testing.expect(report_store.isFenced());
    var blocked_denial: protocol.PermissionDecisionCommand = .{ .action_id = 1 };
    try blocked_denial.key.set("blocked-after-report-failure");
    try blocked_denial.session.set(allocated_session_0.slice());
    try std.testing.expectEqual(PermissionDecisionReply.infrastructure_failure, report_store.decidePermission(&blocked_denial, .{}));

    var action_tmp = std.testing.tmpDir(.{});
    defer action_tmp.cleanup();
    var action_store: Store = undefined;
    try testingStore(&action_store, &action_tmp, std.testing.io);
    defer action_store.close() catch unreachable;
    const allocated_session_1 = try configureTestSession(&action_store, "action-corrupt-config");
    try submitTestMessage(&action_store, &action_tmp, "action-corrupt-message", "action-corrupt-message", allocated_session_1.slice(), "propose");
    const binding = (try action_store.admitNextModelAttempt(.{})).?.permit.binding;
    try settleTwoActionsForTesting(&action_store, &action_tmp, binding, "action-corrupt-metadata");
    const action_id = try store_testing.sqlite_only.queryU64(&action_store, "SELECT min(action_id) FROM action_operation", .{});
    try store_testing.sqlite_only.withoutForeignKeys(&action_store, "DELETE FROM content WHERE content_id=(SELECT call_id_content_id FROM model_tool_call ORDER BY operation_id,call_ordinal LIMIT 1)", .{});
    try std.testing.expectError(error.CorruptStore, action_store.actionCallId(allocated_session_1.slice(), action_id));
    try std.testing.expect(action_store.isFenced());
    try std.testing.expectError(error.StoreFenced, action_store.actionArguments(allocated_session_1.slice(), action_id));

    // Existing public content is not necessarily a valid accepted descriptor.
    // A changed name must fence just like changed arguments, before dispatch.
    for ([_][:0]const u8{
        "UPDATE model_tool_call SET arguments_content_id=name_content_id",
        "UPDATE model_tool_call SET name_content_id=call_id_content_id",
        "UPDATE model_tool_call SET arguments_content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0",
    }) |damage| {
        for ([_]enum { report, arguments, execution }{ .report, .arguments, .execution }) |route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const allocated_session_2 = try configureTestSession(&storage, "descriptor-config");
            try submitTestMessage(&storage, &tmp, "descriptor-input", "descriptor-message", allocated_session_2.slice(), "propose");
            const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, source, "descriptor-metadata");
            try sqlite.exec(storage.sqliteDatabase(), damage);
            const result: anyerror!void = switch (route) {
                .report => if (testingSessionReport(&storage, &tmp, allocated_session_2.slice(), 1024 * 1024)) |bytes| blk: {
                    std.testing.allocator.free(bytes);
                    break :blk {};
                } else |err| err,
                .arguments => if (storage.actionArguments(allocated_session_2.slice(), try store_testing.sqlite_only.queryU64(&storage, "SELECT min(action_id) FROM action_operation", .{}))) |_| {} else |err| err,
                .execution => blk: {
                    const action = (try storage.admitNextActionAttempt(300_000, .{})).?;
                    var input: BashExecutionInput = undefined;
                    break :blk storage.readBashExecutionInput(action.permit.binding, &input);
                },
            };
            try std.testing.expectError(error.CorruptStore, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, storage.admitNextActionAttempt(300_000, .{}));
        }
    }
}

/// Every claimed Session position is used exactly once: the claims, from
/// every table that saves one, are exactly 1 through `next_position - 1`.
fn expectDenseSessionPositions(storage: *Store, session: []const u8) !void {
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
        "UNION ALL SELECT position FROM session_stop WHERE session_ref=?1), " ++
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

test "Core classifies trustworthy calls atomically without Action-shaped rejections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;

    const allocated_session_0 = try configureTestSessionAsk(&storage, "mixed-config");
    try submitTestMessage(&storage, &tmp, "mixed-message", "mixed-message", allocated_session_0.slice(), "classify");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run first command\\\",\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run first command\",\"cmd\":\"one\",\"timeout_ms\":null}" },
        .{ .item_id = "item-2", .name = "other", .encoded_call_id = "call-2", .decoded_call_id = "call-2", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "item-3", .name = "bash", .encoded_call_id = "call-3", .decoded_call_id = "call-3", .encoded_arguments = "{", .decoded_arguments = "{" },
        .{ .item_id = "item-4", .name = "bash", .encoded_call_id = "call-4", .decoded_call_id = "call-4", .encoded_arguments = "{\\\"command\\\":\\\"wrong\\\"}", .decoded_arguments = "{\"command\":\"wrong\"}" },
        .{ .item_id = "item-5", .name = "edit", .encoded_call_id = "call-5", .decoded_call_id = "call-5", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "item-6", .name = &@as([300]u8, @splat('x')), .encoded_call_id = "call-6", .decoded_call_id = "call-6", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "item-7", .name = "bash", .encoded_call_id = "call-7", .decoded_call_id = "call-7", .encoded_arguments = "{\\\"description\\\":\\\"Run seventh command\\\",\\\"cmd\\\":\\\"seven\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run seventh command\",\"cmd\":\"seven\",\"timeout_ms\":null}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "mixed-metadata", &calls);

    try std.testing.expectEqual(@as(u64, 7), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_tool_call", .{}));
    try std.testing.expectEqual(@as(u64, 5), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE rejection_code IS NOT NULL", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=4 AND rejection_code='unknown_tool'", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=5 AND rejection_code='unknown_tool'", .{}));
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation action JOIN model_tool_call tool_call ON tool_call.operation_id=action.parent_operation_id AND tool_call.call_ordinal=action.call_ordinal WHERE tool_call.rejection_code IS NOT NULL", .{}));
    try expectDenseSessionPositions(&storage, allocated_session_0.slice());
    {
        const rejected_action = try sqlite.prepare(storage.sqliteDatabase(), "INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,authorized,resolution_code) VALUES(999,?1,1,?2,1,1,0,NULL)");
        defer _ = c.sqlite3_finalize(rejected_action);
        try sqlite.bindU64(rejected_action, 1, binding.operation_id);
        try sqlite.bindText(rejected_action, 2, allocated_session_0.slice());
        try std.testing.expectError(error.StatementFailed, sqlite.expectDone(rejected_action));
    }
    var observation = try storage.inspectSessionForTesting(allocated_session_0.slice());
    try std.testing.expectEqual(@as(u64, 2), observation.action_count);
    try std.testing.expectEqual(@as(u64, 5), observation.rejected_call_count);
    const first_action_id = first: {
        const report_bytes = try testingSessionReportWithProfile(&storage, &tmp, allocated_session_0.slice(), 1024 * 1024, .full);
        defer std.testing.allocator.free(report_bytes);
        const report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, report_bytes, .{ .ignore_unknown_fields = true });
        defer report.deinit();
        try std.testing.expectEqual(@as(usize, 2), report.value.actions.unresolved.len);
        try std.testing.expectEqualStrings("0", report.value.actions.unresolved[0].call_ordinal);
        try std.testing.expectEqualStrings("6", report.value.actions.unresolved[1].call_ordinal);
        try std.testing.expectEqual(@as(usize, 5), report.value.rejected_calls.items.len);
        const rejected = report.value.rejected_calls.items[0];
        try std.testing.expectEqualStrings("1", rejected.call_ordinal);
        try std.testing.expectEqualStrings("unknown_tool", rejected.code);
        try std.testing.expect((try std.fmt.parseInt(u64, rejected.acceptance_position, 10)) > 0);
        try std.testing.expectEqualStrings("20", rejected.result.bytes);
        try std.testing.expectEqualStrings(
            &std.fmt.bytesToHex(protocol.contentDigest("Unknown tool: other."), .lower),
            rejected.result.sha256,
        );
        inline for (.{
            .{ rejected.name, "other" },
            .{ rejected.call_id, "call-2" },
            .{ rejected.arguments, "{}" },
        }) |expected| {
            var length_buffer: [20]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&length_buffer, "{d}", .{expected[1].len}), expected[0].bytes);
            const digest = protocol.contentDigest(expected[1]);
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), expected[0].sha256);
        }
        var full = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report_bytes, .{});
        defer full.deinit();
        const rejected_rows = full.value.object.get("rejected_calls").?.object.get("items").?.array.items;
        for (rejected_rows) |row| {
            const p = row.object.get("presentation").?.object;
            try std.testing.expect(p.get("description").? == .null);
            try std.testing.expect(p.get("publication_position").? == .null);
            try std.testing.expectEqualStrings(row.object.get("code").?.string, p.get("code").?.string);
        }
        const full_rejected = full.value.object.get("full").?.object.get("tool_calls").?.array.items[1].object;
        try std.testing.expectEqualStrings("other", full_rejected.get("name").?.object.get("text").?.string);
        try std.testing.expectEqualStrings("{}", full_rejected.get("arguments").?.object.get("text").?.string);
        try std.testing.expectEqualStrings("Unknown tool: other.", full_rejected.get("rejection_result").?.object.get("text").?.string);
        break :first try std.fmt.parseInt(u64, report.value.actions.unresolved[0].action, 10);
    };
    {
        const content_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT rejection_content_id FROM model_tool_call WHERE call_ordinal=5", .{});
        const metadata = try testingContentReference(&storage, content_id);
        var reader: ContentReader = undefined;
        reader.open(try storage.openContent(metadata));
        defer reader.close();
        var result: [192]u8 = undefined;
        const count = try reader.read(0, &result);
        try std.testing.expect(std.mem.startsWith(u8, result[0..count], "Unknown tool: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx…"));
        try std.testing.expect(std.mem.indexOf(u8, result[0..count], "name continues; Rui content digest") != null);
    }
    var deny: protocol.PermissionDecisionCommand = .{ .action_id = first_action_id };
    try deny.key.set("mixed-deny");
    try deny.session.set(allocated_session_0.slice());
    try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
    observation = try storage.inspectSessionForTesting(allocated_session_0.slice());
    try std.testing.expectEqual(@as(u64, 5), observation.rejected_call_count);
    {
        const report_bytes = try testingSessionReport(&storage, &tmp, allocated_session_0.slice(), 1024 * 1024);
        defer std.testing.allocator.free(report_bytes);
        const report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, report_bytes, .{ .ignore_unknown_fields = true });
        defer report.deinit();
        try std.testing.expectEqual(@as(usize, 1), report.value.actions.unresolved.len);
        try std.testing.expectEqualStrings("6", report.value.actions.unresolved[0].call_ordinal);
        try std.testing.expectEqual(@as(usize, 1), report.value.actions.resolved.len);
        const resolved = report.value.actions.resolved[0];
        try std.testing.expectEqualStrings("0", resolved.call_ordinal);
        try std.testing.expectEqualStrings("denied", resolved.code);
        try std.testing.expect((try std.fmt.parseInt(u64, resolved.acceptance_position, 10)) > 0);
        try std.testing.expectEqualStrings("18", resolved.result.bytes);
        try std.testing.expectEqualStrings(
            &std.fmt.bytesToHex(protocol.contentDigest("Permission denied."), .lower),
            resolved.result.sha256,
        );
    }

    try storage.close();
    storage_open = false;
    var root: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root);
    var database: [platform.max_database_path_bytes]u8 = undefined;
    var reopened: Store = undefined;
    try reopened.open(
        std.testing.io,
        try std.fmt.bufPrint(&database, "{s}/store.sqlite3", .{root[0..root_length]}),
        root[0..root_length],
    );
    defer reopened.close() catch unreachable;
    const recovered = try reopened.inspectSessionForTesting(allocated_session_0.slice());
    try std.testing.expectEqual(@as(u64, 2), recovered.action_count);
    try std.testing.expectEqual(@as(u64, 5), recovered.rejected_call_count);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&reopened, "SELECT count(*) FROM action_operation WHERE action_id=(SELECT min(action_id) FROM action_operation) " ++
        "AND parent_operation_id=(SELECT min(parent_operation_id) FROM action_operation) " ++
        "AND call_ordinal=0 AND resolution_code='denied'", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&reopened, "SELECT count(*) FROM permission_decision_command WHERE command_key='mixed-deny' " ++
        "AND action_id=CAST((SELECT min(action_id) FROM action_operation) AS TEXT)", .{}));
    try expectContent(&reopened, try reopened.actionCallId(allocated_session_0.slice(), first_action_id), "call-1");
    try expectContent(&reopened, try reopened.actionArguments(allocated_session_0.slice(), first_action_id), "{\"description\":\"Run first command\",\"cmd\":\"one\",\"timeout_ms\":null}");
    const recovered_bytes = try testingSessionReport(&reopened, &tmp, allocated_session_0.slice(), 1024 * 1024);
    defer std.testing.allocator.free(recovered_bytes);
    const recovered_report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, recovered_bytes, .{ .ignore_unknown_fields = true });
    defer recovered_report.deinit();
    try std.testing.expectEqual(@as(usize, 1), recovered_report.value.actions.unresolved.len);
    try std.testing.expectEqualStrings("6", recovered_report.value.actions.unresolved[0].call_ordinal);
    try std.testing.expectEqual(@as(usize, 5), recovered_report.value.rejected_calls.items.len);
}

const ConstraintProbe = enum { accepted, check_violation, other_failure };

/// Runs one write inside a rolled-back savepoint and reports whether SQLite
/// accepted it or rejected it on a CHECK rather than another constraint.
fn probeConstraint(database: *c.sqlite3, sql: [:0]const u8) !ConstraintProbe {
    try sqlite.exec(database, "SAVEPOINT constraint_probe");
    defer sqlite.exec(database, "ROLLBACK TO constraint_probe; RELEASE constraint_probe") catch unreachable;
    const statement = try sqlite.prepare(database, sql);
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) == c.SQLITE_DONE) return .accepted;
    return if (c.sqlite3_extended_errcode(database) == c.SQLITE_CONSTRAINT_CHECK) .check_violation else .other_failure;
}

test "a fresh Store creates a Session with instructions, an output schema and the default tools" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var command = try completeConfiguration("fresh-tool-texts", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
    command.configuration.instructions = try testingBytesContent(&tmp, "fresh-instructions", "Be brief.");
    command.configuration.output_schema = try testingBytesContent(&tmp, "fresh-schema", "{\"type\":\"object\"}");
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;
    // The Store saved the catalog's seven texts when it opened: two each
    // for Bash, message_agent and start_agent, and web search's empty one.
    // The configure adds its two values.
    try std.testing.expectEqual(@as(u64, 7), try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
    try std.testing.expect(storage.configure(&command, .{}) == .accepted);
    try std.testing.expectEqual(@as(u64, 9), try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
}

test "a Session's tools are saved once and read back as saved, not as today's built-ins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const Tools = struct {
        fn set(store: *Store, key: []const u8, session: protocol.Bounded(protocol.max_session_bytes), offered: []const []const u8) !void {
            var command: protocol.ConfigureCommand = .{};
            try command.key.set(key);
            command.session = session;
            command.configuration.tools = try .of(offered);
            try std.testing.expect(store.configure(&command, .{}) == .accepted);
        }
        fn counts(store: *Store) ![3]u64 {
            return .{
                try store_testing.queryU64(store, "SELECT count(*) FROM tool_set", .{}),
                try store_testing.queryU64(store, "SELECT count(*) FROM tool_record", .{}),
                try store_testing.queryU64(store, "SELECT count(*) FROM tool_set_member", .{}),
            };
        }
    };
    // The Host's catalog: one set of the four built-ins, saved at open.
    try std.testing.expectEqual([3]u64{ 1, 4, 4 }, try Tools.counts(&storage));
    // Two Sessions offering Bash share one set, of the catalog's record.
    const first = try configureTestSessionAsk(&storage, "saved-tools-first");
    const second = try configureTestSessionAsk(&storage, "saved-tools-second");
    try std.testing.expectEqual([3]u64{ 2, 4, 5 }, try Tools.counts(&storage));
    // A set with the catalog's members is the catalog's set.
    try Tools.set(&storage, "saved-tools-all", first, &.{ "bash", "message_agent", "start_agent", "web_search" });
    try std.testing.expectEqual([3]u64{ 2, 4, 5 }, try Tools.counts(&storage));
    try Tools.set(&storage, "saved-tools-both", second, &.{ "bash", "web_search" });
    try std.testing.expectEqual([3]u64{ 3, 4, 7 }, try Tools.counts(&storage));
    try Tools.set(&storage, "saved-tools-none", first, &.{});
    try std.testing.expectEqual([3]u64{ 4, 4, 7 }, try Tools.counts(&storage));
    // Each revision keeps the set it was saved with.
    try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(DISTINCT tool_set_id) FROM session_revision WHERE revision IN (1,2) AND " ++
        "session_ref=(SELECT session_ref FROM session_revision WHERE command_key='saved-tools-both')", .{}));

    // A reworded built-in changes no saved set: the saved text is what an
    // Operation offers.
    const reworded = "Reworded description.";
    try submitTestMessage(&storage, &tmp, "saved-tools-message", "saved-tools-message", second.slice(), reworded);
    try sqlite.exec(storage.sqliteDatabase(), "UPDATE tool_record SET description_content_id=(SELECT content_id FROM content WHERE CAST(payload AS TEXT)='Reworded description.') WHERE name='bash'");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var view: HistoricalView = undefined;
    try storage.openHistoricalView(binding, &view);
    defer view.close();
    var settings: HistoricalSettings = undefined;
    try view.settings(&settings);
    try std.testing.expectEqual(@as(u64, 2), settings.tool_count);
    var tool: historical_domain.HistoricalTool = .{};
    try std.testing.expect(try view.nextTool(&tool));
    try std.testing.expectEqualStrings("bash", tool.name.slice());
    try std.testing.expectEqual(tool_catalog.Owner.rui, tool.owner);
    try std.testing.expectEqual(protocol.contentDigest(reworded), tool.description.digest);
    try std.testing.expectEqual(protocol.contentDigest(tool_catalog.bash_record.input_schema), tool.input_schema.digest);
    try std.testing.expect(try view.nextTool(&tool));
    try std.testing.expectEqualStrings("web_search", tool.name.slice());
    try std.testing.expectEqual(tool_catalog.Owner.provider, tool.owner);
    try std.testing.expect(!try view.nextTool(&tool));
}

test "a Bash call the Operation did not offer is rejected and keeps its description" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("unoffered-config", "", workspace, "model-a");
    command.configuration.tools.state = .value;
    command.configuration.tools.count = 0;
    const reply = storage.configure(&command, .{});
    try std.testing.expect(reply == .accepted);
    const session = reply.accepted.session;
    try submitTestMessage(&storage, &tmp, "unoffered-message", "unoffered-message", session.slice(), "classify");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"one\\\"}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"one\"}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "unoffered-metadata", &calls);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=0 AND rejection_code='unknown_tool' AND description='Run'", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation", .{}));
}

test "lifecycle CHECKs reject null-valued invalid combinations on the CHECK itself" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSessionAsk(&storage, "check-config");
    try submitTestMessage(&storage, &tmp, "check-message", "check-message", session.slice(), "classify");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"one\",\"timeout_ms\":null}" },
        .{ .item_id = "item-2", .name = "other", .encoded_call_id = "call-2", .decoded_call_id = "call-2", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "check-metadata", &calls);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE call_ordinal=0 AND resolution_code IS NULL AND attempt_ordinal=0", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=1 AND rejection_code='unknown_tool'", .{}));

    // Each pair changes only one field, the null-valued one where a NULL could
    // pass the CHECK. The valid witness shows the row satisfies every
    // unrelated constraint, so the invalid write can only fail on the
    // lifecycle CHECK.
    const Case = struct { valid: [:0]const u8, invalid: [:0]const u8 };
    const cases = [_]Case{
        // An unresolved Operation needs a retry time; zero marks it uncertain.
        .{
            .valid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=0,attempt_at=1,resolved_at=NULL",
            .invalid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=NULL,attempt_at=1,resolved_at=NULL",
        },
        // Interruption linkage requires the interrupted Resolution.
        .{
            .valid = "UPDATE model_operation SET resolution_code='interrupted',retry_due_at_ms=NULL,interrupted_by_command_key=(SELECT min(command_key) FROM core_command)",
            .invalid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=0,interrupted_by_command_key=(SELECT min(command_key) FROM core_command)",
        },
        // A call without rejection fields must be an Action call.
        .{
            .valid = "UPDATE model_tool_call SET rejection_code=NULL,rejection_content_id=NULL,acceptance_position=NULL,action_kind=1 WHERE call_ordinal=1",
            .invalid = "UPDATE model_tool_call SET rejection_code=NULL,rejection_content_id=NULL,acceptance_position=NULL,action_kind=NULL WHERE call_ordinal=1",
        },
        // A denied Action never started an Attempt.
        .{
            .valid = "UPDATE action_operation SET attempt_ordinal=1,attempt_at=1,bash_timeout_ms=1,resolution_code='failed'," ++
                "resolution_content_id=(SELECT min(content_id) FROM content),acceptance_position=1,resolved_at=1 WHERE call_ordinal=0",
            .invalid = "UPDATE action_operation SET attempt_ordinal=1,attempt_at=1,bash_timeout_ms=1,resolution_code='denied'," ++
                "resolution_content_id=(SELECT min(content_id) FROM content),acceptance_position=1,resolved_at=1 WHERE call_ordinal=0",
        },
        // An authorized Action is never denied.
        .{
            .valid = "UPDATE action_operation SET authorized=1,decided_at=1,resolution_code='failed'," ++
                "resolution_content_id=(SELECT min(content_id) FROM content),acceptance_position=1,resolved_at=1 WHERE call_ordinal=0",
            .invalid = "UPDATE action_operation SET authorized=1,decided_at=1,resolution_code='denied'," ++
                "resolution_content_id=(SELECT min(content_id) FROM content),acceptance_position=1,resolved_at=1 WHERE call_ordinal=0",
        },
    };
    var outcomes: [cases.len]ConstraintProbe = undefined;
    for (cases, &outcomes) |case, *outcome| {
        try std.testing.expectEqual(ConstraintProbe.accepted, try probeConstraint(storage.sqliteDatabase(), case.valid));
        outcome.* = try probeConstraint(storage.sqliteDatabase(), case.invalid);
    }
    try std.testing.expectEqual(@as([cases.len]ConstraintProbe, @splat(.check_violation)), outcomes);
}

test "closed value columns accept exactly their values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSessionAsk(&storage, "values-config");
    try submitTestMessage(&storage, &tmp, "values-message", "values-message", session.slice(), "classify");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"one\",\"timeout_ms\":null}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "values-metadata", &calls);

    const efforts = [_][]const u8{ "NULL", "'none'", "'low'", "'medium'", "'high'", "'xhigh'", "'max'" };
    const not_efforts = [_][]const u8{ "'minimal'", "'Medium'", "''" };
    const Column = struct { update: []const u8, accepted: []const []const u8, rejected: []const []const u8 };
    const columns = [_]Column{
        .{ .update = "UPDATE core_command SET kind={s}", .accepted = &.{ "1", "2", "3", "4", "5" }, .rejected = &.{ "0", "6" } },
        .{ .update = "UPDATE model_output_item SET item_kind=v.k,message_content_id=CASE WHEN v.k=2 THEN extras_content_id END FROM (SELECT {s} AS k) v", .accepted = &.{ "1", "2", "3", "4", "5" }, .rejected = &.{ "0", "6" } },
        .{
            .update = "UPDATE conversation_entry SET entry_kind=v.k,source_admission_id=CASE WHEN v.k=1 THEN source_admission_id END," ++
                "source_revision=CASE WHEN v.k=2 THEN 1 END,source_operation_id=CASE WHEN v.k=3 THEN (SELECT min(operation_id) FROM model_output_item) END," ++
                "source_item_ordinal=CASE WHEN v.k=3 THEN 0 END FROM (SELECT {s} AS k) v WHERE entry_kind=1",
            .accepted = &.{ "1", "2", "3" },
            .rejected = &.{ "0", "4" },
        },
        .{ .update = "UPDATE session SET reasoning_effort={s}", .accepted = &efforts, .rejected = &not_efforts },
        .{ .update = "UPDATE session_revision SET reasoning_effort={s}", .accepted = &efforts, .rejected = &not_efforts },
        .{ .update = "UPDATE model_operation SET reasoning_effort={s}", .accepted = &efforts, .rejected = &not_efforts },
        .{
            .update = "UPDATE action_operation SET resolution_code={s},resolution_content_id=(SELECT min(content_id) FROM content)," ++
                "acceptance_position=1,resolved_at=1 WHERE call_ordinal=0",
            .accepted = &.{ "'denied'", "'cancelled'", "'succeeded'", "'failed'", "'timed_out'", "'indeterminate'", "'storage_failed'", "'spawn_failed'", "'infrastructure_shutdown'" },
            .rejected = &.{ "'interrupted'", "'Failed'", "''" },
        },
    };
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM conversation_entry WHERE entry_kind=1", .{}));
    var sql: [512]u8 = undefined;
    inline for (columns) |column| {
        for (column.accepted) |value|
            try std.testing.expectEqual(ConstraintProbe.accepted, try probeConstraint(storage.sqliteDatabase(), try std.mem.printSentinel(&sql, column.update, .{value}, 0)));
        for (column.rejected) |value|
            try std.testing.expectEqual(ConstraintProbe.check_violation, try probeConstraint(storage.sqliteDatabase(), try std.mem.printSentinel(&sql, column.update, .{value}, 0)));
    }
}

test "claiming Session positions stops at the largest position, and fails when its write does not land" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSessionAsk(&storage, "claim-config");
    const last: u64 = std.math.maxInt(i64);
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET next_position=9223372036854775805 WHERE session_ref=?1", .{session.slice()});
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var a: store_access.Access(.write, error{}) = .open(&entry);
        defer a.deinit();
        var loaded: TestingRound.head.Result = undefined;
        a.read(TestingRound.head, .{ .session_ref = session.slice() }, &loaded);
        try a.run();
        const positions = try a.positions(loaded.head);
        try std.testing.expectEqual(last - 2, try positions.take(2));
        try std.testing.expectError(error.SessionPositionExhausted, positions.take(1));
        try std.testing.expectEqual(last, try positions.take(0));
        try std.testing.expectError(error.SessionPositionExhausted, positions.take(last + 1));
        try a.commit();
    }
    try std.testing.expectEqual(last, try store_testing.sqlite_only.queryU64(&storage, "SELECT next_position FROM session", .{}));

    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET next_position=1 WHERE session_ref=?1", .{session.slice()});
    try sqlite.exec(storage.sqliteDatabase(), "CREATE TEMP TRIGGER skip_claim BEFORE UPDATE OF next_position ON main.session BEGIN SELECT RAISE(IGNORE); END");
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var a: store_access.Access(.write, error{}) = .open(&entry);
        defer a.deinit();
        var loaded: TestingRound.head.Result = undefined;
        a.read(TestingRound.head, .{ .session_ref = session.slice() }, &loaded);
        try a.run();
        _ = try (try a.positions(loaded.head)).take(1);
        try std.testing.expectError(error.CorruptStore, a.commit());
        try a.abandon(.{});
    }
}

test "each state-bearing row keeps exactly the time its state owns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSessionAsk(&storage, "time-config");
    try submitTestMessage(&storage, &tmp, "time-message", "time-message", session.slice(), "classify");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"one\",\"timeout_ms\":null}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "time-metadata", &calls);

    // Each pair moves one row to a state. The valid write sets exactly that
    // state's time; the invalid one forgets it or keeps the old state's time.
    const Case = struct { valid: [:0]const u8, invalid: [:0]const u8 };
    const cases = [_]Case{
        .{
            .valid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=0,attempt_at=1,resolved_at=NULL",
            .invalid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=0,attempt_at=1",
        },
        .{
            .valid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=0,attempt_at=1,resolved_at=NULL",
            .invalid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=0,resolved_at=NULL",
        },
        .{
            .valid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=5,retry_scheduled_at=1,resolved_at=NULL",
            .invalid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=5,retry_scheduled_at=1,attempt_at=1,resolved_at=NULL",
        },
        .{
            .valid = "UPDATE model_operation SET resolved_at=2",
            .invalid = "UPDATE model_operation SET resolved_at=NULL",
        },
        .{
            .valid = "UPDATE turn SET outcome_code='cancelled',outcome_position=99,outcome_at=1",
            .invalid = "UPDATE turn SET outcome_code='cancelled',outcome_position=99",
        },
        .{
            .valid = "UPDATE action_operation SET attempt_ordinal=1,attempt_at=1,bash_timeout_ms=1",
            .invalid = "UPDATE action_operation SET attempt_ordinal=1,bash_timeout_ms=1",
        },
        .{
            .valid = "UPDATE action_operation SET authorized=1,decided_at=1",
            .invalid = "UPDATE action_operation SET authorized=1",
        },
        .{
            .valid = "UPDATE action_operation SET resolution_code='failed',resolution_content_id=(SELECT min(content_id) FROM content),acceptance_position=1,resolved_at=1",
            .invalid = "UPDATE action_operation SET resolution_code='failed',resolution_content_id=(SELECT min(content_id) FROM content),acceptance_position=1",
        },
        .{
            .valid = "UPDATE conversation_entry SET recorded_at=1",
            .invalid = "UPDATE conversation_entry SET recorded_at=0",
        },
    };
    var outcomes: [cases.len]ConstraintProbe = undefined;
    for (cases, &outcomes) |case, *outcome| {
        try std.testing.expectEqual(ConstraintProbe.accepted, try probeConstraint(storage.sqliteDatabase(), case.valid));
        outcome.* = try probeConstraint(storage.sqliteDatabase(), case.invalid);
    }
    try std.testing.expectEqual(@as([cases.len]ConstraintProbe, @splat(.check_violation)), outcomes);
}

test "a stale Action settlement leaves the Store byte-identical" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "stale-config");
    try submitTestMessage(&storage, &tmp, "stale-message", "stale-message", session.slice(), "propose");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleTwoActionsForTesting(&storage, &tmp, binding, "stale-metadata");
    for ([_][]const u8{ "stale-allow-first", "stale-allow-second" }, [_][]const u8{ "min", "max" }) |key, end| {
        var sql: [64]u8 = undefined;
        var allow: protocol.PermissionDecisionCommand = .{ .action_id = try store_testing.sqliteQueryU64(storage.sqliteDatabase(), try std.fmt.bufPrintSentinel(&sql, "SELECT {s}(action_id) FROM action_operation", .{end}, 0), .{}), .decision = .allow_once };
        try allow.key.set(key);
        try allow.session.set(session.slice());
        try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    }
    const settled = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
    const open = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
    try std.testing.expectEqual(ActionSettlement.effect, try storage.settleActionAttempt(settled, .succeeded, "Bash succeeded.", .{}));

    const Snapshot = struct {
        database: []u8,
        log: []u8,
        ids: @TypeOf(storage.ids.next),
        generation: u64,

        fn take(store: *Store, dir: std.Io.Dir) !@This() {
            return .{
                .database = try dir.readFileAlloc(std.testing.io, "store.sqlite3", std.testing.allocator, .unlimited),
                .log = try dir.readFileAlloc(std.testing.io, "store.sqlite3-wal", std.testing.allocator, .unlimited),
                .ids = store.ids.next,
                .generation = store.commitGeneration(),
            };
        }

        fn deinit(self: @This()) void {
            std.testing.allocator.free(self.database);
            std.testing.allocator.free(self.log);
        }
    };
    const before = try Snapshot.take(&storage, tmp.dir);
    defer before.deinit();
    // Already settled, and a binding whose Turn is not the Action's.
    const wrong_turn: ActionAttemptBinding = .{ .turn_id = open.turn_id + 1, .parent_operation_id = open.parent_operation_id, .action_id = open.action_id };
    for ([_]ActionAttemptBinding{ settled, wrong_turn }) |stale| {
        try std.testing.expectError(error.StaleActionAttemptBinding, storage.settleActionAttempt(stale, .failed, "A stale result is never stored.", .{}));
    }
    try std.testing.expect(!storage.isFenced());
    const after = try Snapshot.take(&storage, tmp.dir);
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, before.database, after.database);
    try std.testing.expectEqualSlices(u8, before.log, after.log);
    try std.testing.expectEqual(before.ids, after.ids);
    try std.testing.expectEqual(before.generation, after.generation);

    // Round 1 finds `open` current; before the write round runs, the
    // Action stops being attempted, so the resolve guard fails after the
    // result's content row and position were queued.
    const Interposed = struct {
        const Inner = store_access.Access(.write, error{StaleActionAttemptBinding});
        inner: *Inner,
        action_id: u64,

        pub fn read(self: *@This(), comptime S: type, args: S.Args, destination: *S.Result) void {
            self.inner.read(S, args, destination);
        }
        pub fn run(self: *@This()) Inner.Error!void {
            return self.inner.run();
        }
        pub fn positions(self: *@This(), head: rsql.SessionHead) !*store_access.Positions {
            return self.inner.positions(head);
        }
        pub fn write(self: *@This(), comptime S: type, args: S.Args) void {
            self.inner.write(S, args);
        }
        pub fn identity(self: *@This(), comptime column: store_core.Identity) !u64 {
            return self.inner.identity(column);
        }
        pub fn writeContent(self: *@This(), content_id: u64, bytes: []const u8) void {
            self.inner.writeContent(content_id, bytes);
        }
        pub fn insertedContent(self: *const @This(), digest: *const [32]u8, length: u64, private: bool) ?u64 {
            return self.inner.insertedContent(digest, length, private);
        }
        pub fn recordInserted(self: *@This(), digest: *const [32]u8, length: u64, private: bool, content_id: u64) void {
            self.inner.recordInserted(digest, length, private, content_id);
        }
        pub fn commit(self: *@This()) Inner.Error!void {
            var sql: [160]u8 = undefined;
            const unattempt = std.fmt.bufPrintSentinel(&sql, "UPDATE action_operation SET attempt_ordinal=0,bash_timeout_ms=NULL,attempt_at=NULL,sender_handle=NULL WHERE action_id={d}", .{self.action_id}, 0) catch unreachable;
            sqlite.exec(self.inner.store.sqliteDatabase(), unattempt) catch unreachable;
            return self.inner.commit();
        }
    };
    const guarded = try Snapshot.take(&storage, tmp.dir);
    defer guarded.deinit();
    const unclaimed = try store_testing.sqlite_only.queryU64(&storage, "SELECT next_position FROM session", .{});
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var access: Interposed.Inner = .open(&entry);
        defer access.deinit();
        var interposed: Interposed = .{ .inner = &access, .action_id = open.action_id };
        try std.testing.expectError(error.StaleActionAttemptBinding, entry.finishTransaction(error{StaleActionAttemptBinding}, .{}, access.end(.{}, action_domain.settleActionAttempt(&interposed, open, .failed, "A result the guard refuses.", .{}))));
    }
    try std.testing.expect(!storage.isFenced());
    const refused = try Snapshot.take(&storage, tmp.dir);
    defer refused.deinit();
    try std.testing.expectEqualSlices(u8, guarded.database, refused.database);
    try std.testing.expectEqualSlices(u8, guarded.log, refused.log);
    try std.testing.expectEqual(guarded.ids, refused.ids);
    try std.testing.expectEqual(unclaimed, try store_testing.sqlite_only.queryU64(&storage, "SELECT next_position FROM session", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM content WHERE CAST(payload AS TEXT)='A result the guard refuses.'", .{}));

    // The open Action still settles at the position and content id the stale ones left.
    const position = try store_testing.sqlite_only.queryU64(&storage, "SELECT next_position FROM session", .{});
    const content_id = storage.ids.next.get(.content_id);
    try std.testing.expectEqual(ActionSettlement.effect, try storage.settleActionAttempt(open, .failed, "A later result is stored.", .{}));
    try std.testing.expectEqual(position, try store_testing.sqlite_only.queryU64(&storage, "SELECT acceptance_position FROM action_operation WHERE resolution_code='failed'", .{}));
    try std.testing.expectEqual(content_id, try store_testing.sqlite_only.queryU64(&storage, "SELECT resolution_content_id FROM action_operation WHERE resolution_code='failed'", .{}));
}

test "every transition dates its fact from the Host clock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const before: u64 = @intCast(@divFloor(try store_core.readUnixMilliseconds(std.testing.io), 1000));

    const session = try configureTestSessionAsk(&storage, "dated-config");
    try submitTestMessage(&storage, &tmp, "dated-message", "dated-message", session.slice(), "propose");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"one\",\"timeout_ms\":null}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "dated-metadata", &calls);
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT action_id FROM action_operation", .{}), .decision = .allow_once };
    try allow.key.set("dated-allow");
    try allow.session.set(session.slice());
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
    var stop = try completeSessionStop("dated-stop", session.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    try std.testing.expectEqual(ActionSettlement.session_stop, try storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{}));
    const after: u64 = @intCast(@divFloor(try store_core.readUnixMilliseconds(std.testing.io), 1000));

    const Column = struct { table: []const u8, column: []const u8 };
    const columns = [_]Column{
        .{ .table = "session", .column = "created_at" },
        .{ .table = "conversation_entry", .column = "recorded_at" },
        .{ .table = "model_operation", .column = "resolved_at" },
        .{ .table = "action_operation", .column = "decided_at" },
        .{ .table = "action_operation", .column = "attempt_at" },
        .{ .table = "action_operation", .column = "resolved_at" },
        .{ .table = "session_stop", .column = "stopped_at" },
        .{ .table = "turn", .column = "outcome_at" },
    };
    for (columns) |column| {
        var sql_buffer: [160]u8 = undefined;
        const sql = try std.fmt.bufPrintSentinel(&sql_buffer, "SELECT count(*) FROM {s} WHERE {s} BETWEEN {d} AND {d}", .{ column.table, column.column, before, after }, 0);
        const dated = try store_testing.sqliteQueryU64(storage.sqliteDatabase(), sql, .{});
        if (dated == 0) std.debug.print("{s}.{s} is not dated within the transition\n", .{ column.table, column.column });
        try std.testing.expect(dated != 0);
    }
}

test "Action admission never visits an Action waiting for permission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    // Each round adds a Turn with two Actions waiting for permission.
    var sessions: [2]protocol.Bounded(protocol.max_session_bytes) = undefined;
    var steps: [2]i32 = undefined;
    var allowed: [2]u64 = undefined;
    for (&sessions, &steps, &allowed, 0..) |*session, *cost, *allowed_id, round| {
        var name_buffer: [32]u8 = undefined;
        session.* = try configureTestSessionAsk(&storage, try std.fmt.bufPrint(&name_buffer, "waiting-config-{d}", .{round}));
        var message_buffer: [32]u8 = undefined;
        const message = try std.fmt.bufPrint(&message_buffer, "waiting-message-{d}", .{round});
        try submitTestMessage(&storage, &tmp, message, message, session.slice(), "propose");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        var metadata_buffer: [32]u8 = undefined;
        try settleTwoActionsForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&metadata_buffer, "waiting-metadata-{d}", .{round}));
        try std.testing.expect((try storage.admitNextActionAttempt(300_000, .{})) == null);
        allowed_id.* = try store_testing.sqlite_only.queryU64(&storage, "SELECT max(action_id) FROM action_operation", .{});

        const select = try sqlite.prepare(storage.sqliteDatabase(), next_action_attempt_sql);
        defer _ = c.sqlite3_finalize(select);
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(select));
        cost.* = c.sqlite3_stmt_status(select, c.SQLITE_STMTSTATUS_VM_STEP, 0);
    }
    // Four waiting Actions cost the scan what two did: none is in its index.
    try std.testing.expectEqual(@as(u64, 4), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE authorized=0 AND resolution_code IS NULL", .{}));
    try std.testing.expectEqual(steps[0], steps[1]);

    // One allowed Action per Turn enters the index; its sibling stays out.
    for (sessions, allowed, 0..) |session, action_id, round| {
        var key_buffer: [32]u8 = undefined;
        var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
        try allow.key.set(try std.fmt.bufPrint(&key_buffer, "waiting-allow-{d}", .{round}));
        try allow.session.set(session.slice());
        try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    }
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqliteQueryU64(storage.sqliteDatabase(), "SELECT count(*) FROM action_operation INDEXED BY action_operation_executable " ++
        "WHERE authorized=1 AND resolution_code IS NULL AND attempt_ordinal=0", .{}));
    for (allowed) |action_id| {
        const admitted = (try storage.admitNextActionAttempt(300_000, .{})).?;
        try std.testing.expectEqual(action_id, admitted.permit.binding.action_id);
    }
    try std.testing.expect((try storage.admitNextActionAttempt(300_000, .{})) == null);
}

test "complete call outcomes continue once in call order ahead of pending input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSessionAsk(&storage, "result-config");
    try submitTestMessage(&storage, &tmp, "result-first", "result-first", session.slice(), "first");
    const first_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "result-item-0", .name = "bash", .encoded_call_id = "result-call-0", .decoded_call_id = "result-call-0", .encoded_arguments = "{\\\"description\\\":\\\"Run zeroth command\\\",\\\"cmd\\\":\\\"zero\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run zeroth command\",\"cmd\":\"zero\",\"timeout_ms\":null}" },
        .{ .item_id = "result-item-1", .name = "unknown", .encoded_call_id = "result-call-1", .decoded_call_id = "result-call-1", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "result-item-2", .name = "bash", .encoded_call_id = "result-call-2", .decoded_call_id = "result-call-2", .encoded_arguments = "{", .decoded_arguments = "{" },
        .{ .item_id = "result-item-3", .name = "bash", .encoded_call_id = "result-call-3", .decoded_call_id = "result-call-3", .encoded_arguments = "{\\\"description\\\":\\\"Run third command\\\",\\\"cmd\\\":\\\"three\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run third command\",\"cmd\":\"three\",\"timeout_ms\":null}" },
    };
    try settleCallsForTesting(&storage, &tmp, first_binding, "result-metadata", &calls);
    try submitTestMessage(&storage, &tmp, "result-second", "result-second", session.slice(), "second");
    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);

    const first_action_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT min(action_id) FROM action_operation", .{});
    const second_action_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT max(action_id) FROM action_operation", .{});
    var deny_second: protocol.PermissionDecisionCommand = .{ .action_id = second_action_id };
    try deny_second.key.set("result-deny-second");
    try deny_second.session.set(session.slice());
    try std.testing.expect(storage.decidePermission(&deny_second, .{}) == .accepted);
    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);

    var deny_first: protocol.PermissionDecisionCommand = .{ .action_id = first_action_id };
    try deny_first.key.set("result-deny-first");
    try deny_first.session.set(session.slice());
    try std.testing.expect(storage.decidePermission(&deny_first, .{}) == .accepted);
    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expectEqual(first_binding.turn_id, continuation.turn_id);
    try std.testing.expectEqual(first_binding.operation_id + 1, continuation.operation_id);
    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);

    const replayed_denial = storage.decidePermission(&deny_first, .{});
    try std.testing.expect(replayed_denial == .accepted);
    try std.testing.expect(replayed_denial.accepted.replayed);
    var stale_denial: protocol.PermissionDecisionCommand = .{ .action_id = first_action_id };
    try stale_denial.key.set("result-stale-denial");
    try stale_denial.session.set(session.slice());
    const stale_reply = storage.decidePermission(&stale_denial, .{});
    try std.testing.expect(stale_reply == .rejected);
    try std.testing.expectEqual(protocol.PermissionDecisionRejection.action_not_pending, stale_reply.rejected.code);

    var view: HistoricalView = undefined;
    try storage.openHistoricalView(continuation, &view);
    defer view.close();
    var position: u64 = 0;
    try std.testing.expectEqual(HistoricalEntryKind.user, (try view.nextEntry(position)).?.kind);
    position = (try view.nextEntry(position)).?.position;
    // The Operation that proposed the calls, at its admission position.
    const proposing = (try view.nextEntry(position)).?;
    try std.testing.expectEqual(HistoricalEntryKind.operation, proposing.kind);
    position = proposing.position;
    for (0..calls.len) |_| {
        const item = (try view.nextEntry(position)).?;
        try std.testing.expectEqual(HistoricalEntryKind.provider_output, item.kind);
        position = item.position;
    }
    const group = (try view.nextEntry(position)).?;
    try std.testing.expectEqual(HistoricalEntryKind.tool_results, group.kind);
    position = group.position;

    const expected_call_ids = [_][]const u8{ "result-call-0", "result-call-1", "result-call-2", "result-call-3" };
    const expected_outputs = [_][]const u8{
        "Permission denied.",
        "Unknown tool: unknown.",
        "Invalid arguments for tool 'bash': the arguments are not one well-formed JSON object.",
        "Permission denied.",
    };
    for (expected_call_ids, expected_outputs, 0..) |expected_call_id, expected_output, ordinal| {
        _ = ordinal;
        const result = (try view.nextToolResult()).?;
        var call_id: HistoricalReader = undefined;
        try view.openContent(result.call_id, &call_id);
        var output: HistoricalReader = undefined;
        try view.openContent(result.output, &output);
        var buffer: [128]u8 = undefined;
        const call_id_count = try call_id.read(0, &buffer);
        try std.testing.expectEqualStrings(expected_call_id, buffer[0..call_id_count]);
        const checkpoint = c.sqlite3_wal_checkpoint_v2(storage.sqliteDatabase(), null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null);
        const output_count = try output.read(0, &buffer);
        try std.testing.expectEqualStrings(expected_output, buffer[0..output_count]);
        output.close();
        call_id.close();
        try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), checkpoint);
    }
    try std.testing.expect((try view.nextToolResult()) == null);
    const pending = (try view.nextEntry(position)).?;
    try std.testing.expectEqual(HistoricalEntryKind.user, pending.kind);
    try std.testing.expect((try view.nextEntry(pending.position)) == null);
    try std.testing.expectEqual(HistoricalEntryKind.user, (try view.nextEntry(0)).?.kind);
}

test "tool continuation admission runs its selection once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "config");
    try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "start");
    const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
    const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
    try settleCallsForTesting(&storage, &tmp, first, "output", &calls);

    const selection = try storage.engine.sqlite.cachedTyped(tool_continuation_selection);
    const runs_before = c.sqlite3_stmt_status(selection, c.SQLITE_STMTSTATUS_RUN, 0);
    const continued = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
    try std.testing.expectEqual(first.turn_id, continued.turn_id);
    try std.testing.expectEqual(runs_before + 1, c.sqlite3_stmt_status(selection, c.SQLITE_STMTSTATUS_RUN, 0));
}

test "a stored continuation never names a later Operation than its Turn's" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "later-config");
    try submitTestMessage(&storage, &tmp, "later", "later", session.slice(), "start");
    _ = (try storage.admitModelAttempt(.message, .{})).?;
    try std.testing.expectEqual(ConstraintProbe.accepted, try probeConstraint(storage.sqliteDatabase(), "UPDATE turn SET continuation_operation_id=operation_id"));
    try std.testing.expectEqual(ConstraintProbe.check_violation, try probeConstraint(storage.sqliteDatabase(), "UPDATE turn SET continuation_operation_id=operation_id+1"));
}

test "tool continuation selection never visits a Turn waiting for its tool results" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    // Each round adds a Turn with two Actions waiting for permission.
    var steps: [2]i32 = undefined;
    for (&steps, 0..) |*cost, round| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "waiting-{d}", .{round});
        var config_buffer: [40]u8 = undefined;
        const config = try std.fmt.bufPrint(&config_buffer, "{s}-config", .{name});
        const session = try configureTestSessionAsk(&storage, config);
        try submitTestMessage(&storage, &tmp, name, name, session.slice(), "propose");
        const binding = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
        try settleTwoActionsForTesting(&storage, &tmp, binding, config);

        const select = try sqlite.prepare(storage.sqliteDatabase(), tool_continuation_selection.sql);
        defer _ = c.sqlite3_finalize(select);
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(select));
        cost.* = c.sqlite3_stmt_status(select, c.SQLITE_STMTSTATUS_VM_STEP, 0);
    }
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM turn WHERE outcome_code IS NULL", .{}));
    try std.testing.expectEqual(steps[0], steps[1]);
}

test "complete historical tool-result traversal scales with groups and calls" {
    const Measure = struct {
        const Counter = struct {
            steps: u64 = 0,

            fn progress(context: ?*anyopaque) callconv(.c) c_int {
                const counter: *Counter = @ptrCast(@alignCast(context orelse return 1));
                counter.steps += 1;
                return 0;
            }
        };

        fn run(group_count: usize, calls_per_group: usize) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "scale-config");
            try submitTestMessage(
                &storage,
                &tmp,
                "scale-message-file",
                "scale-message",
                session.slice(),
                "scale",
            );
            var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var calls: [32]TestingCall = undefined;
            var item_ids: [32][32]u8 = undefined;
            var call_ids: [32][32]u8 = undefined;
            for (calls[0..calls_per_group], 0..) |*call, index| {
                const item_id = try std.fmt.bufPrint(&item_ids[index], "scale-item-{d}", .{index});
                const call_id = try std.fmt.bufPrint(&call_ids[index], "scale-call-{d}", .{index});
                call.* = .{
                    .item_id = item_id,
                    .name = "unknown",
                    .encoded_call_id = call_id,
                    .decoded_call_id = call_id,
                    .encoded_arguments = "{}",
                    .decoded_arguments = "{}",
                };
            }
            for (0..group_count) |index| {
                var prefix_buffer: [64]u8 = undefined;
                try settleCallsForTesting(
                    &storage,
                    &tmp,
                    binding,
                    try std.fmt.bufPrint(&prefix_buffer, "scale-metadata-{d}", .{index}),
                    calls[0..calls_per_group],
                );
                binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }

            var counter: Counter = .{};
            c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, Counter.progress, &counter);
            defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(binding, &view);
            defer view.close();
            var position: u64 = 0;
            var groups_seen: usize = 0;
            var results_seen: usize = 0;
            while (try view.nextEntry(position)) |entry| {
                position = entry.position;
                if (entry.kind != .tool_results) continue;
                groups_seen += 1;
                while (try view.nextToolResult()) |_| {
                    results_seen += 1;
                }
            }
            try std.testing.expectEqual(group_count, groups_seen);
            try std.testing.expectEqual(group_count * calls_per_group, results_seen);
            return counter.steps;
        }
    };

    const baseline = try Measure.run(4, 1);
    const more_groups = try Measure.run(16, 1);
    const call_baseline = try Measure.run(4, 8);
    const more_calls = try Measure.run(4, 32);
    try std.testing.expect(more_groups > baseline);
    try std.testing.expect(more_groups < baseline * 7);
    try std.testing.expect(more_calls > call_baseline);
    try std.testing.expect(more_calls < call_baseline * 8);
}

/// One bounded step through history in preparation order. Each served
/// entry moves `after` past it, a tool group is drained, and the end sets
/// `after` to the largest position.
fn testingHistoricalStep(view: *HistoricalView, after: *u64, bytes: *usize, items: *usize) !void {
    switch (try view.nextEntryStep(after.*, bytes, items)) {
        .pending => {},
        .ready => |served| if (served) |entry| {
            after.* = entry.position;
            if (entry.kind == .tool_results) while (try view.nextToolResult()) |_| {};
        } else {
            after.* = std.math.maxInt(u64);
        },
    }
}

test "historical preparation yields covered group populations under small allowances" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const allocated_session_0 = try configureTestSession(&storage, "bounded-config");
    try submitTestMessage(&storage, &tmp, "bounded-input", "bounded-input", allocated_session_0.slice(), "tools");
    var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var calls: [16]TestingCall = undefined;
    var ids: [16][32]u8 = undefined;
    const arguments: [3072]u8 = @splat('x');
    for (&calls, 0..) |*call, i| {
        const id = try std.fmt.bufPrint(&ids[i], "bounded-{d}", .{i});
        call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = &arguments, .decoded_arguments = &arguments };
    }
    for (0..8) |i| {
        var prefix: [32]u8 = undefined;
        try settleCallsForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&prefix, "bounded-{d}", .{i}), &calls);
        binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    }
    // An after-position covering every group must not drain discovery in one
    // call, and a view closed mid-discovery leaves checkpoints free.
    {
        var view: HistoricalView = undefined;
        try storage.openHistoricalView(binding, &view);
        while (!try view.validateOutputsStep()) {}
        var bytes: usize = 7;
        var items: usize = 1;
        try std.testing.expect(try view.nextEntryStep(view.output_boundary, &bytes, &items) == .pending);
        _ = try configureTestSession(&storage, "yielded-checkpoint");
        const checkpoint = c.sqlite3_wal_checkpoint_v2(storage.sqliteDatabase(), null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null);
        view.close();
        try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), checkpoint);
    }
    var view: HistoricalView = undefined;
    try storage.openHistoricalView(binding, &view);
    defer view.close();
    while (!try view.validateOutputsStep()) {}
    var turns: usize = 0;
    var served: usize = 0;
    var after: u64 = 0;
    while (after != std.math.maxInt(u64)) {
        turns += 1;
        try std.testing.expect(turns < 200000);
        var bytes: usize = 127;
        var items: usize = 3;
        const before = after;
        try testingHistoricalStep(&view, &after, &bytes, &items);
        if (after != before) served += 1;
    }
    // One user input, 8 Operations each with its group of 16 calls, their
    // 8 result groups and the end, each served by its own step after
    // discovery yields.
    try std.testing.expectEqual(@as(usize, 1 + 8 + 8 * calls.len + 8 + 1), served);
    try std.testing.expect(turns > served);
    try std.testing.expect(!storage.isFenced());
}

test "large historical readers leave checkpoints free" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const text = try std.testing.allocator.alloc(u8, 1024 * 1024 + 37);
    defer std.testing.allocator.free(text);
    for (text, 0..) |*byte, index| byte.* = @intCast('a' + index % 23);
    const session = try configureTestSession(&storage, "large-history-config");
    try submitTestMessage(&storage, &tmp, "large-history-input", "large-history-key", session.slice(), text);
    const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleCallsForTesting(&storage, &tmp, source, "large-history-call", &.{.{
        .item_id = "large-item",
        .name = "unknown",
        .encoded_call_id = "large-call",
        .decoded_call_id = "large-call",
        .encoded_arguments = text,
        .decoded_arguments = text,
    }});
    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var view: HistoricalView = undefined;
    try storage.openHistoricalView(continuation, &view);
    defer view.close();
    const entry = (try view.nextEntry(0)).?;
    try std.testing.expectEqual(HistoricalEntryKind.user, entry.kind);
    var reader: HistoricalReader = undefined;
    try view.openContent(entry.content.?, &reader);
    defer reader.close();
    reader.reader.allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < text.len) {
        const wanted = @min(buffer.len, text.len - offset);
        try std.testing.expectEqual(wanted, try reader.read(offset, &buffer));
        try std.testing.expectEqualSlices(u8, text[offset..][0..wanted], buffer[0..wanted]);
        if (offset == 0) {
            _ = try configureTestSession(&storage, "large-history-write");
            try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_wal_checkpoint_v2(storage.sqliteDatabase(), null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null));
        }
        offset += wanted;
    }
    try std.testing.expectEqual(@as(usize, 0), try reader.read(text.len, &buffer));
    try std.testing.expect(!storage.isFenced());
}

test "historical preparation rejects missing extra and reordered sibling classifications incrementally" {
    for ([_]bool{ false, true }) |covered| {
        // `corrupts_bytes`: the fault breaks bytes replay reads, not rows.
        cases: for ([_]struct { sql: [:0]const u8, corrupts_bytes: bool = false }{
            .{ .sql = "UPDATE model_tool_call SET call_ordinal=99 WHERE call_ordinal=0; UPDATE model_tool_call SET call_ordinal=0 WHERE call_ordinal=1; UPDATE model_tool_call SET call_ordinal=1 WHERE call_ordinal=99" },
            .{ .sql = "DELETE FROM model_tool_call WHERE call_ordinal=1" },
            .{ .sql = "UPDATE model_output_item SET item_kind=1 WHERE item_ordinal=1" },
            .{ .sql = "DELETE FROM model_output_item WHERE item_ordinal=1; DELETE FROM model_tool_call WHERE call_ordinal=1" },
            .{ .sql = "DELETE FROM model_output_item WHERE operation_id IN (SELECT operation_id FROM model_tool_call); DELETE FROM model_tool_call" },
            .{ .sql = "UPDATE content SET payload=zeroblob(byte_length) WHERE private=1", .corrupts_bytes = true },
        }) |fault| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "sibling-config");
            try submitTestMessage(&storage, &tmp, "sibling-input", "sibling-input", session.slice(), "tools");
            const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{
                .{ .item_id = "a", .name = "unknown", .encoded_call_id = "a", .decoded_call_id = "a", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                .{ .item_id = "b", .name = "unknown", .encoded_call_id = "b", .decoded_call_id = "b", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            };
            try settleCallsForTesting(&storage, &tmp, source, "sibling-output", &calls);
            var next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            if (covered) {
                try storage.settleModelAttemptFailure(next, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                const compact = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCompactionForTesting(&storage, &tmp, compact, &.{.compaction});
                next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
            try sqlite.exec(storage.sqliteDatabase(), fault.sql);
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(next, &view);
            defer view.close();
            while (!(view.validateOutputsStep() catch |err| {
                try std.testing.expectEqual(error.CorruptStore, err);
                try std.testing.expect(storage.isFenced());
                continue :cases;
            })) {}
            // Row faults fail while discovery walks the group, before any
            // entry is served. Corrupt call bytes fence when replay reads
            // the first call, whose digest no longer matches.
            const bytes_fault = fault.corrupts_bytes;
            var served: ?HistoricalEntry = null;
            while (true) {
                var bytes: usize = 1;
                var items: usize = 1;
                const progress = view.nextEntryStep(if (served) |entry| entry.position else 0, &bytes, &items) catch |err| {
                    try std.testing.expectEqual(error.CorruptStore, err);
                    try std.testing.expect(!bytes_fault);
                    break;
                };
                if (!bytes_fault and view.tool_group_initialized) return error.MissingCorruptionFailure;
                switch (progress) {
                    .pending => {},
                    .ready => |entry| {
                        // The view never reaches its end, so no request seals.
                        if (!bytes_fault) return error.MissingCorruptionFailure;
                        served = entry.?.*;
                        if (served.?.kind == .user or served.?.kind == .operation) continue;
                        try std.testing.expectEqual(HistoricalEntryKind.provider_output, served.?.kind);
                        const output = try view.openOutput(served.?.position);
                        try std.testing.expectEqual(OutputItemKind.function_call, output.kind);
                        // The call's private bag holds its item ID.
                        var reader: HistoricalReader = undefined;
                        try view.openContent(output.bag.?, &reader);
                        defer reader.close();
                        var buffer: [4096]u8 = undefined;
                        try std.testing.expectError(error.CorruptStore, reader.read(0, buffer[0..@intCast(output.bag.?.length)]));
                        break;
                    },
                }
            }
            try std.testing.expect(storage.isFenced());
        }
    }
}

test "historical accepted assistant output completeness and provenance fence reads" {
    // Replay trusts each item's saved kind, identity and bytes once their
    // digest matches; acceptance judged them, and the rows below the
    // admission boundary are immutable.
    const Incompatibility = enum { none, model };
    for ([_]struct { fault: ?[:0]const u8 = null, incompatible: Incompatibility = .none, tied_owners: bool = false, failure: anyerror = error.CorruptStore }{
        .{ .tied_owners = true, .fault = "DELETE FROM model_output_item WHERE operation_id=(SELECT max(operation_id) FROM model_output_item)" },
        .{ .tied_owners = true, .fault = "UPDATE model_operation SET output_item_count=output_item_count+1 WHERE operation_id=(SELECT max(operation_id) FROM model_output_item)" },
        .{ .tied_owners = true, .fault = "UPDATE model_operation SET output_item_count=output_item_count-1 WHERE operation_id=(SELECT max(operation_id) FROM model_output_item)" },
        .{ .tied_owners = true, .fault = "DELETE FROM model_output_item WHERE operation_id=(SELECT min(operation_id) FROM model_output_item)" },
        .{ .tied_owners = true, .fault = "UPDATE model_operation SET output_item_count=output_item_count+1 WHERE operation_id=(SELECT min(operation_id) FROM model_output_item)" },
        .{ .tied_owners = true, .fault = "UPDATE model_operation SET output_item_count=output_item_count-1 WHERE operation_id=(SELECT min(operation_id) FROM model_output_item)" },
        .{ .fault = "DELETE FROM model_output_item" },
        .{ .fault = "DELETE FROM model_output_item WHERE item_ordinal=1" },
        .{ .fault = "UPDATE model_output_item SET item_ordinal=9 WHERE item_ordinal=1" },
        .{ .fault = "UPDATE model_output_item SET session_position=session_position+100 WHERE item_ordinal=1" },
        .{ .fault = "UPDATE model_output_item SET session_position=session_position+100 WHERE item_ordinal IN (0,1); " ++
            "UPDATE model_output_item SET session_position=session_position-99-2*item_ordinal WHERE item_ordinal IN (0,1)" },
        .{ .fault = "UPDATE model_output_item SET attempt_ordinal=attempt_ordinal+1" },
        .{ .fault = "UPDATE model_output_item SET session_ref='f0re1g'" },
        .{ .fault = "UPDATE content SET payload=zeroblob(byte_length) WHERE private=1" },
        .{ .fault = "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id=(SELECT extras_content_id FROM model_output_item WHERE item_ordinal=1)" },
        // Once continuation is unavailable, later items are not read.
        .{ .incompatible = .model, .fault = "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id=(SELECT extras_content_id FROM model_output_item WHERE item_ordinal=0)", .failure = error.ContinuationUnavailable },
        .{ .fault = "UPDATE model_operation SET resolution_code='failed' WHERE output_item_count IS NOT NULL" },
        .{ .fault = "UPDATE model_operation SET resolution_code='future' WHERE output_item_count IS NOT NULL" },
        .{ .fault = "UPDATE model_operation SET resolution_code='tool_proposals' WHERE output_item_count IS NOT NULL" },
        .{ .fault = "UPDATE turn SET session_ref='f0re1g' WHERE turn_id=(SELECT turn_id FROM model_operation WHERE output_item_count IS NOT NULL)" },
        .{ .incompatible = .model, .failure = error.ContinuationUnavailable },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "output-config");
        try submitTestMessage(&storage, &tmp, "output-input", "output-input", session.slice(), "first");
        var source_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const reasoning = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\"}";
        const answer = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}";
        const sse = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ reasoning ++ "}\n\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ answer ++ "}\n\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"response\",\"status\":\"completed\",\"output\":[]}}\n\n";
        const source = try tmp.dir.createFile(std.testing.io, "output-source", .{ .read = true });
        defer source.close(std.testing.io);
        try source.writeStreamingAll(std.testing.io, sse);
        var root: [protocol.max_store_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(std.testing.io, &root);
        var used: std.atomic.Value(u64) = .init(0);
        var retained: ?named_scratch.Owner = null;
        var metadata = try OutputMetadataWriter.init(std.testing.io, root[0..length], "output-metadata", .{ .used = &used, .limit = 4096 }, false, &retained);
        defer metadata.deinit();
        var event_data: output_decode.EventData = undefined;
        try event_data.init(std.testing.io, root[0..length], "output-event-data", .{ .used = &used, .limit = 4096 }, false, &retained);
        defer event_data.deinit();
        var interpreted: output_decode.Interpretation = undefined;
        output_decode.interpret(output_decode.testingInterpret(), .@"openai-responses/1", std.testing.io, source, sse.len, &metadata, &event_data, .assistant_response, .{}, output_decode.testingProviderFailure(), &interpreted);
        if (interpreted != .accepted) return error.TestUnexpectedResult;
        const validated = &interpreted.accepted.output;
        for (0..@as(usize, if (case.tied_owners) 2 else 1)) |index| {
            if (index != 0) {
                try submitTestMessage(&storage, &tmp, "output-second", "output-second", session.slice(), "second");
                source_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }
            try storage.settleModelSuccess(source_binding, &.{
                .source = validated.source,
                .source_length = validated.source_length,
                .metadata = metadata.file,
                .item_count = validated.item_count,
                .call_count = validated.call_count,
                .answer_item_ordinal = validated.answer_item_ordinal,
                .answer_length = validated.answer_length,
                .answer_digest = validated.answer_digest,
                .response_id = validated.evidence.response_id,
                .model_evidence = testing_absent_model_evidence,
                .request_id = .{},
            }, .{});
        }
        var reconfigure: protocol.ConfigureCommand = .{};
        try reconfigure.key.set("output-reconfigure");
        reconfigure.session = session;
        try std.testing.expect(storage.configure(&reconfigure, .{}) == .accepted);
        try submitTestMessage(&storage, &tmp, "output-next", "output-next", session.slice(), "next");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        switch (case.incompatible) {
            .none => {},
            .model => try storage.setHistoricalModelForTesting(source_binding, "different-model"),
        }
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        if (case.tied_owners) try store_testing.sqlite_only.exec(&storage, "UPDATE model_operation SET admission_position=" ++
            "(SELECT min(admission_position) FROM model_operation WHERE output_item_count IS NOT NULL) WHERE output_item_count IS NOT NULL", .{});
        // Deliberately bypass the message-certificate CHECK too: these cases
        // exercise read-time detection of damaged persisted item kinds.
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=ON");
        if (case.fault) |fault| try sqlite.exec(storage.sqliteDatabase(), fault);
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=OFF");
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
        var preparation: @import("../model_adapter.zig").Preparation = undefined;
        try storage.openHistoricalView(binding, &preparation.view);
        try preparation.init(std.testing.io, root[0..length], .{ .used = &used, .limit = 1024 * 1024 }, protocol.routesAll(.endpoint), null, .{}, &retained);
        defer if (preparation.state.active) preparation.cancel();
        while (true) {
            const progress = preparation.advance(7, 2);
            switch (progress) {
                .pending => {},
                .failed => |err| {
                    try std.testing.expectEqual(case.failure, err);
                    break;
                },
                .prepared => |request| {
                    request.deinit(std.testing.io, preparation.writer.budget);
                    return error.MissingCorruptionFailure;
                },
            }
        }
        try std.testing.expectEqual(case.failure == error.CorruptStore, storage.isFenced());
        preparation.cancel();
        try std.testing.expectEqual(@as(usize, 0), preparation.view.outstandingReaders());
    }
}

test "historical preparation fences a served call that does not match its certificate" {
    // A call binds its Tool Results through its admission certificate; replay
    // reads each call's bytes against their digest.
    for ([_][:0]const u8{
        "UPDATE content SET payload=zeroblob(byte_length) WHERE private=1",
        "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id=(SELECT extras_content_id FROM model_output_item WHERE item_ordinal=1)",
        "UPDATE model_tool_call SET arguments_content_id=name_content_id",
        "UPDATE model_operation SET resolution_code='answer' WHERE output_item_count IS NOT NULL",
        "UPDATE model_operation SET resolution_code='compacted' WHERE output_item_count IS NOT NULL",
        "UPDATE model_operation SET resolution_code='failed' WHERE output_item_count IS NOT NULL",
    }) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "incompatible-config");
        try submitTestMessage(&storage, &tmp, "incompatible-input", "incompatible-input", session.slice(), "tools");
        const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const calls = [_]TestingCall{
            .{ .item_id = "a", .name = "unknown", .encoded_call_id = "a", .decoded_call_id = "a", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            .{ .item_id = "b", .name = "unknown", .encoded_call_id = "b", .decoded_call_id = "b", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        };
        try settleCallsForTesting(&storage, &tmp, source, "incompatible-output", &calls);
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try sqlite.exec(storage.sqliteDatabase(), fault);
        var root: [protocol.max_store_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(std.testing.io, &root);
        var used: std.atomic.Value(u64) = .init(0);
        var retained: ?named_scratch.Owner = null;
        var preparation: @import("../model_adapter.zig").Preparation = undefined;
        try storage.openHistoricalView(binding, &preparation.view);
        try preparation.init(std.testing.io, root[0..length], .{ .used = &used, .limit = 1024 * 1024 }, protocol.routesAll(.endpoint), null, .{}, &retained);
        defer if (preparation.state.active) preparation.cancel();
        while (true) {
            const progress = preparation.advance(1, 1);
            switch (progress) {
                .pending => {},
                .failed => |err| {
                    try std.testing.expectEqual(error.CorruptStore, err);
                    break;
                },
                .prepared => |request| {
                    request.deinit(std.testing.io, preparation.writer.budget);
                    return error.MissingCompatibilityFailure;
                },
            }
        }
        try std.testing.expect(storage.isFenced());
        preparation.cancel();
        try std.testing.expectEqual(@as(usize, 0), preparation.view.outstandingReaders());
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
        try std.testing.expect(retained == null);
    }
}

test "historical accepted output selection work excludes failed Operation population" {
    const Measure = struct {
        steps: u64 = 0,

        fn progress(context: ?*anyopaque) callconv(.c) c_int {
            const counter: *@This() = @ptrCast(@alignCast(context orelse return 1));
            counter.steps += 1;
            return 0;
        }

        fn run(population: usize) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "selection-config");
            try submitTestMessage(&storage, &tmp, "selection-input", "selection-input", session.slice(), "retain");
            const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try store_testing.sqlite_only.exec(&storage, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL", .{});
            const insert = try sqlite.prepare(storage.sqliteDatabase(), "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL " ++
                "SELECT value+1 FROM sequence WHERE value<?1) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position," ++
                "attempt_ordinal,output_reservation,resolution_code,resolved_at) " ++
                "SELECT 100+value,current.turn_id,current.session_ref,current.settings_revision,current.input_cutoff,100+value," ++
                "1,0,'failed',1 FROM sequence CROSS JOIN model_operation current WHERE current.operation_id=?2");
            defer _ = c.sqlite3_finalize(insert);
            try sqlite.bindU64(insert, 1, population);
            try sqlite.bindU64(insert, 2, current.operation_id);
            try sqlite.expectDone(insert);
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(current, &view);
            defer view.close();
            var measured: @This() = .{};
            c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, progress, &measured);
            defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
            while (!try view.validateOutputsStep()) {}
            return measured.steps;
        }
    };
    const small = try Measure.run(8);
    const large = try Measure.run(1024);
    try std.testing.expect(large <= small + 100);
}

test "Current report work is independent of terminal tool history" {
    const Measure = struct {
        const Counter = struct {
            steps: u64 = 0,

            fn progress(context: ?*anyopaque) callconv(.c) c_int {
                const counter: *Counter = @ptrCast(@alignCast(context orelse return 1));
                counter.steps += 1;
                return 0;
            }
        };

        fn run(group_count: usize) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "current-cost-config");
            const calls = [_]TestingCall{.{
                .item_id = "current-cost-item",
                .name = "unknown",
                .encoded_call_id = "current-cost-call",
                .decoded_call_id = "current-cost-call",
                .encoded_arguments = "{}",
                .decoded_arguments = "{}",
            }};
            for (0..group_count) |index| {
                var file_buffer: [64]u8 = undefined;
                var key_buffer: [64]u8 = undefined;
                var metadata_buffer: [64]u8 = undefined;
                try submitTestMessage(
                    &storage,
                    &tmp,
                    try std.fmt.bufPrint(&file_buffer, "current-cost-file-{d}", .{index}),
                    try std.fmt.bufPrint(&key_buffer, "current-cost-message-{d}", .{index}),
                    session.slice(),
                    "call",
                );
                const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCallsForTesting(
                    &storage,
                    &tmp,
                    source,
                    try std.fmt.bufPrint(&metadata_buffer, "current-cost-metadata-{d}", .{index}),
                    &calls,
                );
                const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(continuation, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
            }
            try submitTestMessage(
                &storage,
                &tmp,
                "current-cost-active-file",
                "current-cost-active-message",
                session.slice(),
                "active",
            );
            const active = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            // Usage anchors the context estimate here, so the report reads
            // only what follows this call, as it does with a real provider.
            try settleCallsForTestingWithFaults(
                &storage,
                &tmp,
                active,
                "current-cost-active-metadata",
                &calls,
                .{},
                "{\"input_tokens\":10,\"output_tokens\":0}",
            );

            var root: [protocol.max_store_bytes]u8 = undefined;
            const root_length = try tmp.dir.realPath(std.testing.io, &root);
            var used = std.atomic.Value(u64).init(0);
            var counter: Counter = .{};
            c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, Counter.progress, &counter);
            defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
            var report = try storage.captureSessionReport(session.slice(), .{
                .scratch_path = root[0..root_length],
                .scratch_budget = .{ .used = &used, .limit = 1024 * 1024 },
                .request_number = 1,
                .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 },
            });
            report.deinit();
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            return counter.steps;
        }
    };

    const sixteen_groups = try Measure.run(16);
    const sixty_four_groups = try Measure.run(64);
    try std.testing.expectEqual(sixteen_groups, sixty_four_groups);
}

test "Current pending count skips excluded Message history by indexed cutoff" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "pending-cost-config");
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");

    var costs: [2]i32 = undefined;
    for ([_]usize{ 100, 10_000 }, 0..) |history, index| {
        try store_testing.sqlite_only.exec(&storage, "DELETE FROM message_admission; DELETE FROM session_stop", .{});
        const insert = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at) " ++
                "SELECT value,'{1s}',printf('excluded-%d',value),1,NULL,1 FROM sequence; " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at) " ++
                "VALUES({0}+1,'{1s}','eligible',1,NULL,1); " ++
                "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) " ++
                "VALUES('history-stop','{1s}',NULL,{0},1)",
            .{ history, session.slice() },
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.sqliteDatabase(), insert);
        var counted: reads_domain.First(command_domain.pending_messages.Row) = .{};
        {
            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            var a: reads_domain.ReadAccess = .open(&entry);
            defer a.deinit();
            a.readEach(command_domain.pending_messages, .{ .session = session.slice(), .cutoff = history }, 1, &counted);
            try a.run();
        }
        try std.testing.expectEqual(@as(u64, 1), counted.row.?.pending);

        const cutoff_statement = try sqlite.prepare(storage.sqliteDatabase(), session_stop_cutoff_sql);
        defer _ = c.sqlite3_finalize(cutoff_statement);
        try sqlite.bindText(cutoff_statement, 1, session.slice());
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(cutoff_statement));
        const cutoff = c.sqlite3_column_int64(cutoff_statement, 0);
        const count_statement = try sqlite.prepare(storage.sqliteDatabase(), pending_message_count_sql);
        defer _ = c.sqlite3_finalize(count_statement);
        try sqlite.bindText(count_statement, 1, session.slice());
        try sqlite.bindI64(count_statement, 2, cutoff);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(count_statement));
        try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(count_statement, 0));
        costs[index] = c.sqlite3_stmt_status(cutoff_statement, c.SQLITE_STMTSTATUS_VM_STEP, 0) +
            c.sqlite3_stmt_status(count_statement, c.SQLITE_STMTSTATUS_VM_STEP, 0);
    }
    try std.testing.expect(costs[1] <= costs[0] + 8);
}

test "Full Message projection work does not multiply Messages by stops" {
    const Measure = struct {
        const Counter = struct {
            steps: u64 = 0,

            fn progress(context: ?*anyopaque) callconv(.c) c_int {
                const counter: *Counter = @ptrCast(@alignCast(context orelse return 1));
                counter.steps += 1;
                return 0;
            }
        };

        fn run(message_count: usize, stop_count: usize) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "full-scale-config");
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");

            for (1..message_count + 1) |index| {
                const insert = try std.testing.allocator.printSentinel(
                    "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at,admission_position) " ++
                        "VALUES({0},'{1s}','message-{0}',1,NULL,1,{2})",
                    .{ index, session.slice(), 1000 + index },
                    0,
                );
                defer std.testing.allocator.free(insert);
                try sqlite.exec(storage.sqliteDatabase(), insert);
            }
            for (1..stop_count + 1) |index| {
                const insert = try std.testing.allocator.printSentinel(
                    "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) " ++
                        "VALUES('stop-{0}',3,'{2s}',zeroblob(32),NULL,NULL,1,'accepted',0,0,(SELECT coalesce(max(command_seq),0)+1 FROM core_command));" ++
                        "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,position,stopped_at) " ++
                        "VALUES('stop-{0}','{2s}',NULL,{1},{0},1)",
                    .{ index, message_count, session.slice() },
                    0,
                );
                defer std.testing.allocator.free(insert);
                try sqlite.exec(storage.sqliteDatabase(), insert);
            }

            var counter: Counter = .{};
            c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, Counter.progress, &counter);
            defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
            const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 8 * 1024 * 1024, .full);
            defer std.testing.allocator.free(full);
            return counter.steps;
        }
    };

    const baseline = try Measure.run(32, 32);
    const more_messages = try Measure.run(128, 32);
    const more_stops = try Measure.run(32, 128);
    const both_larger = try Measure.run(128, 128);
    try std.testing.expect(more_messages > baseline);
    try std.testing.expect(more_stops > baseline);
    try std.testing.expect(both_larger > more_messages);
    try std.testing.expect(both_larger > more_stops);
    try std.testing.expect(both_larger * 2 < (more_messages + more_stops) * 3);
}

test "an item id repeated in a later batch or the same batch fails the settlement" {
    inline for (.{ 65, 1 }) |repeat_at| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "repeat-item-config");
        try submitTestMessage(&storage, &tmp, "repeat-item-input", "repeat-item-key", session.slice(), "repeat");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        // Item 65 is in the second batch: a check over one batch's ids
        // alone passes it, and only the read of the saved items finds it.
        try std.testing.expectError(error.InvalidProviderEnvelope, settleMessagesForTesting(&storage, &tmp, binding, 66, false, repeat_at));
        try std.testing.expect(!storage.isFenced());
        try std.testing.expectEqual(0, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_output_item", .{}));
        try settleMessagesForTesting(&storage, &tmp, binding, 66, false, null);
        try std.testing.expectEqual(66, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_output_item", .{}));
        try expectDenseSessionPositions(&storage, session.slice());
    }
}

/// How many times a settlement read its saved item ids, then its content
/// identities, each in a narrow (sixteen digests) and a wide (64)
/// statement.
fn digestReadsForTesting(storage: *Store) [4]i64 {
    var reads: [4]i64 = @splat(0);
    for (storage.engine.sqlite.statements.slots) |slot| if (slot.statement) |statement| {
        const sql = std.mem.span(slot.sql.?);
        const kind: usize = if (std.mem.startsWith(u8, sql, "SELECT item_id_digest AS digest FROM model_output_item WHERE operation_id=?1"))
            0
        else if (std.mem.startsWith(u8, sql, "SELECT content_id,digest,byte_length,private FROM content WHERE digest IN ("))
            2
        else
            continue;
        const wide = std.mem.endsWith(u8, sql, "?65)") or std.mem.endsWith(u8, sql, "?64)");
        reads[kind + @intFromBool(wide)] += c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_RUN, 0);
    };
    return reads;
}

test "a settlement batch holds 64 items, read narrow up to sixteen" {
    // One batch per 64 items, so a reply of 64 settles in two rounds; a
    // batch of at most sixteen ids binds main's narrow statement. Each
    // message imports its text and its bag, and the usage record one
    // more, so 64 items look up 129 identities: two wide statements of 64
    // while more than 48 are left, then one narrow; 16 items' 33 take
    // main's three narrow ones.
    inline for (.{
        .{ 1, .{ 1, 0, 1, 0 } },
        .{ 16, .{ 1, 0, 3, 0 } },
        .{ 17, .{ 0, 1, 3, 0 } },
        .{ 64, .{ 0, 1, 1, 2 } },
        .{ 65, .{ 1, 1, 2, 2 } },
        .{ 100, .{ 0, 2, 2, 3 } },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "batch-width-config");
        try submitTestMessage(&storage, &tmp, "batch-width-input", "batch-width-key", session.slice(), "width");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try settleMessagesForTesting(&storage, &tmp, binding, case[0], false, null);
        try std.testing.expectEqual([4]i64{ case[1][0], case[1][1], case[1][2], case[1][3] }, digestReadsForTesting(&storage));
        try std.testing.expectEqual(case[0], try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_output_item", .{}));
    }
}

test "a full item batch followed by calls keeps every queued row's bound bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "full-batch-calls-config");
    try submitTestMessage(&storage, &tmp, "full-batch-calls-input", "full-batch-calls-key", session.slice(), "full");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    // 64 function_call items fill the first item batch and no usage
    // record follows, so the next item batch is empty and the call batch
    // is collected before any round steps the last item's queued row.
    var item_ids: [64][16]u8 = undefined;
    var call_ids: [64][16]u8 = undefined;
    var calls: [64]TestingCall = undefined;
    for (&calls, &item_ids, &call_ids, 0..) |*call, *item_id, *call_id, index| {
        const id = try std.fmt.bufPrint(call_id, "call-{d}", .{index});
        call.* = .{
            .item_id = try std.fmt.bufPrint(item_id, "item-{d}", .{index}),
            .name = "bash",
            .encoded_call_id = id,
            .decoded_call_id = id,
            .encoded_arguments = "{\\\"description\\\":\\\"Run it\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
            .decoded_arguments = "{\"description\":\"Run it\",\"cmd\":\"true\",\"timeout_ms\":null}",
        };
    }
    try settleCallsForTesting(&storage, &tmp, binding, "full-batch-calls", &calls);
    try std.testing.expectEqual(64, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(DISTINCT item_id_digest) FROM model_output_item", .{}));
    const digest = protocol.contentDigest("item-63");
    const statement = try sqlite.prepare(storage.sqliteDatabase(), "SELECT count(*) FROM model_output_item WHERE item_ordinal=63 AND item_id_digest=?1");
    defer _ = c.sqlite3_finalize(statement);
    try sqlite.bindBlob(statement, 1, &digest);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
    try std.testing.expectEqual(1, c.sqlite3_column_int64(statement, 0));
    try std.testing.expectEqual(64, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_tool_call", .{}));
    try expectDenseSessionPositions(&storage, session.slice());
}

test "a success settlement keeps main's answers for a missing Session or revision row" {
    inline for (.{
        .{ "DELETE FROM session_revision", error.StaleAttemptBinding, false },
        .{ "DELETE FROM session", error.CorruptStore, true },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "missing-row-config");
        try submitTestMessage(&storage, &tmp, "missing-row-input", "missing-row-key", session.slice(), "missing");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        try sqlite.exec(storage.sqliteDatabase(), case[0]);
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
        // A missing revision row is a stale binding, as on main; a missing
        // Session row fences, as main's session facts read did, where an
        // inner join reported a stale binding that does not fence.
        try std.testing.expectError(case[1], settleMessagesForTesting(&storage, &tmp, binding, 1, false, null));
        try std.testing.expectEqual(case[2], storage.isFenced());
    }
}

test "a success settlement whose pending Messages read fails reports main's SessionStopReadFailed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "stop-read-config");
    try submitTestMessage(&storage, &tmp, "stop-read-input", "stop-read-key", session.slice(), "first");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    // A pending Message makes the count read the stop cutoff.
    try submitTestMessage(&storage, &tmp, "stop-read-second", "stop-read-second-key", session.slice(), "second");
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    try store_testing.sqlite_only.exec(&storage, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) VALUES('stop-read-stop',?1,NULL,0,1)", .{session.slice()});
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
    try store_testing.failReadsOf(&storage, "session_stop");
    // Round 1 reads it with the Attempt; a step failure there was
    // `OperationReadFailed` before each read kept main's name.
    try std.testing.expectError(error.SessionStopReadFailed, settleMessagesForTesting(&storage, &tmp, binding, 1, false, null));
    try std.testing.expect(storage.isFenced());
}

test "64 calls with distinct unknown names fit one call batch's identities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "unknown-calls-config");
    try submitTestMessage(&storage, &tmp, "unknown-calls-input", "unknown-calls-key", session.slice(), "unknown");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    // Each call imports four identities: its name, call_id, arguments and
    // rejection text, 256 in all: exactly one batch's identities.
    var item_ids: [64][16]u8 = undefined;
    var call_ids: [64][16]u8 = undefined;
    var names: [64][16]u8 = undefined;
    var arguments: [64][32]u8 = undefined;
    var calls: [64]TestingCall = undefined;
    for (&calls, &item_ids, &call_ids, &names, &arguments, 0..) |*call, *item_id, *call_id, *name, *argument, index| {
        const id = try std.fmt.bufPrint(call_id, "call-{d}", .{index});
        const text = try std.fmt.bufPrint(argument, "{{}}{d}", .{index});
        call.* = .{
            .item_id = try std.fmt.bufPrint(item_id, "item-{d}", .{index}),
            .name = try std.fmt.bufPrint(name, "tool_{d}", .{index}),
            .encoded_call_id = id,
            .decoded_call_id = id,
            .encoded_arguments = text,
            .decoded_arguments = text,
        };
    }
    try settleCallsForTesting(&storage, &tmp, binding, "unknown-calls", &calls);
    try std.testing.expectEqual(64, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(DISTINCT rejection_content_id) FROM model_tool_call WHERE rejection_code='unknown_tool'", .{}));
    try std.testing.expectEqual(64, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(DISTINCT name_content_id) FROM model_tool_call", .{}));
    try std.testing.expectEqual(64, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(DISTINCT arguments_content_id) FROM model_tool_call", .{}));
    try expectDenseSessionPositions(&storage, session.slice());
}

test "equal texts in many batches share one row, and entries keep item order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "same-text-config");
    try submitTestMessage(&storage, &tmp, "same-text-input", "same-text-key", session.slice(), "same");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    // A later batch's lookup runs after the earlier batch's inserts.
    try settleMessagesForTesting(&storage, &tmp, binding, 140, true, null);
    try std.testing.expectEqual(1, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(DISTINCT message_content_id) FROM model_output_item", .{}));
    try std.testing.expectEqual(140, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM conversation_entry WHERE entry_kind=3", .{}));
    try std.testing.expectEqual(0, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM conversation_entry e JOIN model_output_item i " ++
        "ON i.operation_id=e.source_operation_id AND i.item_ordinal=e.source_item_ordinal WHERE e.session_position<>i.session_position", .{}));
    try expectDenseSessionPositions(&storage, session.slice());
}

test "an item with more content than a batch holds settles through its own lookups" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "wide-item-config");
    try submitTestMessage(&storage, &tmp, "wide-item-input", "wide-item-key", session.slice(), "wide");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    // 300 distinct summary texts: more identities than one batch's 256.
    var reasoning_buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&reasoning_buffer);
    try writer.writeAll("{\"type\":\"reasoning\",\"id\":\"wide\",\"summary\":[");
    for (0..300) |index| try writer.print("{s}{{\"type\":\"summary_text\",\"text\":\"summary {d}\"}}", .{ if (index == 0) "" else ",", index });
    try writer.writeAll("],\"encrypted_content\":\"opaque\"}");
    const items = [_][]const u8{ writer.buffered(), "{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}" };
    try settleItemsForTesting(&storage, &tmp, binding, &items, "done");
    try std.testing.expectEqual(300, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(DISTINCT text_content_id) FROM model_output_part WHERE part_kind=3", .{}));
    try std.testing.expectEqual(2, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_output_item", .{}));
    try expectDenseSessionPositions(&storage, session.slice());
}

test "controls wait behind an active model settlement transaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSession(&storage, "transaction-race-config");
    try submitTestMessage(
        &storage,
        &tmp,
        "transaction-race-message",
        "transaction-race-message",
        session.slice(),
        "execute",
    );
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{.{
        .item_id = "transaction-race-item",
        .name = "bash",
        .encoded_call_id = "transaction-race-call",
        .decoded_call_id = "transaction-race-call",
        .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
        .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
    }};

    const SettlementCheckpoint = enum(u8) { waiting, transaction_active, worker_finished };
    const Shared = struct {
        io: std.Io,
        order: std.atomic.Value(u64) = .init(0),
        checkpoint_ready: std.Io.Semaphore = .{},
        settlement_release: std.Io.Semaphore = .{},
        controls_requested: std.Io.Semaphore = .{},
        checkpoint: std.atomic.Value(SettlementCheckpoint) = .init(.waiting),
        transaction_active_order: std.atomic.Value(u64) = .init(0),
        settlement_complete_order: std.atomic.Value(u64) = .init(0),

        fn next(self: *@This()) u64 {
            return self.order.fetchAdd(1, .seq_cst) + 1;
        }

        fn settlementTrace(context: *anyopaque, phase: SettlementTracePhase) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (phase) {
                .transaction_active => {
                    self.transaction_active_order.store(self.next(), .seq_cst);
                    std.debug.assert(
                        self.checkpoint.cmpxchgStrong(
                            .waiting,
                            .transaction_active,
                            .acq_rel,
                            .acquire,
                        ) == null,
                    );
                    self.checkpoint_ready.post(self.io);
                    self.settlement_release.waitUncancelable(self.io);
                },
                .settlement_complete => self.settlement_complete_order.store(self.next(), .seq_cst),
                else => {},
            }
        }

        fn workerFinished(self: *@This()) void {
            if (self.checkpoint.swap(.worker_finished, .acq_rel) != .worker_finished) {
                self.checkpoint_ready.post(self.io);
            }
        }
    };
    const ControlProbe = struct {
        shared: *Shared,
        lock_acquired_order: std.atomic.Value(u64) = .init(0),

        fn mark(context: *anyopaque, phase: ControlTracePhase) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (phase) {
                .lock_requested => self.shared.controls_requested.post(self.shared.io),
                .lock_acquired => self.lock_acquired_order.store(self.shared.next(), .seq_cst),
                else => {},
            }
        }
    };
    const SettlementContext = struct {
        storage: *Store,
        tmp: *std.testing.TmpDir,
        binding: AttemptBinding,
        calls: []const TestingCall,
        shared: *Shared,
        failure_before_settlement: ?anyerror = null,
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            defer self.shared.workerFinished();
            if (self.failure_before_settlement) |err| {
                self.result = err;
                return;
            }
            settleCallsForTestingWithFaults(
                self.storage,
                self.tmp,
                self.binding,
                "transaction-race-metadata",
                self.calls,
                .{ .settlement_trace = .{ .context = self.shared, .mark_fn = Shared.settlementTrace } },
                null,
            ) catch |err| {
                self.result = err;
            };
        }
    };
    const StopContext = struct {
        storage: *Store,
        command: *const protocol.SessionStopCommand,
        probe: ControlProbe,
        reply: ?SessionStopReply = null,
        finished: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.reply = self.storage.stopSession(self.command, .{
                .control_trace = .{ .context = &self.probe, .mark_fn = ControlProbe.mark },
            });
            self.finished.store(true, .seq_cst);
        }
    };
    const InterruptContext = struct {
        storage: *Store,
        command: *const protocol.ModelInterruptionCommand,
        probe: ControlProbe,
        reply: ?ModelInterruptionReply = null,
        finished: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.reply = self.storage.interruptModel(self.command, .{
                .control_trace = .{ .context = &self.probe, .mark_fn = ControlProbe.mark },
            });
            self.finished.store(true, .seq_cst);
        }
    };

    var early_shared: Shared = .{ .io = std.testing.io };
    var early: SettlementContext = .{
        .storage = &storage,
        .tmp = &tmp,
        .binding = binding,
        .calls = &calls,
        .shared = &early_shared,
        .failure_before_settlement = error.InjectedSettlementCheckpointFailure,
    };
    const early_thread = try std.Thread.spawn(.{}, SettlementContext.run, .{&early});
    early_shared.checkpoint_ready.waitUncancelable(std.testing.io);
    early_thread.join();
    try std.testing.expectEqual(SettlementCheckpoint.worker_finished, early_shared.checkpoint.load(.acquire));
    try std.testing.expectEqual(error.InjectedSettlementCheckpointFailure, early.result.?);

    var shared: Shared = .{ .io = std.testing.io };
    var settlement_thread: ?std.Thread = null;
    var stop_thread: ?std.Thread = null;
    var interrupt_thread: ?std.Thread = null;
    var settlement_released = false;
    defer {
        if (!settlement_released) shared.settlement_release.post(std.testing.io);
        if (settlement_thread) |thread| thread.join();
        if (stop_thread) |thread| thread.join();
        if (interrupt_thread) |thread| thread.join();
    }
    var settlement: SettlementContext = .{
        .storage = &storage,
        .tmp = &tmp,
        .binding = binding,
        .calls = &calls,
        .shared = &shared,
    };
    settlement_thread = try std.Thread.spawn(.{}, SettlementContext.run, .{&settlement});
    shared.checkpoint_ready.waitUncancelable(std.testing.io);
    if (shared.checkpoint.load(.acquire) == .worker_finished) {
        settlement_thread.?.join();
        settlement_thread = null;
        if (settlement.result) |err| return err;
        return error.SettlementCheckpointMissing;
    }
    try std.testing.expectEqual(SettlementCheckpoint.transaction_active, shared.checkpoint.load(.acquire));

    var stop = try completeSessionStop("transaction-race-stop", session.slice());
    var interrupt = try completeModelInterruption(
        "transaction-race-interrupt",
        session.slice(),
        binding,
    );
    var stop_context: StopContext = .{
        .storage = &storage,
        .command = &stop,
        .probe = .{ .shared = &shared },
    };
    var interrupt_context: InterruptContext = .{
        .storage = &storage,
        .command = &interrupt,
        .probe = .{ .shared = &shared },
    };
    stop_thread = try std.Thread.spawn(.{}, StopContext.run, .{&stop_context});
    interrupt_thread = try std.Thread.spawn(.{}, InterruptContext.run, .{&interrupt_context});
    shared.controls_requested.waitUncancelable(std.testing.io);
    shared.controls_requested.waitUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(u64, 0), stop_context.probe.lock_acquired_order.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 0), interrupt_context.probe.lock_acquired_order.load(.seq_cst));
    try std.testing.expect(!stop_context.finished.load(.seq_cst));
    try std.testing.expect(!interrupt_context.finished.load(.seq_cst));

    shared.settlement_release.post(std.testing.io);
    settlement_released = true;
    settlement_thread.?.join();
    settlement_thread = null;
    stop_thread.?.join();
    stop_thread = null;
    interrupt_thread.?.join();
    interrupt_thread = null;
    if (settlement.result) |err| return err;

    const settlement_complete_order = shared.settlement_complete_order.load(.seq_cst);
    try std.testing.expect(shared.transaction_active_order.load(.seq_cst) < settlement_complete_order);
    try std.testing.expect(settlement_complete_order < stop_context.probe.lock_acquired_order.load(.seq_cst));
    try std.testing.expect(settlement_complete_order < interrupt_context.probe.lock_acquired_order.load(.seq_cst));
    try std.testing.expectEqual(c.SQLITE_TXN_NONE, c.sqlite3_txn_state(storage.sqliteDatabase(), "main"));

    const stop_reply = stop_context.reply.?;
    try std.testing.expect(stop_reply == .accepted);
    try std.testing.expectEqual(binding.turn_id, stop_reply.accepted.selection.selected_turn_id.?);
    try std.testing.expectEqual(protocol.SessionStopCompletion.completed, stop_reply.accepted.completion);
    const interrupt_reply = interrupt_context.reply.?;
    try std.testing.expect(interrupt_reply == .rejected);
    try std.testing.expectEqual(protocol.ModelInterruptionRejection.operation_resolved, interrupt_reply.rejected.code);

    const action_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT action_id FROM action_operation", .{});
    try expectContent(
        &storage,
        try storage.actionCallId(session.slice(), action_id),
        "transaction-race-call",
    );
    try expectContent(
        &storage,
        try storage.actionArguments(session.slice(), action_id),
        "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
    );
}

fn expectBindingPreserved(storage: *Store, session: []const u8, phase: []const u8) !void {
    for (0..6) |variant| {
        const before = try storage.inspectSessionForTesting(session);
        var key_buffer: [128]u8 = undefined;
        var update: protocol.ConfigureCommand = .{};
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
        if (variant >= 4) {
            update.configuration.tools.state = .value;
            update.configuration.tools.count = 0;
            update.configuration.permission_mode.state = .value;
            try update.configuration.permission_mode.value.set("bypass");
        }
        const reply = storage.configure(&update, .{});
        if (variant < 4) {
            try std.testing.expect(reply == .accepted);
            try std.testing.expectEqual(before.revision + 1, reply.accepted.revision);
        } else {
            try std.testing.expect(reply == .rejected);
            try std.testing.expectEqual(if (variant == 4) protocol.ConfigurationRejection.unsupported_provider else protocol.ConfigurationRejection.model_is_immutable, reply.rejected.code);
        }
        const after = try storage.inspectSessionForTesting(session);
        try std.testing.expectEqual(before.revision + @as(u64, if (variant < 4) 1 else 0), after.revision);
        try std.testing.expectEqual(protocol.Provider.codex, after.provider.?);
        try std.testing.expectEqualStrings("model-a", after.model.slice());
        try std.testing.expectEqual(before.tools_mask, after.tools_mask);
        try std.testing.expectEqualStrings(before.permission_mode.slice(), after.permission_mode.slice());
        try std.testing.expectEqualDeep(before.instructions, after.instructions);
        try std.testing.expectEqualDeep(before.output_schema, after.output_schema);
    }
}

test "persisted settings survive reopen and corrupt canonical provider fences current and historical reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("provider-reopen", "", workspace, "model-a");
    configuration.configuration.tools.state = .value;
    configuration.configuration.tools = try .of(&.{"bash"});
    configuration.configuration.permission_mode.state = .value;
    try configuration.configuration.permission_mode.value.set("ask");
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    const created_session_0_reply = storage.configure(&configuration, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    try expectBindingPreserved(&storage, created_session_0.slice(), "before-reopen");
    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const reopened = try storage.inspectSessionForTesting(created_session_0.slice());
    try std.testing.expectEqual(protocol.Provider.codex, reopened.provider.?);
    try std.testing.expectEqual(@as(u8, 1), reopened.tools_mask);
    try std.testing.expectEqualStrings("ask", reopened.permission_mode.slice());
    try expectBindingPreserved(&storage, created_session_0.slice(), "after-reopen");

    const file = try tmp.dir.createFile(std.testing.io, "provider-reopen-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "message");
    try file.sync(std.testing.io);
    var message = try completeMessage("provider-reopen-message", created_session_0.slice(), file, "message");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store_testing.sqlite_only.exec(&storage, "UPDATE session_revision SET provider='other' WHERE session_ref=?1", .{created_session_0.slice()});
    var view: HistoricalView = undefined;
    try storage.openHistoricalView(binding, &view);
    try std.testing.expectError(error.CorruptStore, testSettings(&view));
    view.close();
    try store_testing.sqlite_only.exec(&storage, "UPDATE session_revision SET provider='codex' WHERE session_ref=?1", .{created_session_0.slice()});
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT codec='openai-responses/2' AND codec_options IS NULL FROM session", .{}));
    for ([_][:0]const u8{
        "UPDATE session SET provider='Codex' WHERE session_ref=?1",
        "UPDATE session_revision SET provider='9codex' WHERE session_ref=?1",
        "UPDATE session SET provider='codex.v2' WHERE session_ref=?1",
        "UPDATE session SET provider='' WHERE session_ref=?1",
        "UPDATE session SET provider='abcdefghijklmnopq' WHERE session_ref=?1",
        "UPDATE session SET codec_options=x'' WHERE session_ref=?1",
    }) |fault| try std.testing.expectError(error.StatementFailed, store_testing.sqliteExec(storage.sqliteDatabase(), fault, .{created_session_0.slice()}));
    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);

    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET provider='other' WHERE session_ref=?1", .{created_session_0.slice()});
    try std.testing.expectError(error.CorruptStore, storage.inspectSessionForTesting(created_session_0.slice()));
}

test "a Session pinned to a codec this Host cannot build fences its settings" {
    for ([_]?[:0]const u8{
        null,
        "UPDATE session SET codec='openai-responses/3' WHERE session_ref=?1",
        "UPDATE session SET codec_options=x'00' WHERE session_ref=?1",
    }) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "config");
        try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT codec='openai-responses/2' AND codec_options IS NULL FROM session", .{}));
        try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "text");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        if (fault) |sql| try store_testing.sqliteExec(storage.sqliteDatabase(), sql, .{session.slice()});
        var view: HistoricalView = undefined;
        try storage.openHistoricalView(binding, &view);
        defer view.close();
        if (fault == null) _ = try testSettings(&view) else try std.testing.expectError(error.CorruptStore, testSettings(&view));
    }
}

test "configuration rejections bypass content effects and replay committed answer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const instructions = "rejected instructions";
    const instructions_file = try tmp.dir.createFile(std.testing.io, "rejected-instructions", .{ .read = true });
    try instructions_file.writeStreamingAll(std.testing.io, instructions);
    try instructions_file.sync(std.testing.io);
    const schema = "{\"type\":\"object\"}";
    const schema_file = try tmp.dir.createFile(std.testing.io, "rejected-schema", .{ .read = true });
    try schema_file.writeStreamingAll(std.testing.io, schema);
    try schema_file.sync(std.testing.io);
    var command: protocol.ConfigureCommand = .{};
    try command.key.set("rejected-content");
    try command.session.set("invalid/session");
    command.configuration.instructions = .{
        .state = .value,
        .file = instructions_file,
        .length = instructions.len,
        .digest = protocol.contentDigest(instructions),
    };
    command.configuration.output_schema = .{
        .state = .value,
        .file = schema_file,
        .length = schema.len,
        .digest = protocol.contentDigest(schema),
    };
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;

    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        try std.testing.expect(storage.configure(&command, .{
            .content_import = true,
            .before_commit = true,
        }) == .infrastructure_failure);
        try storage.close();
    }
    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        try std.testing.expect((try storage.observeCommand("rejected-content")).status == .absent);
        const rolled_back_content = try sqlite.prepare(storage.sqliteDatabase(), "SELECT count(*) FROM content WHERE content_id NOT IN (SELECT description_content_id FROM tool_record) AND content_id NOT IN (SELECT input_schema_content_id FROM tool_record)");
        defer _ = c.sqlite3_finalize(rolled_back_content);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(rolled_back_content));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(rolled_back_content, 0));

        const rejected = storage.configure(&command, .{ .content_import = true });
        try std.testing.expect(rejected == .rejected);
        try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_session_reference, rejected.rejected.code);
        const committed_content = try sqlite.prepare(
            storage.sqliteDatabase(),
            "SELECT COUNT(*) FROM core_command WHERE command_key='rejected-content' " ++
                "AND primary_content_id IS NULL AND secondary_content_id IS NULL",
        );
        defer _ = c.sqlite3_finalize(committed_content);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(committed_content));
        try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(committed_content, 0));

        const replay = storage.configure(&command, .{ .content_import = true });
        try std.testing.expect(replay == .rejected);
        try std.testing.expect(replay.rejected.replayed);
        try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_session_reference, replay.rejected.code);
        const retained_content = try sqlite.prepare(storage.sqliteDatabase(), "SELECT count(*) FROM content WHERE content_id NOT IN (SELECT description_content_id FROM tool_record) AND content_id NOT IN (SELECT input_schema_content_id FROM tool_record)");
        defer _ = c.sqlite3_finalize(retained_content);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(retained_content));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(retained_content, 0));
    }
}

test "interleaved large content readers bound repeated SQLite page reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const length = 4 * 1024 * 1024;
    const first = try std.testing.allocator.alloc(u8, length);
    defer std.testing.allocator.free(first);
    const second = try std.testing.allocator.alloc(u8, length);
    defer std.testing.allocator.free(second);
    for (first, second, 0..) |*a, *b, index| {
        a.* = @intCast(index % 251);
        b.* = @intCast((index * 17 + 37) % 253);
    }
    try importCommittedForTesting(&storage, first);
    try importCommittedForTesting(&storage, second);
    var readers: [2]ContentReader = undefined;
    readers[0].open(try storage.openContent(.{ .length = length, .digest = protocol.contentDigest(first) }));
    readers[1].open(try storage.openContent(.{ .length = length, .digest = protocol.contentDigest(second) }));
    defer for (&readers) |*reader| reader.close();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    readers[0].allocator = failing.allocator();
    var buffer: [4096]u8 = undefined;
    // EOF needs no read-ahead allocation. A real allocation failure preserves
    // the existing bounded reads and leaves this same Store usable.
    try std.testing.expectEqual(@as(usize, 0), try readers[0].read(length, &buffer));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(buffer.len, try readers[0].read(0, &buffer));
    try std.testing.expectEqualSlices(u8, first[0..buffer.len], &buffer);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
    for (&readers) |*reader| reader.allocator = std.testing.allocator;
    var misses: c_int = 0;
    var ignored: c_int = 0;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_db_status(storage.sqliteDatabase(), c.SQLITE_DBSTATUS_CACHE_MISS, &misses, &ignored, 1));
    var offset: usize = 0;
    while (offset < length) : (offset += buffer.len) {
        for (&readers, [_][]const u8{ first, second }) |*reader, expected| {
            try std.testing.expectEqual(buffer.len, try reader.read(offset, &buffer));
            try std.testing.expectEqualSlices(u8, expected[offset..][0..buffer.len], &buffer);
        }
        if (offset == 0) {
            _ = try configureTestSession(&storage, "interleaved-write");
            try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_wal_checkpoint_v2(storage.sqliteDatabase(), null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null));
        }
    }
    for (&readers) |*reader| try std.testing.expectEqual(@as(usize, 0), try reader.read(length, &buffer));
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_db_status(storage.sqliteDatabase(), c.SQLITE_DBSTATUS_CACHE_MISS, &misses, &ignored, 0));
    // Two 4-MiB streams through a 1-MiB SQLite cache must not re-read their
    // entire overflow prefix for every 4-KiB delivery, including interleaving.
    const pages = 2 * length / 4096;
    try std.testing.expect(misses <= 16 * pages);
    try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
    {
        const corrupt = try sqlite.prepare(storage.sqliteDatabase(), "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id=?1");
        defer _ = c.sqlite3_finalize(corrupt);
        try sqlite.bindI64(corrupt, 1, readers[0].content_id);
        try sqlite.expectDone(corrupt);
    }
    // Copied bytes belong only to their original reader. A newly resolved
    // raw reader must see the changed row, not another reader's old window.
    var fresh: ContentReader = undefined;
    fresh.open(try storage.openContent(readers[0].reference));
    defer fresh.close();
    fresh.allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 1), try readers[0].read(length - 1, buffer[0..1]));
    try std.testing.expectEqual(first[length - 1], buffer[0]);
    try std.testing.expectEqual(@as(usize, 1), try fresh.read(length - 1, buffer[0..1]));
    try std.testing.expectEqual(@as(u8, 0), buffer[0]);
    {
        const remove = try sqlite.prepare(storage.sqliteDatabase(), "DELETE FROM content WHERE content_id=?1");
        defer _ = c.sqlite3_finalize(remove);
        try sqlite.bindI64(remove, 1, readers[0].content_id);
        try sqlite.expectDone(remove);
    }
    try std.testing.expectEqual(@as(usize, 1), try readers[0].read(length - 1, buffer[0..1]));
    try std.testing.expectError(error.ContentReadFailed, readers[0].read(0, &buffer));
    try std.testing.expect(storage.isFenced());
}

test "retained readers allow checkpoints between committed windows" {
    var checkpoints: [2]c_int = undefined;
    for ([_]bool{ false, true }, 0..) |answer, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const text = @as([32768]u8, @splat('x')) ++ "asymmetric-é-tail";
        const location = if (answer) blk: {
            const request = try testingPublicProjection(&storage, &tmp, &.{.{ .encoded = text, .decoded = text }});
            break :blk try storage.openPublicConversationContent(&request);
        } else blk: {
            try importCommittedForTesting(&storage, text);
            break :blk try storage.openContent(.{ .length = text.len, .digest = protocol.contentDigest(text) });
        };
        var reader: ContentReader = undefined;
        reader.open(location);
        defer reader.close();
        var window: [4096]u8 = undefined;
        try std.testing.expectEqual(window.len, try reader.read(0, &window));
        try std.testing.expectEqualSlices(u8, text[0..window.len], &window);
        // Keep the reader alive across an unrelated ordinary commit, just as
        // slow Reply delivery or an allowance-limited preparation does.
        _ = try configureTestSession(&storage, "checkpoint-write");
        checkpoints[index] = c.sqlite3_wal_checkpoint_v2(storage.sqliteDatabase(), null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null);
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
        var offset: usize = window.len;
        while (offset < text.len) {
            const count = try reader.read(offset, &window);
            try std.testing.expectEqualSlices(u8, text[offset..][0..count], window[0..count]);
            offset += count;
        }
        try std.testing.expectEqual(@as(usize, 0), try reader.read(text.len, &window));
    }
    try std.testing.expectEqualSlices(c_int, &.{ c.SQLITE_OK, c.SQLITE_OK }, &checkpoints);
}

test "yielded Bash preparation leaves checkpoints free while retaining its descriptor" {
    const bash = @import("../bash.zig");
    for ([_]usize{ 0, 1024 * 1024 }) |padding_length| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const command = "printf " ++ @as([16384]u8, @splat('x'));
        const padding = try std.testing.allocator.alloc(u8, padding_length);
        defer std.testing.allocator.free(padding);
        @memset(padding, ' ');
        const descriptor = try std.testing.allocator.print("{{\"cmd\":\"{s}\",{s}\"timeout_ms\":null,\"description\":\"Print marker\"}}", .{ command, padding });
        defer std.testing.allocator.free(descriptor);
        const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, descriptor, .{});
        defer std.testing.allocator.free(encoded);
        const request = try testingPublicProjection(&storage, &tmp, &.{.{
            .encoded = encoded[1 .. encoded.len - 1],
            .decoded = descriptor,
        }});
        var input: BashExecutionInput = .{
            .session = request.session,
            .sender_handle = .{},
            .workspace = .{},
            .arguments = .{ .length = descriptor.len, .digest = undefined },
            .timeout_ms = 1000,
        };
        try input.workspace.set(storage.selector.slice());
        var used: std.atomic.Value(u64) = .init(0);
        const scratch: bash.Scratch = .{ .io = std.testing.io, .path = storage.selector.slice(), .budget = .{ .used = &used, .limit = 4096 } };
        var preparation: bash.Preparation = undefined;
        if (preparation.start(scratch, std.testing.allocator, try storage.openPublicConversationContent(&request), &input, storage.selector.slice(), "/bin/bash", 11, .{})) |initial| {
            var failure = initial;
            try failure.cleanup.cleanup(scratch);
            return failure.cause;
        }
        var owned = true;
        defer if (owned) {
            var cleanup = preparation.cancel();
            cleanup.cleanup(scratch) catch unreachable;
        };
        var prepared: bash.Prepared = undefined;
        try std.testing.expect(preparation.advance(&prepared) == .pending);
        _ = try configureTestSession(&storage, "bash-checkpoint");
        try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_wal_checkpoint_v2(storage.sqliteDatabase(), null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null));
        while (true) {
            var progress = preparation.advance(&prepared);
            switch (progress) {
                .pending => {},
                .prepared => {
                    owned = false;
                    defer prepared.cleanup() catch unreachable;
                    try std.testing.expectEqualStrings(command, prepared.command.?);
                    break;
                },
                .failed => |*failure| {
                    owned = false;
                    try failure.cleanup.cleanup(scratch);
                    return failure.cause;
                },
            }
        }
        try std.testing.expectEqual(@as(u64, 0), used.load(.monotonic));
    }
}

test "an outside SQLite writer cannot take the open Store's lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
    const database = try std.fmt.bufPrintSentinel(&database_buffer, "{s}/store.sqlite3", .{root}, 0);
    var storage: Store = undefined;
    try storage.open(std.testing.io, database, root);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;

    var blocker: ?*c.sqlite3 = null;
    try std.testing.expectEqual(
        @as(c_int, c.SQLITE_OK),
        c.sqlite3_open_v2(
            database.ptr,
            &blocker,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_NOMUTEX,
            null,
        ),
    );
    var blocker_open = true;
    defer if (blocker_open) {
        _ = c.sqlite3_close(blocker);
    };
    // The Store's exclusive lock refuses the outside writer, never the Host.
    try std.testing.expectEqual(
        @as(c_int, c.SQLITE_BUSY),
        c.sqlite3_exec(blocker, "BEGIN IMMEDIATE", null, null, null),
    );

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration(
        "busy-save",
        "",
        workspace,
        "model-a",
    );
    const configured = storage.configure(&command, .{});
    try std.testing.expect(configured == .accepted);
    try std.testing.expect(!storage.isFenced());

    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_close(blocker));
    blocker_open = false;
    try storage.close();
    storage_open = false;

    var reopened: Store = undefined;
    try reopened.open(std.testing.io, database, root);
    defer reopened.close() catch unreachable;
    try std.testing.expect((try reopened.observeCommand("busy-save")).status != .absent);
    try std.testing.expect((try reopened.inspectSessionForTesting(configured.accepted.session.slice())).found);
}

test "real SQLite full during import publishes no canonical prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;

    const page_count = try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA page_count");
    var limit_buffer: [64:0]u8 = undefined;
    const limit = try std.fmt.bufPrintSentinel(&limit_buffer, "PRAGMA max_page_count={d}", .{page_count}, 0);
    try sqlite.exec(storage.sqliteDatabase(), limit);
    try std.testing.expectEqual(page_count, try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA max_page_count"));

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration(
        "full-import",
        "",
        workspace,
        "model-a",
    );
    command.configuration.instructions = try testingContent(
        &tmp,
        "full-import-content",
        'x',
        128 * 1024,
    );
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;

    // Drive the production transaction body directly so the test observes
    // the exact import-step result before the public wrapper maps it. SQLite
    // automatically rolls this FULL transaction back; the public wrapper's
    // `finishTransaction` then fences it as a non-ordinary error.
    try std.testing.expectError(
        error.CanonicalStorageFull,
        configure: {
            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            var a: store_access.Access(.write, error{SessionUpdateFailed}) = .open(&entry);
            defer a.deinit();
            break :configure a.end(.{}, configuration_domain.configure(&a, storage.io, storage.served, &command, .{}));
        },
    );
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
    store_core.fence(&storage, error.CanonicalStorageFull) catch {};
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.observeCommand("full-import"));
    try storage.close();
    storage_open = false;

    var reopened: Store = undefined;
    try testingStore(&reopened, &tmp, std.testing.io);
    defer reopened.close() catch unreachable;
    try std.testing.expect((try reopened.observeCommand("full-import")).status == .absent);
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&reopened, "SELECT count(*) FROM session", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&reopened, "SELECT count(*) FROM content WHERE byte_length=131072", .{}));
}

test "message admissions remain queued in order and retain bounded canonical content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&configuration, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;

    const first_text = "first message\n" ++ @as([700 * 6]u8, @bitCast(@as([700][6]u8, @splat("abcdef".*)))) ++ "🙂";
    const first_file = try tmp.dir.createFile(std.testing.io, "first-message", .{ .read = true });
    try first_file.writeStreamingAll(std.testing.io, first_text);
    try first_file.sync(std.testing.io);
    var first = try completeMessage("message-1", created_session_0.slice(), first_file, first_text);
    defer first.removeTemporaryContent(std.testing.io) catch unreachable;
    const before = try sqlite.pragmaInt(storage.sqliteDatabase(), "SELECT unixepoch()");
    var commits: TestingCommits = .{};
    const first_reply = storage.submitMessageWithModel(&first, commits.callback(), .{});
    try std.testing.expectEqual(@as(usize, 1), commits.count);
    try std.testing.expect(commits.calls[0].session.eql(created_session_0.slice()));
    try std.testing.expectEqual(@as(u64, 1), commits.calls[0].admission_id);
    try std.testing.expect(!commits.calls[0].from_peer);
    try std.testing.expect(first_reply == .accepted);
    try std.testing.expect(!first_reply.accepted.replayed);
    try std.testing.expectEqual(@as(u64, 1), first_reply.accepted.admission_id);

    const second_text = "second";
    const second_file = try tmp.dir.createFile(std.testing.io, "second-message", .{ .read = true });
    try second_file.writeStreamingAll(std.testing.io, second_text);
    try second_file.sync(std.testing.io);
    var second = try completeMessage("message-2", created_session_0.slice(), second_file, second_text);
    defer second.removeTemporaryContent(std.testing.io) catch unreachable;
    const second_reply = storage.submitMessageWithModel(&second, null, .{});
    try std.testing.expect(second_reply == .accepted);
    try std.testing.expect(first_reply.accepted.admission_id < second_reply.accepted.admission_id);
    // The Host stamps each admission with its wall clock, to the second.
    const after = try sqlite.pragmaInt(storage.sqliteDatabase(), "SELECT unixepoch()");
    const stamped = try sqlite.pragmaInt(storage.sqliteDatabase(), "SELECT admitted_at FROM message_admission WHERE admission_id=1");
    try std.testing.expect(before <= stamped and stamped <= after);
    // A replayed or restarted admission keeps the time it was admitted at.
    try store_testing.sqlite_only.exec(&storage, "UPDATE message_admission SET admitted_at=1000 WHERE admission_id=1", .{});

    const replay = storage.submitMessageWithModel(&first, commits.callback(), .{});
    // A replayed admission installs nothing.
    try std.testing.expectEqual(@as(usize, 1), commits.count);
    try std.testing.expect(replay == .accepted);
    try std.testing.expect(replay.accepted.replayed);
    try std.testing.expectEqual(first_reply.accepted.admission_id, replay.accepted.admission_id);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(first_text), &replay.accepted.content.digest);

    const session = try storage.inspectSessionForTesting(created_session_0.slice());
    try std.testing.expectEqual(@as(u64, 2), session.pending_messages);
    const observed = try storage.observeCommand("message-1");
    try std.testing.expect(observed.status == .accepted);
    try std.testing.expect(observed.kind == .message);
    try std.testing.expect(observed.message != null);
    const accepted_observation = observed.message.?.queue.?;
    try std.testing.expectEqual(first_reply.accepted.admission_id, accepted_observation.admission_id);
    try std.testing.expect(accepted_observation.state == .queued);

    var reader: ContentReader = undefined;
    reader.open(try storage.openContent(observed.message.?.content));
    var actual: [first_text.len]u8 = undefined;
    var offset: usize = 0;
    while (offset < actual.len) {
        const count = try reader.read(offset, actual[offset..@min(actual.len, offset + 31)]);
        try std.testing.expect(count != 0);
        offset += count;
    }
    reader.close();
    try std.testing.expectEqualSlices(u8, first_text, &actual);

    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const restarted = try storage.observeCommand("message-1");
    try std.testing.expectEqual(first_reply.accepted.admission_id, restarted.message.?.queue.?.admission_id);
    try std.testing.expectEqual(@as(u64, 2), (try storage.inspectSessionForTesting(created_session_0.slice())).pending_messages);
    try std.testing.expectEqual(@as(u32, 1000), try sqlite.pragmaInt(storage.sqliteDatabase(), "SELECT admitted_at FROM message_admission WHERE admission_id=1"));
}

/// Gives `session` Bash, has its model propose two calls, and attempts
/// the first; the second stays unattempted.
fn attemptBashForTesting(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8) !ActionAttemptBinding {
    var tools: protocol.ConfigureCommand = .{};
    try tools.key.set("bash-tools");
    try tools.session.set(session);
    tools.configuration.tools = try .of(&.{"bash"});
    tools.configuration.permission_mode.state = .value;
    try tools.configuration.permission_mode.value.set("bypass");
    try std.testing.expect(storage.configure(&tools, .{}) == .accepted);
    try submitTestMessage(storage, tmp, "bash-seed", "bash-seed", session, "run two");
    try settleTwoActionsForTesting(storage, tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding, "bash-calls");
    return (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
}

/// Counts the statements the Store starts from `begin` to `end`: not a
/// trigger's program, nor the test-only touch oracle's read.
const TestingStatements = struct {
    count: u64 = 0,

    fn begin(self: *TestingStatements, database: *c.sqlite3) void {
        _ = c.sqlite3_trace_v2(database, c.SQLITE_TRACE_STMT, traced, self);
    }

    fn end(_: *const TestingStatements, database: *c.sqlite3) void {
        _ = c.sqlite3_trace_v2(database, 0, null, null);
    }

    fn traced(_: c_uint, context: ?*anyopaque, _: ?*anyopaque, text: ?*anyopaque) callconv(.c) c_int {
        const self: *TestingStatements = @ptrCast(@alignCast(context.?));
        const sql = std.mem.span(@as([*:0]const u8, @ptrCast(text.?)));
        if (!std.mem.startsWith(u8, sql, "--") and std.mem.indexOf(u8, sql, "touched_oracle") == null) self.count += 1;
        return 0;
    }
};

test "a Bash binding that is unknown, unattempted or without its revision is stale, and fences nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "stale-bash-config");
    const action = try attemptBashForTesting(&storage, &tmp, session.slice());
    var input: BashExecutionInput = undefined;
    try storage.readBashExecutionInput(action, &input);
    try std.testing.expectEqualStrings(session.slice(), input.session.slice());
    try std.testing.expectEqual(@as(u64, 300_000), input.timeout_ms);

    var unknown = action;
    unknown.action_id += 1000;
    try std.testing.expectError(error.StaleActionAttemptBinding, storage.readBashExecutionInput(unknown, &input));
    // The other Action of the call pair, never attempted: its timeout is NULL.
    var unattempted = action;
    unattempted.action_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT action_id FROM action_operation WHERE session_ref=?1 AND attempt_ordinal=0", .{session.slice()});
    try std.testing.expectError(error.StaleActionAttemptBinding, storage.readBashExecutionInput(unattempted, &input));
    var rebound = action;
    rebound.turn_id += 1000;
    try std.testing.expectError(error.StaleActionAttemptBinding, storage.readBashExecutionInput(rebound, &input));
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    try store_testing.sqlite_only.exec(&storage, "UPDATE action_operation SET permission_revision=999 WHERE session_ref=?1 AND attempt_ordinal=1", .{session.slice()});
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
    try std.testing.expectError(error.StaleActionAttemptBinding, storage.readBashExecutionInput(action, &input));
    try std.testing.expect(!storage.isFenced());
}

test "revoking a sender runs main's statements, with no transaction, and a missing Attempt changes nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "revoke-config");
    const action = try attemptBashForTesting(&storage, &tmp, session.slice());
    const held = "SELECT count(*) FROM action_operation WHERE session_ref=?1 AND sender_handle IS NOT NULL";
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, held, .{session.slice()}));

    // Main: its UPDATE, then its touch's Workspace read. Now: the read, then the UPDATE.
    var statements: TestingStatements = .{};
    statements.begin(storage.sqliteDatabase());
    try storage.revokeActionSender(action);
    statements.end(storage.sqliteDatabase());
    try std.testing.expectEqual(@as(u64, 2), statements.count);
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, held, .{session.slice()}));

    var unknown = action;
    unknown.action_id += 1000;
    const generation = storage.commit_generation.load(.acquire);
    statements = .{};
    statements.begin(storage.sqliteDatabase());
    try storage.revokeActionSender(unknown);
    statements.end(storage.sqliteDatabase());
    try std.testing.expectEqual(@as(u64, 1), statements.count);
    try std.testing.expectEqual(generation, storage.commit_generation.load(.acquire));
    try std.testing.expect(!storage.isFenced());
}

test "rollback failure fences mutation until fresh reopen restores committed facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration(
        "rollback-configure",
        "",
        workspace,
        "model-a",
    );
    const message_file = try tmp.dir.createFile(std.testing.io, "rollback-message", .{ .read = true });
    try message_file.writeStreamingAll(std.testing.io, "committed prefix");
    try message_file.sync(std.testing.io);
    var message = try completeMessage(
        "rollback-message",
        "",
        message_file,
        "committed prefix",
    );
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;

    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        const configured = storage.configure(&configuration, .{});
        try std.testing.expect(configured == .accepted);
        message.session = configured.accepted.session;
        try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
        try std.testing.expectError(
            error.CanonicalRollbackFailed,
            storage.admitNextModelAttempt(.{
                .attempt_before_commit = true,
                .rollback_failure = true,
            }),
        );
        try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
        try std.testing.expect(storage.isFenced());
        try std.testing.expectError(error.StoreFenced, storage.admitNextModelAttempt(.{}));
        var later = try completeConfiguration("rollback-later", "", workspace, "model-a");
        try std.testing.expect(storage.configure(&later, .{}) == .infrastructure_failure);
        try storage.close();
    }

    var binding: AttemptBinding = undefined;
    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        try std.testing.expect((try storage.observeCommand("rollback-configure")).status == .accepted);
        try std.testing.expect(
            (try storage.observeCommand("rollback-message")).message.?.queue.?.state == .queued,
        );
        {
            const partial = try sqlite.prepare(
                storage.sqliteDatabase(),
                "SELECT (SELECT count(*) FROM turn),(SELECT count(*) FROM model_operation)," ++
                    "(SELECT count(*) FROM conversation_entry)",
            );
            defer _ = c.sqlite3_finalize(partial);
            try std.testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(partial));
            try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(partial, 0));
            try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(partial, 1));
            try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(partial, 2));
        }

        var admission = (try storage.admitNextModelAttempt(.{})).?;
        binding = try admission.permit.consume();
        var stale = binding;
        stale.attempt_ordinal += 1;
        try std.testing.expectError(
            error.CanonicalRollbackFailed,
            storage.settleModelAttemptFailure(
                stale,
                .{ .uncorrelated = "must-not-settle" },
                .ordinary,
                .{ .rollback_failure = true },
            ),
        );
        try std.testing.expect(storage.isFenced());
        try std.testing.expectError(
            error.StoreFenced,
            storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "must-not-settle" }, .ordinary, .{}),
        );
        try storage.close();
    }

    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const observation = (try storage.observeCommand("rollback-message")).message.?.queue.?;
        const observed_binding = switch (observation.state) {
            .processing => |value| value,
            else => return error.ExpectedProcessingObservation,
        };
        try std.testing.expectEqual(binding.operation_id, observed_binding.operation_id);
        try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
        try std.testing.expect(
            (try storage.observeCommand("rollback-message")).message.?.queue.?.state == .failed,
        );
    }
}

test "production Store applies finite durable SQLite settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA busy_timeout"));
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA foreign_keys"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA mmap_size"));
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA temp_store"));
    try std.testing.expectEqual(@as(u32, 2), try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA synchronous"));
    try std.testing.expectEqual(@as(u32, 4194304), try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA journal_size_limit"));
    try std.testing.expectEqualStrings("exclusive", (sqlite.diagnosticTextPragma(storage.sqliteDatabase(), "PRAGMA locking_mode") orelse return error.TestUnexpectedResult).slice());
    try std.testing.expectEqual(@as(u32, 4096), try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA page_size"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA trusted_schema"));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_threadsafe());
    try std.testing.expectEqual(@as(i64, sqlite_heap_bytes), c.sqlite3_hard_heap_limit64(-1));
    try std.testing.expectEqual(@as(c_int, 16 * 1024), c.sqlite3_limit(storage.sqliteDatabase(), c.SQLITE_LIMIT_SQL_LENGTH, -1));
    try std.testing.expectEqual(@as(c_int, 65), c.sqlite3_limit(storage.sqliteDatabase(), c.SQLITE_LIMIT_VARIABLE_NUMBER, -1));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_limit(storage.sqliteDatabase(), c.SQLITE_LIMIT_ATTACHED, -1));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_limit(storage.sqliteDatabase(), c.SQLITE_LIMIT_WORKER_THREADS, -1));

    const diagnostic = storage.sqliteDiagnostic();
    try std.testing.expectEqual(@as(?u64, sqlite_heap_bytes), diagnostic.hard_heap_limit_bytes);
    try std.testing.expectEqual(@as(?u64, 4096), diagnostic.page_size_bytes);
    try std.testing.expectEqual(@as(?i64, -1024), diagnostic.cache_size_setting);
    try std.testing.expect(diagnostic.cache_spill_threshold.? > 0);
    try std.testing.expectEqual(@as(?u64, 0), diagnostic.mmap_size_bytes);
    try std.testing.expectEqual(@as(?i64, 2), diagnostic.synchronous);
    try std.testing.expectEqual(@as(?i64, 1), diagnostic.temp_store);
    try std.testing.expectEqual(@as(?u64, 0), diagnostic.busy_timeout_ms);
    try std.testing.expectEqualStrings("wal", diagnostic.journal_mode.?.slice());
    try std.testing.expect(diagnostic.process_memory_current_bytes != null);
    try std.testing.expect(diagnostic.process_memory_highwater_bytes != null);
    try std.testing.expect(diagnostic.cache_used_bytes != null);
    try std.testing.expect(diagnostic.cache_spills != null);
    // Readback alone would only prove configuration. A single SQLite-owned
    // allocation larger than the process-global hard ceiling must be denied
    // by the pinned library while this Store owns the configured limit.
    const over_limit = c.sqlite3_malloc64(sqlite_heap_bytes + 1);
    defer c.sqlite3_free(over_limit);
    try std.testing.expect(over_limit == null);
}

/// Rows in a raw copy's content table, or null when the copy lacks the table.
fn rawContentCount(path: []const u8) !?u64 {
    var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
    var raw: ?*c.sqlite3 = null;
    defer _ = c.sqlite3_close(raw);
    if (c.sqlite3_open(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{path}, 0), &raw) != c.SQLITE_OK) return error.StoreOpenFailed;
    const statement = sqlite.prepare(raw.?, "SELECT count(*) FROM content") catch return null;
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.QueryFailed;
    return @intCast(c.sqlite3_column_int64(statement, 0));
}

test "Store WAL lifecycle at the maximum path: sidecars, lock ownership, crash copy, checkpoint and restore" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const vfs = c.sqlite3_vfs_find(null) orelse return error.SqliteVfsUnavailable;
    try std.testing.expectEqual(@as(c_int, 512), vfs.*.mxPathname);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store_buffer: [protocol.max_store_bytes]u8 = undefined;
    const store_path = try createMaximumCanonicalStore(&tmp, &store_buffer);
    const paths = try platform.resolveClientPaths(io, store_path);
    const database = paths.database.slice();
    try std.testing.expectEqual(@as(usize, platform.max_database_path_bytes), database.len);
    var wal_buffer: [platform.max_database_path_bytes + "-wal".len]u8 = undefined;
    const wal = try std.fmt.bufPrint(&wal_buffer, "{s}-wal", .{database});
    var shm_buffer: [platform.max_database_path_bytes + "-shm".len]u8 = undefined;
    const shm = try std.fmt.bufPrint(&shm_buffer, "{s}-shm", .{database});
    var journal_buffer: [platform.max_database_path_bytes + "-journal".len]u8 = undefined;
    const journal = try std.fmt.bufPrint(&journal_buffer, "{s}-journal", .{database});
    try tmp.dir.createDir(io, "crash", .default_dir);
    try tmp.dir.createDir(io, "database-only", .default_dir);

    var storage: Store = undefined;
    try storage.open(io, database, paths.store.slice());
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;
    try store_testing.sqlite_only.exec(&storage, "INSERT INTO content(digest,byte_length,private,payload) VALUES(randomblob(32),0,0,zeroblob(0))", .{});
    const crash_rows = try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM content", .{});
    try std.testing.expect((try cwd.statFile(io, wal, .{})).size > 0);
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, shm, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, journal, .{}));

    // The open Host excludes every other reader and a second owner.
    {
        var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
        var raw: ?*c.sqlite3 = null;
        defer _ = c.sqlite3_close(raw);
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{database}, 0), &raw, c.SQLITE_OPEN_READONLY, null));
        var statement: ?*c.sqlite3_stmt = null;
        const prepared = c.sqlite3_prepare_v2(raw, "SELECT count(*) FROM content", -1, &statement, null);
        defer _ = c.sqlite3_finalize(statement);
        try std.testing.expect(prepared == c.SQLITE_BUSY or (prepared == c.SQLITE_OK and c.sqlite3_step(statement) == c.SQLITE_BUSY));
    }
    var refused: Store = undefined;
    if (refused.open(io, database, paths.store.slice())) |_| return error.TestUnexpectedResult else |_| {}
    // The failed open released the process-wide heap limit; restore it.
    _ = c.sqlite3_hard_heap_limit64(sqlite_heap_bytes);

    // A process crash leaves exactly these files; the WAL holds the commits.
    try cwd.copyFile(database, tmp.dir, "crash/rui.sqlite3", io, .{});
    try cwd.copyFile(wal, tmp.dir, "crash/rui.sqlite3-wal", io, .{});
    try cwd.copyFile(database, tmp.dir, "database-only/rui.sqlite3", io, .{});

    // A payload past the auto-checkpoint size moves into the database file,
    // and the next commit truncates the reset WAL to the size limit.
    try store_testing.sqlite_only.exec(&storage, "INSERT INTO content(digest,byte_length,private,payload) VALUES(randomblob(32),6291456,0,zeroblob(6291456))", .{});
    try store_testing.sqlite_only.exec(&storage, "INSERT INTO content(digest,byte_length,private,payload) VALUES(randomblob(32),0,0,zeroblob(0))", .{});
    try std.testing.expect((try cwd.statFile(io, database, .{})).size > 6291456);
    try std.testing.expect((try cwd.statFile(io, wal, .{})).size <= 4194304);
    try storage.close();
    storage_open = false;
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, wal, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, shm, .{}));

    // Restoring the complete crash copy at the original path recovers its
    // commits; the database file alone does not.
    try tmp.dir.copyFile("crash/rui.sqlite3", cwd, database, io, .{});
    try tmp.dir.copyFile("crash/rui.sqlite3-wal", cwd, wal, io, .{});
    try storage.open(io, database, paths.store.slice());
    storage_open = true;
    try std.testing.expectEqual(crash_rows, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM content", .{}));
    var database_only_buffer: [protocol.max_store_bytes + 32]u8 = undefined;
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const database_only = try std.fmt.bufPrint(&database_only_buffer, "{s}/database-only/rui.sqlite3", .{root});
    const surviving = try rawContentCount(database_only);
    try std.testing.expect(surviving == null or surviving.? < crash_rows);
}

test "measurement Store can disable cache spill without changing other limits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    var storage: Store = undefined;
    try storage.openWithOptions(
        std.testing.io,
        database,
        root,
        .{ .cache_spill = false },
    );
    defer storage.close() catch unreachable;

    const diagnostic = storage.sqliteDiagnostic();
    try std.testing.expectEqual(@as(?i64, 0), diagnostic.cache_spill_threshold);
    try std.testing.expectEqual(@as(?u64, sqlite_heap_bytes), diagnostic.hard_heap_limit_bytes);
    try std.testing.expectEqual(@as(?i64, -1024), diagnostic.cache_size_setting);
    try std.testing.expectEqual(@as(?i64, 2), diagnostic.synchronous);
    try std.testing.expectEqualStrings("wal", diagnostic.journal_mode.?.slice());
}

test "measurement Store can force a smaller SQLite cache without changing production defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});

    var storage: Store = undefined;
    try storage.openWithOptions(std.testing.io, database, root, .{ .cache_kib = 32 });
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(?i64, -32), storage.sqliteDiagnostic().cache_size_setting);
    var refused: Store = undefined;

    try std.testing.expectError(
        error.InvalidSqliteCacheSize,
        refused.openWithOptions(std.testing.io, database, root, .{ .cache_kib = 0 }),
    );
    try std.testing.expectError(
        error.InvalidSqliteCacheSize,
        refused.openWithOptions(std.testing.io, database, root, .{ .cache_kib = 4097 }),
    );
}

test "fresh Store uses current schema and rejects the prior version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});

    var storage: Store = undefined;
    try storage.open(std.testing.io, database, root);
    try std.testing.expectEqual(schema_version, try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA user_version"));
    {
        const removed_index = try sqlite.prepare(
            storage.sqliteDatabase(),
            "SELECT count(*) FROM sqlite_schema WHERE type='index' AND name='model_operation_runnable'",
        );
        defer _ = c.sqlite3_finalize(removed_index);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(removed_index));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(removed_index, 0));
    }
    {
        // Uncertainty is derived from resolution and retry facts, not stored.
        const stored_uncertainty = try sqlite.prepare(
            storage.sqliteDatabase(),
            "SELECT (SELECT count(*) FROM pragma_table_info('action_operation') WHERE name='uncertain')+" ++
                "(SELECT count(*) FROM pragma_table_info('model_operation') WHERE name='uncertain')",
        );
        defer _ = c.sqlite3_finalize(stored_uncertainty);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stored_uncertainty));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(stored_uncertainty, 0));
    }
    {
        // An Action stores only its authorization; its denial is its Resolution.
        const stored_permission = try sqlite.prepare(
            storage.sqliteDatabase(),
            "SELECT count(*) FROM pragma_table_info('action_operation') WHERE name='permission_state'",
        );
        defer _ = c.sqlite3_finalize(stored_permission);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stored_permission));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(stored_permission, 0));
    }
    try storage.close();
    // Model the prior format's rollback-journal header; rejection must
    // happen before the WAL switch, leaving that Store unmodified.
    {
        var raw: ?*c.sqlite3 = null;
        var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{database}, 0), &raw));
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw.?, "PRAGMA journal_mode=DELETE");
        try sqlite.exec(raw.?, std.fmt.comptimePrint("PRAGMA user_version={d}", .{store_schema.migration_baseline - 1}));
    }
    const before = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, database, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(before);
    try std.testing.expectEqual(@as(u8, 1), before[18]);

    var refused: Store = undefined;

    try std.testing.expectError(
        error.WrongStoreVersion,
        refused.open(std.testing.io, database, root),
    );
    const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, database, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    var wal_buffer: [platform.max_database_path_bytes + "-wal".len]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, try std.fmt.bufPrint(&wal_buffer, "{s}-wal", .{database}), .{}));
}

test "existing Store rejects a format that store_meta does not hold" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    var storage: Store = undefined;
    try storage.open(std.testing.io, database, root);
    try std.testing.expectEqual(@as(u64, schema_version), try store_testing.sqlite_only.queryU64(&storage, "SELECT CAST(meta_value AS INTEGER) FROM store_meta WHERE meta_key='format'", .{}));
    try storage.close();
    const Case = struct { sql: [:0]const u8, refusal: anyerror };
    const cases = [_]Case{
        .{ .sql = std.fmt.comptimePrint("UPDATE store_meta SET meta_value='{d}' WHERE meta_key='format'", .{schema_version - 1}), .refusal = error.WrongStoreVersion },
        .{ .sql = "DELETE FROM store_meta WHERE meta_key='format'", .refusal = error.WrongStoreVersion },
    };
    for (cases) |case| {
        var raw: ?*c.sqlite3 = null;
        var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{database}, 0), &raw));
        try sqlite.exec(raw.?, case.sql);
        _ = c.sqlite3_close(raw);
        const before = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, database, std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(before);
        var refused: Store = undefined;
        try std.testing.expectError(case.refusal, refused.open(std.testing.io, database, root));
        const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, database, std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(after);
        try std.testing.expectEqualSlices(u8, before, after);
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{database}, 0), &raw));
        try sqlite.exec(raw.?, "DELETE FROM store_meta WHERE meta_key='format'");
        try sqlite.exec(raw.?, std.fmt.comptimePrint("INSERT INTO store_meta(meta_key,meta_value) VALUES('format','{d}')", .{schema_version}));
        _ = c.sqlite3_close(raw);
    }
    try storage.open(std.testing.io, database, root);
    try storage.close();
}

/// The Store id store_meta holds in the database at `path`.
fn storeId(path: []const u8) ![2 * store_schema.store_id_bytes]u8 {
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

test "a new Store draws its own Store id, keeps it, and is refused without it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var first_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const first = try std.fmt.bufPrint(&first_buffer, "{s}/first.sqlite3", .{root});
    var second_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const second = try std.fmt.bufPrint(&second_buffer, "{s}/second.sqlite3", .{root});
    var storage: Store = undefined;
    try storage.open(std.testing.io, first, root);
    try storage.close();
    try storage.open(std.testing.io, second, root);
    try storage.close();
    const id = try storeId(first);
    try std.testing.expect(!std.mem.eql(u8, &id, &try storeId(second)));
    try storage.open(std.testing.io, first, root);
    try storage.close();
    try std.testing.expectEqualStrings(&id, &try storeId(first));
    for ([_][:0]const u8{ "UPDATE store_meta SET meta_value=upper(meta_value) WHERE meta_key='store_id'", "DELETE FROM store_meta WHERE meta_key='store_id'" }) |damage| {
        {
            const raw = try openRaw(first);
            defer _ = c.sqlite3_close(raw);
            try sqlite.exec(raw, damage);
        }
        var refused: Store = undefined;
        try std.testing.expectError(error.WrongStoreIdentity, refused.open(std.testing.io, first, root));
    }
}

test "existing Store rejects a table rebuilt without one of its CHECKs, and stays unmodified" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    var storage: Store = undefined;
    try storage.open(std.testing.io, database, root);
    try storage.close();
    const original = comptime for (store_schema.objects(.sqlite)) |object| {
        if (std.mem.eql(u8, object.name, "content")) break object.sql;
    } else unreachable;
    // The same text without its first CHECK clause.
    const unchecked = comptime blk: {
        const start = std.mem.indexOf(u8, original, " CHECK(").?;
        var depth: usize = 0;
        var end = start + " CHECK".len;
        while (true) : (end += 1) {
            if (original[end] == '(') depth += 1;
            if (original[end] == ')') depth -= 1;
            if (depth == 0) break;
        }
        break :blk original[0..start] ++ original[end + 1 ..];
    };
    const Rebuild = struct {
        fn run(path: []const u8, comptime create: []const u8) !void {
            var raw: ?*c.sqlite3 = null;
            var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
            try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{path}, 0), &raw));
            defer _ = c.sqlite3_close(raw);
            try sqlite.exec(raw.?, "PRAGMA foreign_keys=OFF");
            try sqlite.exec(raw.?, "BEGIN; CREATE TEMP TABLE kept AS SELECT * FROM content; DROP TABLE content; " ++
                create ++ "; INSERT INTO content SELECT * FROM kept; DROP TABLE kept; COMMIT");
        }
    };
    // Rebuilt from its own text, the Store still opens.
    try Rebuild.run(database, original);
    try storage.open(std.testing.io, database, root);
    try storage.close();
    try Rebuild.run(database, unchecked);
    const before = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, database, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(before);
    var refused: Store = undefined;
    try std.testing.expectError(error.WrongStoreSchema, refused.open(std.testing.io, database, root));
    const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, database, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

test "a Workspace is matched by its digest and then its text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var root: [protocol.max_store_bytes]u8 = undefined;
    const first_workspace = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    var nested = try tmp.dir.createDirPathOpen(std.testing.io, "other", .{});
    defer nested.close(std.testing.io);
    var other_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const other_workspace = other_buffer[0..try nested.realPath(std.testing.io, &other_buffer)];

    var first_command = try completeConfiguration("digest-first", "", first_workspace, "model");
    const first = storage.configure(&first_command, .{}).accepted.session;
    var sibling_command = try completeConfiguration("digest-sibling", "", first_workspace, "model");
    const sibling = storage.configure(&sibling_command, .{}).accepted.session;
    // A digest collision: the first Workspace's Sessions carry the other's digest.
    {
        var sql: [160]u8 = undefined;
        const forged = std.fmt.bytesToHex(store_core.workspaceDigest(other_workspace), .lower);
        try sqlite.exec(storage.sqliteDatabase(), try std.fmt.bufPrintSentinel(&sql, "UPDATE session SET workspace_digest=x'{s}'", .{&forged}, 0));
    }
    var other_command = try completeConfiguration("digest-other", "", other_workspace, "model");
    const other = storage.configure(&other_command, .{}).accepted.session;

    const first_key = try store_testing.sqlite_only.queryU64(&storage, "SELECT workspace_key FROM session WHERE session_ref=?1", .{first.slice()});
    try std.testing.expectEqual(first_key, try store_testing.sqlite_only.queryU64(&storage, "SELECT workspace_key FROM session WHERE session_ref=?1", .{sibling.slice()}));
    try std.testing.expectEqual(first_key, try store_testing.sqlite_only.queryU64(&storage, "SELECT created_seq FROM session WHERE session_ref=?1", .{first.slice()}));
    const other_key = try store_testing.sqlite_only.queryU64(&storage, "SELECT workspace_key FROM session WHERE session_ref=?1", .{other.slice()});
    try std.testing.expectEqual(other_key, try store_testing.sqlite_only.queryU64(&storage, "SELECT created_seq FROM session WHERE session_ref=?1", .{other.slice()}));
    try std.testing.expect(other_key != first_key);

    var scope: protocol.Bounded(protocol.max_workspace_bytes) = .{};
    try scope.set(other_workspace);
    const listed = try TestingListing.read(&storage, &tmp, .{ .workspace = scope });
    try listed.expectReferences(&.{other.slice()[0..protocol.session_id_bytes].*});
}

test "a reference is checked when its row is written, not at commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "immediate-config");
    try sqlite.exec(storage.sqliteDatabase(), "BEGIN");
    defer sqlite.exec(storage.sqliteDatabase(), "ROLLBACK") catch unreachable;
    const Admission = struct {
        fn insert(database: *c.sqlite3, session_ref: []const u8, command_key: []const u8) !void {
            var sql: [320]u8 = undefined;
            try sqlite.exec(database, try std.fmt.bufPrintSentinel(
                &sql,
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admitted_at) " ++
                    "SELECT 1000,session_ref,'{s}',instructions_content_id,1 FROM session WHERE session_ref='{s}'",
                .{ command_key, session_ref },
                0,
            ));
        }
    };
    try std.testing.expectError(error.SqliteExecFailed, Admission.insert(storage.sqliteDatabase(), session.slice(), "later-command"));
    try store_testing.sqlite_only.exec(&storage, "INSERT INTO core_command(command_key,kind,target,input_digest,accepted,code,revision,created,command_seq) " ++
        "VALUES('later-command',2,'',zeroblob(32),1,'',0,0,(SELECT max(command_seq)+1 FROM core_command))", .{});
    try Admission.insert(storage.sqliteDatabase(), session.slice(), "later-command");
}

test "existing Store rejects noncanonical durable authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});

    var storage: Store = undefined;
    try storage.open(std.testing.io, database, root);
    try sqlite.exec(storage.sqliteDatabase(), "CREATE TABLE tool_result_authority(call_id INTEGER PRIMARY KEY, result_content_id INTEGER NOT NULL)");
    try storage.close();

    var refused: Store = undefined;

    try std.testing.expectError(
        error.WrongStoreSchema,
        refused.open(std.testing.io, database, root),
    );
}

test "canonical observation failure fences later admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("create", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&command, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;

    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET instructions_content_id=9223372036854775807 WHERE session_ref=?1", .{created_session_0.slice()});
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
    try std.testing.expectError(error.CorruptStore, storage.inspectSessionForTesting(created_session_0.slice()));

    var later = try completeConfiguration("later", "", workspace, "model-a");
    try std.testing.expect(storage.configure(&later, .{}) == .infrastructure_failure);
    try std.testing.expectError(error.StoreFenced, storage.observeCommand("later"));
}

test "public content SQL failure fences Store instead of reporting absence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "public-read-config");
    try submitTestMessage(&storage, &tmp, "public-read-text", "public-read-key", session.slice(), "text");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    var request: protocol.ConversationContent = .{ .position = 1 };
    try request.session.set(session.slice());
    const Interrupt = struct {
        fn progress(_: ?*anyopaque) callconv(.c) c_int {
            return 1;
        }
    };
    c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, Interrupt.progress, null);
    defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
    // The shared provenance query is interrupted during preparation, before
    // identity lookup can step. Either phase must retain the public fence.
    try std.testing.expectError(error.StatementPrepareFailed, storage.openPublicConversationContent(&request));
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.openPublicConversationContent(&request));
}

test "public content SQLite step failure fences after successful preparation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "step-config");
    try submitTestMessage(&storage, &tmp, "step-input", "step-key", session.slice(), "step text");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    var request = protocol.ConversationContent{ .position = 1 };
    try request.session.set(session.slice());
    try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&.{ .session = request.session, .position = 999 }));
    try std.testing.expect(!storage.isFenced());
    const Interrupt = struct {
        database: *c.sqlite3,
        interrupted_step: bool = false,

        fn progress(context: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            var statement = c.sqlite3_next_stmt(self.database, null);
            while (statement != null) : (statement = c.sqlite3_next_stmt(self.database, statement)) {
                // Preparation may also invoke progress. Interrupt only a
                // statement that has actually entered sqlite3_step.
                if (c.sqlite3_stmt_busy(statement) != 0) {
                    self.interrupted_step = true;
                    return 1;
                }
            }
            return 0;
        }
    };
    var interrupt = Interrupt{ .database = storage.sqliteDatabase() };
    c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, Interrupt.progress, &interrupt);
    defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
    try std.testing.expectError(error.ConversationReadFailed, storage.openPublicConversationContent(&request));
    try std.testing.expect(interrupt.interrupted_step);
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.openPublicConversationContent(&request));
}

const TestingPublicReadRoute = enum { page, content, cursor };

fn testingOrdinaryPublicCorruption(route: TestingPublicReadRoute, foreign_turn: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "ordinary-config");
    try submitTestMessage(&storage, &tmp, "ordinary-input", "ordinary-key", session.slice(), "public input");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    var request = protocol.ConversationPage{};
    request.session = session;
    const valid = try store_core.publicConversationPageForTesting(&storage, request);
    try std.testing.expectEqual(@as(usize, 1), valid.count);
    try std.testing.expect(valid.items[0].kind == .user);
    if (foreign_turn) {
        const foreign_session = try configureTestSession(&storage, "foreign-config");
        try submitTestMessage(&storage, &tmp, "foreign-input", "foreign-key", foreign_session.slice(), "other input");
        _ = (try storage.admitNextModelAttempt(.{})).?;
        const corrupt = try sqlite.prepare(storage.sqliteDatabase(), "UPDATE conversation_entry SET turn_id=(SELECT turn_id FROM turn WHERE session_ref=?1) WHERE session_ref=?2 AND entry_kind=1");
        defer _ = c.sqlite3_finalize(corrupt);
        try sqlite.bindText(corrupt, 1, foreign_session.slice());
        try sqlite.bindText(corrupt, 2, session.slice());
        try sqlite.expectDone(corrupt);
    } else {
        try store_testing.sqlite_only.exec(&storage, "UPDATE content SET private=1 WHERE content_id=(SELECT content_id FROM conversation_entry WHERE session_ref=?1 AND entry_kind=1)", .{session.slice()});
    }
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
    request.end = valid.end;
    if (route == .cursor) request.before_position = valid.items[0].position;
    const result: anyerror!void = if (route == .content)
        if (storage.openPublicConversationContent(&.{ .session = request.session, .position = valid.items[0].position })) |location| blk: {
            var reader: ContentReader = undefined;
            reader.open(location);
            reader.close();
            break :blk {};
        } else |err| err
    else if (store_core.publicConversationPageForTesting(&storage, request)) |_| {} else |err| err;
    try std.testing.expectError(error.CorruptStore, result);
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, store_core.publicConversationPageForTesting(&storage, request));
    try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
}

test "public ordinary private bytes and cursor fence" {
    try testingOrdinaryPublicCorruption(.content, false);
    try testingOrdinaryPublicCorruption(.cursor, false);
}

test "public ordinary private page fences" {
    try testingOrdinaryPublicCorruption(.page, false);
}

test "public foreign Turn bytes and cursor fence" {
    try testingOrdinaryPublicCorruption(.content, true);
    try testingOrdinaryPublicCorruption(.cursor, true);
}

test "public foreign Turn page fences" {
    try testingOrdinaryPublicCorruption(.page, true);
}

fn testingToolPublicCorruption(route: TestingPublicReadRoute, damage: enum { private, missing, sibling_ordinal, sibling_call_id, sibling_arguments }, target_sibling: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "tool-config");
    try submitTestMessage(&storage, &tmp, "tool-input", "tool-key", session.slice(), "run tool");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "sibling", .name = "other", .encoded_call_id = "sibling-call", .decoded_call_id = "sibling-call", .encoded_arguments = "[]", .decoded_arguments = "[]" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "tool-output", &calls);
    // Damaging the first rejection must leave the requested sibling healthy;
    // identical rejection bytes would deduplicate into one content identity.
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(DISTINCT rejection_content_id) FROM model_tool_call", .{}));
    var request = protocol.ConversationPage{};
    try request.session.set(session.slice());
    const valid = try store_core.publicConversationPageForTesting(&storage, request);
    try std.testing.expectEqual(@as(usize, 3), valid.count);
    const item = valid.items[if (target_sibling) 0 else 1];
    try std.testing.expect(item.kind == .tool_result and item.ordinal == (if (target_sibling) @as(u64, 2) else 1));
    {
        var reader: ContentReader = undefined;
        reader.open(try storage.openPublicConversationContent(&.{ .session = request.session, .position = item.position, .ordinal = item.ordinal }));
        defer reader.close();
        var bytes: [64]u8 = undefined;
        const count = try reader.read(0, &bytes);
        try std.testing.expectEqualStrings(if (target_sibling) "Unknown tool: other." else "Unknown tool: unknown.", bytes[0..count]);
    }
    // Keep counts, acceptance positions and results intact for sibling damage:
    // reading the healthy highest ordinal must validate the entire group.
    switch (damage) {
        .sibling_ordinal => try store_testing.sqlite_only.exec(&storage, "UPDATE model_tool_call SET item_ordinal=item_ordinal+1000 WHERE call_ordinal=0", .{}),
        .sibling_call_id => try store_testing.sqlite_only.exec(&storage, "UPDATE model_tool_call SET call_id_content_id=(SELECT name_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0", .{}),
        .sibling_arguments => try store_testing.sqlite_only.exec(&storage, "UPDATE model_tool_call SET arguments_content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0", .{}),
        .private => try store_testing.sqlite_only.exec(&storage, "UPDATE content SET private=1 WHERE content_id=(SELECT rejection_content_id FROM model_tool_call WHERE call_ordinal=0)", .{}),
        .missing => {
            try store_testing.sqlite_only.withoutForeignKeys(&storage, "DELETE FROM content WHERE content_id=(SELECT rejection_content_id FROM model_tool_call WHERE call_ordinal=0)", .{});
        },
    }
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
    request.end = item.position;
    if (route == .cursor) {
        request.before_position = item.position;
        request.before_ordinal = item.ordinal;
    }
    const result: anyerror!void = if (route == .content)
        if (storage.openPublicConversationContent(&.{ .session = request.session, .position = item.position, .ordinal = item.ordinal })) |location| blk: {
            var reader: ContentReader = undefined;
            reader.open(location);
            reader.close();
            break :blk {};
        } else |err| err
    else if (store_core.publicConversationPageForTesting(&storage, request)) |_| {} else |err| err;
    try std.testing.expectError(error.CorruptStore, result);
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, store_core.publicConversationPageForTesting(&storage, request));
    try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
}

test "public private tool bytes fence" {
    try testingToolPublicCorruption(.content, .private, false);
}

test "public private tool page fences" {
    try testingToolPublicCorruption(.page, .private, false);
}

test "public private tool cursor fences" {
    try testingToolPublicCorruption(.cursor, .private, false);
}

test "public completed tool group with missing exposed content fences" {
    try testingToolPublicCorruption(.page, .missing, false);
    try testingToolPublicCorruption(.content, .missing, false);
    try testingToolPublicCorruption(.cursor, .missing, false);
}

test "public completed tool group with corrupt sibling provenance fences" {
    for ([_]TestingPublicReadRoute{ .page, .cursor, .content }) |route| {
        try testingToolPublicCorruption(route, .sibling_ordinal, true);
        try testingToolPublicCorruption(route, .sibling_call_id, true);
        try testingToolPublicCorruption(route, .sibling_arguments, true);
        try testingToolPublicCorruption(route, .private, true);
        try testingToolPublicCorruption(route, .missing, true);
    }
}

test "public completed Action sibling corruption fences first Conversation read" {
    const faults = [_][:0]const u8{
        "UPDATE model_tool_call SET item_ordinal=item_ordinal+1000 WHERE call_ordinal=0",
        "UPDATE model_tool_call SET call_id_content_id=(SELECT name_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0",
        "UPDATE model_tool_call SET arguments_content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0",
        "UPDATE content SET private=1 WHERE content_id=(SELECT resolution_content_id FROM action_operation WHERE call_ordinal=0)",
        "DELETE FROM content WHERE content_id=(SELECT resolution_content_id FROM action_operation WHERE call_ordinal=0)",
    };
    for (faults) |fault| {
        for ([_]TestingPublicReadRoute{ .page, .cursor, .content }) |route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "message", session.slice(), "two tools");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "output");
            for ([_][]const u8{ "allow-first", "allow-second" }) |key| {
                const action_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT min(action_id) FROM action_operation WHERE resolution_code IS NULL", .{});
                var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
                try allow.key.set(key);
                try allow.session.set(session.slice());
                try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
                const action_binding = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
                _ = try storage.settleActionAttempt(action_binding, .succeeded, key, .{});
            }
            // Obtain only the immutable identity, not a traversal on another
            // public route that could accidentally supply validation authority.
            const position = try store_testing.sqlite_only.queryU64(&storage, "SELECT max(acceptance_position) FROM action_operation", .{});
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
            try sqlite.exec(storage.sqliteDatabase(), fault);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
            var request: protocol.ConversationPage = .{ .end = position };
            try request.session.set(session.slice());
            if (route == .cursor) {
                request.before_position = position;
                request.before_ordinal = 2;
            }
            const result: anyerror!void = if (route == .content)
                if (storage.openPublicConversationContent(&.{ .session = request.session, .position = position, .ordinal = 2 })) |value| blk: {
                    var reader: ContentReader = undefined;
                    reader.open(value);
                    reader.close();
                    break :blk {};
                } else |err| err
            else if (store_core.publicConversationPageForTesting(&storage, request)) |_| {} else |err| err;
            try std.testing.expectError(error.CorruptStore, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, store_core.publicConversationPageForTesting(&storage, request));
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
        }
    }
}

test "replay fences part damage that keeps every digest" {
    for ([_][:0]const u8{
        "DELETE FROM model_output_part WHERE part_ordinal=1",
        "UPDATE model_output_item SET part_count=part_count+1 WHERE item_kind=2",
        "UPDATE model_output_part SET part_array=2,part_kind=3,text_length=NULL,text_content_id=extras_content_id WHERE part_ordinal=0",
        // The text parts must cover the message text in order, exactly.
        "UPDATE model_output_part SET text_length=text_length+1 WHERE part_ordinal=0",
        "UPDATE model_output_part SET text_length=text_length-1 WHERE part_ordinal=1",
        // The text keeps its digest while its bytes change: the parts'
        // reads check it across both ranges.
        "UPDATE content SET payload=CAST('onetwx' AS BLOB) WHERE payload=CAST('onetwo' AS BLOB)",
    }) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "part-damage-config");
        const answer = [_]TestingAnswerPart{ .{ .encoded = "one", .decoded = "one" }, .{ .encoded = "two", .decoded = "two" } };
        try answerTestTurn(&storage, &tmp, session.slice(), "part-damage", &answer);
        try submitTestMessage(&storage, &tmp, "part-damage-next", "part-damage-next", session.slice(), "next");
        const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try sqlite.exec(storage.sqliteDatabase(), fault);
        var view: HistoricalView = undefined;
        try storage.openHistoricalView(next, &view);
        defer view.close();
        var cursor: TestingHistoryCursor = .{};
        var bytes: [512]u8 = undefined;
        while (try cursor.next(&view)) |entry| {
            if (entry.kind != .provider_output) continue;
            try std.testing.expectError(error.CorruptStore, renderTestingEntry(&view, entry, &bytes));
            break;
        } else return error.MissingCorruptionFailure;
        try std.testing.expect(storage.isFenced());
    }
}

test "a message's text is stored once and its parts replay as lengths of it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "text-once-config");
    const answer = [_]TestingAnswerPart{ .{ .encoded = "one ", .decoded = "one " }, .{ .encoded = "", .decoded = "" }, .{ .encoded = "tw\\u00f6", .decoded = "tw\u{f6}" } };
    try answerTestTurn(&storage, &tmp, session.slice(), "text-once", &answer);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM content WHERE payload=CAST('one tw\u{f6}' AS BLOB) AND private=0", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM content WHERE payload IN (CAST('one ' AS BLOB),CAST('tw\u{f6}' AS BLOB))", .{}));
    try std.testing.expectEqual(@as(u64, 3), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_output_part WHERE text_content_id IS NULL", .{}));
    try std.testing.expectEqual(@as(u64, 4 + 0 + 4), try store_testing.sqlite_only.queryU64(&storage, "SELECT sum(text_length) FROM model_output_part", .{}));
    try std.testing.expectEqual(try store_testing.sqlite_only.queryU64(&storage, "SELECT content_id FROM conversation_entry WHERE entry_kind=3", .{}), try store_testing.sqlite_only.queryU64(&storage, "SELECT message_content_id FROM model_output_item WHERE item_kind=2", .{}));
    // Each part kind holds exactly its text shape, and a message names its text.
    for ([_]struct { ConstraintProbe, [:0]const u8 }{
        .{ .check_violation, "UPDATE model_output_part SET text_length=NULL WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_part SET text_content_id=extras_content_id WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_part SET text_length=-1 WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_part SET part_kind=0 WHERE part_ordinal=0" },
        .{ .accepted, "UPDATE model_output_part SET part_kind=0,text_length=NULL WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_part SET part_kind=3,part_array=2,text_length=NULL WHERE part_ordinal=0" },
        .{ .accepted, "UPDATE model_output_part SET part_kind=3,part_array=2,text_length=NULL,text_content_id=extras_content_id WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_part SET part_kind=4,text_content_id=extras_content_id WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_item SET message_content_id=NULL WHERE item_kind=2" },
        .{ .check_violation, "UPDATE model_output_item SET item_kind=1,phase=0 WHERE item_kind=2" },
    }) |case| try std.testing.expectEqual(case[0], try probeConstraint(storage.sqliteDatabase(), case[1]));
    try submitTestMessage(&storage, &tmp, "text-once-next", "text-once-next", session.slice(), "next");
    const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var view: HistoricalView = undefined;
    try storage.openHistoricalView(next, &view);
    defer view.close();
    var cursor: TestingHistoryCursor = .{};
    var bytes: [512]u8 = undefined;
    while (try cursor.next(&view)) |entry| {
        if (entry.kind != .provider_output) continue;
        try std.testing.expectEqualStrings("message{\"id\":\"m\"}|content.output_text=one |content.output_text=|content.output_text=tw\u{f6}", try renderTestingEntry(&view, entry, &bytes));
        break;
    } else return error.MissingMessage;
    try std.testing.expect(!storage.isFenced());
}

test "a large message's parts read only their own ranges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "large-parts-config");
    // Many small parts before one large one: each small part's reader must
    // not read ahead into the rest of the text.
    const large = try std.testing.allocator.alloc(u8, 1024 * 1024 + 4096);
    defer std.testing.allocator.free(large);
    @memset(large, 'a');
    var answer: [65]TestingAnswerPart = undefined;
    for (answer[0..64]) |*part| part.* = .{ .encoded = "x", .decoded = "x" };
    answer[64] = .{ .encoded = large, .decoded = large };
    try answerTestTurn(&storage, &tmp, session.slice(), "large-parts", &answer);
    try submitTestMessage(&storage, &tmp, "large-parts-next", "large-parts-next", session.slice(), "next");
    const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var view: HistoricalView = undefined;
    try storage.openHistoricalView(next, &view);
    defer view.close();
    var cursor: TestingHistoryCursor = .{};
    while (try cursor.next(&view)) |entry| {
        if (entry.kind != .provider_output) continue;
        _ = try view.openOutput(entry.position);
        const before = storage.testing_content_work.blob.load(.monotonic);
        var window: [4096]u8 = undefined;
        var text_bytes: u64 = 0;
        while (try view.nextOutputPart()) |part| {
            const text = part.text orelse continue;
            var reader: HistoricalReader = undefined;
            try view.openContent(text, &reader);
            defer reader.close();
            var offset: u64 = 0;
            while (true) {
                const count = try reader.read(offset, &window);
                if (count == 0) break;
                offset += count;
            }
            text_bytes += offset;
        }
        try std.testing.expectEqual(@as(u64, 64 + large.len), text_bytes);
        try std.testing.expectEqual(text_bytes, storage.testing_content_work.blob.load(.monotonic) - before);
        break;
    } else return error.MissingMessage;
    try std.testing.expect(!storage.isFenced());
}

test "a warm Turn prepares no statement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "warm-config");
    const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
    try answerTestTurn(&storage, &tmp, session.slice(), "cold", &answer);
    try answerTestTurn(&storage, &tmp, session.slice(), "warming", &answer);
    const Steps = struct {
        cache: *const StatementCache,
        uncached: usize = 0,

        fn traced(mask: c_uint, context: ?*anyopaque, statement: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            std.debug.assert(mask == c.SQLITE_TRACE_STMT);
            const self: *@This() = @ptrCast(@alignCast(context.?));
            for (self.cache.slots) |slot| {
                if (slot.statement == @as(?*c.sqlite3_stmt, @ptrCast(statement))) return 0;
            }
            self.uncached += 1;
            return 0;
        }
    };
    var steps = Steps{ .cache = &storage.engine.sqlite.statements };
    const prepared = storage.engine.sqlite.statements.count;
    _ = c.sqlite3_trace_v2(storage.sqliteDatabase(), c.SQLITE_TRACE_STMT, Steps.traced, &steps);
    defer _ = c.sqlite3_trace_v2(storage.sqliteDatabase(), 0, null, null);
    try answerTestTurn(&storage, &tmp, session.slice(), "warm", &answer);
    try std.testing.expectEqual(@as(usize, 0), steps.uncached);
    try std.testing.expectEqual(prepared, storage.engine.sqlite.statements.count);
}

test "public assistant message provenance binds the exact accepted item" {
    const faults = [_][:0]const u8{
        "DELETE FROM conversation_entry WHERE entry_kind=3",
        "UPDATE conversation_entry SET source_item_ordinal=source_item_ordinal+1 WHERE entry_kind=3",
        "UPDATE conversation_entry SET content_id=(SELECT content_id FROM conversation_entry WHERE entry_kind=1) WHERE entry_kind=3",
        "UPDATE model_output_item SET message_content_id=(SELECT content_id FROM conversation_entry WHERE entry_kind=1) WHERE item_kind=2",
        "UPDATE model_output_item SET attempt_ordinal=attempt_ordinal+1 WHERE item_kind=2",
        "UPDATE content SET private=1 WHERE content_id=(SELECT message_content_id FROM model_output_item WHERE item_kind=2)",
    };
    for (faults) |fault| {
        for ([_]enum { page, bytes, activity, activity_bytes, full }{ .page, .bytes, .activity, .activity_bytes, .full }) |route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const request = try testingPublicProjection(&storage, &tmp, &.{.{ .encoded = "visible", .decoded = "visible" }});
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
            try sqlite.exec(storage.sqliteDatabase(), fault);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
            try storage.close();
            try testingStore(&storage, &tmp, std.testing.io);
            const result: anyerror!void = switch (route) {
                .page => if (store_core.publicConversationPageForTesting(&storage, .{ .session = request.session })) |_| {} else |err| err,
                .bytes => if (storage.openPublicConversationContent(&request)) |location| blk: {
                    var owned: ContentReader = undefined;
                    owned.open(location);
                    owned.close();
                    break :blk {};
                } else |err| err,
                .activity => if (store_core.activityPageForTesting(&storage, .{ .session = request.session })) |_| {} else |err| err,
                .activity_bytes => if (storage.openActivityContent(&.{ .session = request.session, .position = request.position })) |location| blk: {
                    var owned: ContentReader = undefined;
                    owned.open(location);
                    owned.close();
                    break :blk {};
                } else |err| err,
                .full => if (testingSessionReportWithProfile(&storage, &tmp, request.session.slice(), 1024 * 1024, .full)) |report| blk: {
                    std.testing.allocator.free(report);
                    break :blk {};
                } else |err| err,
            };
            try std.testing.expectError(error.CorruptStore, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
        }
    }
}

test "missing assistant certificates respect page windows and fixed ends" {
    for ([_]bool{ false, true }) |activity| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const missing = try testingPublicProjection(&storage, &tmp, &.{.{ .encoded = "answer", .decoded = "answer" }});
        for (0..20) |index| {
            var key_buffer: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buffer, "later-{d}", .{index});
            try submitTestMessage(&storage, &tmp, key, key, missing.session.slice(), "later user input");
        }
        _ = (try storage.admitNextModelAttempt(.{})).?;
        try store_testing.sqlite_only.exec(&storage, "DELETE FROM conversation_entry WHERE entry_kind=3", .{});
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
        try storage.close();
        try testingStore(&storage, &tmp, std.testing.io);
        // A historical window ending before the damage remains readable.
        _ = try store_core.publicConversationPageForTesting(&storage, .{ .session = missing.session, .end = missing.position - 1 });
        _ = try store_core.activityPageForTesting(&storage, .{ .session = missing.session, .end = missing.position - 1 });
        if (activity) {
            const latest = try store_core.activityPageForTesting(&storage, .{ .session = missing.session, .direction = .backward });
            try std.testing.expect(latest.more);
            var cursor = latest.items[latest.count - 1];
            while (true) {
                const older = store_core.activityPageForTesting(&storage, .{
                    .session = missing.session,
                    .end = latest.end,
                    .direction = .backward,
                    .position = cursor.position,
                    .ordinal = cursor.ordinal,
                }) catch |err| {
                    try std.testing.expectEqual(error.CorruptStore, err);
                    break;
                };
                try std.testing.expect(older.more);
                try std.testing.expect(older.items[older.count - 1].position < cursor.position);
                cursor = older.items[older.count - 1];
            }
        } else {
            const latest = try store_core.publicConversationPageForTesting(&storage, .{ .session = missing.session });
            try std.testing.expectEqual(@as(usize, 16), latest.count);
            try std.testing.expect(latest.more);
            try std.testing.expectError(error.CorruptStore, store_core.publicConversationPageForTesting(&storage, .{
                .session = missing.session,
                .end = latest.end,
                .before_position = latest.items[latest.count - 1].position,
                .before_ordinal = latest.items[latest.count - 1].ordinal,
            }));
        }
        try std.testing.expect(storage.isFenced());
    }
}

test "one committed selection freezes its settings and input prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&configuration, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;

    const first_file = try tmp.dir.createFile(std.testing.io, "dispatch-first", .{ .read = true });
    try first_file.writeStreamingAll(std.testing.io, "first");
    try first_file.sync(std.testing.io);
    var first = try completeMessage("dispatch-1", created_session_0.slice(), first_file, "first");
    defer first.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&first, null, .{}) == .accepted);

    const second_file = try tmp.dir.createFile(std.testing.io, "dispatch-second", .{ .read = true });
    try second_file.writeStreamingAll(std.testing.io, "second");
    try second_file.sync(std.testing.io);
    var second = try completeMessage("dispatch-2", created_session_0.slice(), second_file, "second");
    defer second.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&second, null, .{}) == .accepted);

    var instructions_update: protocol.ConfigureCommand = .{};
    try instructions_update.key.set("instructions-before-selection");
    try instructions_update.session.set(created_session_0.slice());
    instructions_update.configuration.instructions = try testingContent(&tmp, "instructions-before", 'b', 1);
    defer instructions_update.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&instructions_update, .{}) == .accepted);

    try std.testing.expectError(
        error.InjectedAttemptCommitFailure,
        storage.admitNextModelAttempt(.{ .attempt_before_commit = true }),
    );
    try std.testing.expectError(error.StoreFenced, storage.observeCommand("dispatch-1"));
    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
    try std.testing.expect(
        (try storage.observeCommand("dispatch-1")).message.?.queue.?.state == .queued,
    );

    // Failed admission publishes neither projection nor instruction
    // inclusion; the revision's change row holds position 3.
    try std.testing.expectEqual(@as(i64, 0), try sqlite.pragmaInt(storage.sqliteDatabase(), "SELECT count(*) FROM conversation_entry"));
    try std.testing.expectEqual(@as(i64, 4), try sqlite.pragmaInt(storage.sqliteDatabase(), "SELECT next_position FROM session"));

    var admitted = (try storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted.permit.consume();
    try std.testing.expectError(error.DispatchPermitConsumed, admitted.permit.consume());
    const first_observation = (try storage.observeCommand("dispatch-1")).message.?.queue.?;
    const second_observation = (try storage.observeCommand("dispatch-2")).message.?.queue.?;
    try std.testing.expectEqual(protocol.MessageProgressStatus.in_flight, (try storage.observeCommand("dispatch-1")).message.?.progress.?.status);
    try std.testing.expectEqual(protocol.MessageProgressStatus.in_flight, (try storage.observeCommand("dispatch-2")).message.?.progress.?.status);
    const first_binding = switch (first_observation.state) {
        .processing => |value| value,
        else => return error.ExpectedProcessingObservation,
    };
    const second_binding = switch (second_observation.state) {
        .processing => |value| value,
        else => return error.ExpectedProcessingObservation,
    };
    try std.testing.expectEqual(binding.turn_id, first_binding.turn_id);
    try std.testing.expectEqual(binding.turn_id, second_binding.turn_id);
    try std.testing.expectEqual(binding.operation_id, first_binding.operation_id);
    try std.testing.expectEqual(binding.operation_id, second_binding.operation_id);

    const third_file = try tmp.dir.createFile(std.testing.io, "dispatch-third", .{ .read = true });
    try third_file.writeStreamingAll(std.testing.io, "later");
    try third_file.sync(std.testing.io);
    var third = try completeMessage("dispatch-3", created_session_0.slice(), third_file, "later");
    defer third.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&third, null, .{}) == .accepted);
    var update: protocol.ConfigureCommand = .{};
    try update.key.set("configure-later");
    try update.session.set(created_session_0.slice());
    update.configuration.model.state = .value;
    try update.configuration.model.value.set("model-b");
    const active_update = storage.configure(&update, .{});
    try std.testing.expect(active_update == .rejected);
    try std.testing.expectEqual(
        protocol.ConfigurationRejection.model_is_immutable,
        active_update.rejected.code,
    );
    try expectBindingPreserved(&storage, created_session_0.slice(), "during-work");

    var view: HistoricalView = undefined;
    try storage.openHistoricalView(binding, &view);
    defer if (view.active) view.close();
    var settings: HistoricalSettings = undefined;
    try view.settings(&settings);
    try std.testing.expectEqual(protocol.Provider.codex, settings.provider);
    try std.testing.expectEqualStrings("model-a", settings.model.slice());
    // The frozen tools come back as the Store saved them, in set order.
    const offered = tool_catalog.Offered.ofMask(configuration_domain.default_tools_mask);
    try std.testing.expectEqual(@as(u64, offered.len), settings.tool_count);
    var tool: historical_domain.HistoricalTool = .{};
    for (offered.slice()) |expected| {
        try std.testing.expect(try view.nextTool(&tool));
        try std.testing.expectEqualStrings(expected.name, tool.name.slice());
        try std.testing.expectEqual(expected.owner, tool.owner);
        try std.testing.expectEqual(@as(u64, expected.description.len), tool.description.length);
    }
    try std.testing.expect(!try view.nextTool(&tool));
    const first_input = (try view.nextEntry(0)).?;
    const second_input = (try view.nextEntry(first_input.position)).?;
    const instruction = (try view.nextEntry(second_input.position)).?;
    try std.testing.expect(instruction.kind == .instruction);
    try std.testing.expect((try view.nextEntry(instruction.position)) == null);
    var first_reader: HistoricalReader = undefined;
    try view.openContent(first_input.content.?, &first_reader);
    defer if (first_reader.active) first_reader.close();
    var actual: [5]u8 = undefined;
    try std.testing.expectEqual(actual.len, try first_reader.read(0, &actual));
    try std.testing.expectEqualStrings("first", &actual);

    var foreign_view: HistoricalView = undefined;
    try storage.openHistoricalView(binding, &foreign_view);
    try std.testing.expect(first_input.content.?.belongsTo(&view));
    try std.testing.expect(!first_input.content.?.belongsTo(&foreign_view));
    foreign_view.close();
    try std.testing.expectEqual(@as(usize, 1), view.readers);
    first_reader.close();
    try std.testing.expectEqual(@as(usize, 0), view.readers);
    view.close();
    try std.testing.expect(!first_input.content.?.belongsTo(&view));
    try std.testing.expect(!first_reader.usable());

    try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
    try expectActivityOutcome(&storage, created_session_0.slice(), binding, .provider_refused, "provider_http_422");
    const failed = (try storage.observeCommand("dispatch-1")).message.?.queue.?;
    const failure = switch (failed.state) {
        .failed => |value| value,
        else => return error.ExpectedFailedObservation,
    };
    try std.testing.expectEqualStrings("provider_http_422", failure.code.slice());
    try std.testing.expect(
        (try storage.observeCommand("dispatch-3")).message.?.queue.?.state == .queued,
    );
    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(created_session_0.slice())).pending_messages);

    try update.key.set("configure-after-failure");
    const failed_update = storage.configure(&update, .{});
    try std.testing.expect(failed_update == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.model_is_immutable, failed_update.rejected.code);
    try expectBindingPreserved(&storage, created_session_0.slice(), "after-failure");

    var tools_update: protocol.ConfigureCommand = .{};
    try tools_update.key.set("tools-after-failure");
    try tools_update.session.set(created_session_0.slice());
    tools_update.configuration.tools.state = .value;
    tools_update.configuration.tools.count = 0;
    try std.testing.expect(storage.configure(&tools_update, .{}) == .accepted);

    const later = (try storage.admitNextModelAttempt(.{})).?;
    var later_view: HistoricalView = undefined;
    try storage.openHistoricalView(later.permit.binding, &later_view);
    defer later_view.close();
    var later_settings: HistoricalSettings = undefined;
    try later_view.settings(&later_settings);
    try std.testing.expectEqual(protocol.Provider.codex, later_settings.provider);
    try std.testing.expectEqualStrings("model-a", later_settings.model.slice());
    try std.testing.expectEqual(@as(u64, 0), later_settings.tool_count);
    var position: u64 = 0;
    // The failed first Operation keeps its boundary between the inputs.
    for ([_]HistoricalEntryKind{ .user, .user, .instruction, .operation, .user }) |kind| {
        const entry = (try later_view.nextEntry(position)).?;
        try std.testing.expectEqual(kind, entry.kind);
        position = entry.position;
    }
    try std.testing.expect((try later_view.nextEntry(position)) == null);
}

test "continued accepted output keeps model immutable and public text readable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration(
        "continued-config",
        "",
        workspace,
        "model-a",
    );
    const created_session_0_reply = storage.configure(&configuration, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;

    const first_file = try tmp.dir.createFile(std.testing.io, "continued-first", .{ .read = true });
    try first_file.writeStreamingAll(std.testing.io, "first");
    try first_file.sync(std.testing.io);
    var first = try completeMessage(
        "continued-first",
        created_session_0.slice(),
        first_file,
        "first",
    );
    defer first.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&first, null, .{}) == .accepted);
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

    const second_file = try tmp.dir.createFile(std.testing.io, "continued-second", .{ .read = true });
    try second_file.writeStreamingAll(std.testing.io, "second");
    try second_file.sync(std.testing.io);
    var second = try completeMessage(
        "continued-second",
        created_session_0.slice(),
        second_file,
        "second",
    );
    defer second.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&second, null, .{}) == .accepted);

    const source_bytes = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}";
    const source = try tmp.dir.createFile(std.testing.io, "continued-output", .{ .read = true });
    defer source.close(std.testing.io);
    try source.writeStreamingAll(std.testing.io, source_bytes);
    try source.sync(std.testing.io);
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var metadata_used: std.atomic.Value(u64) = .init(0);
    var retained_metadata: ?named_scratch.Owner = null;
    var metadata = try OutputMetadataWriter.init(
        std.testing.io,
        root_buffer[0..root_length],
        "continued-metadata",
        .{ .used = &metadata_used, .limit = 1_024 },
        false,
        &retained_metadata,
    );
    defer metadata.deinit();
    try std.testing.expect(retained_metadata == null);
    _ = try output_decode.recordItemForTesting(&metadata, source, 0, source_bytes.len, 0, .assistant_response);
    try metadata.sealForRead();
    const output = ValidatedOutput{
        .source = source,
        .source_length = source_bytes.len,
        .metadata = metadata.file,
        .item_count = 1,
        .call_count = 0,
        .answer_item_ordinal = 0,
        .answer_length = "answer".len,
        .answer_digest = protocol.contentDigest("answer"),
        .response_id = .{},
        .model_evidence = testing_absent_model_evidence,
        .request_id = .{},
    };
    try storage.settleModelSuccess(binding, &output, .{});
    var public_request = protocol.ConversationPage{};
    try public_request.session.set(created_session_0.slice());
    const public_page = try store_core.publicConversationPageForTesting(&storage, public_request);
    try std.testing.expectEqual(@as(usize, 2), public_page.count);
    try std.testing.expect(public_page.items[0].kind == .assistant);
    var public_reader: ContentReader = undefined;
    public_reader.open(try storage.openPublicConversationContent(&.{ .session = public_request.session, .position = public_page.items[0].position }));
    {
        // The answer is the message's public text row; its bag is private.
        const backing = try sqlite.prepare(storage.sqliteDatabase(), "SELECT text.private,bag.private FROM model_output_item item " ++
            "JOIN content text ON text.content_id=item.message_content_id " ++
            "JOIN content bag ON bag.content_id=item.extras_content_id WHERE item.message_content_id=?1");
        defer _ = c.sqlite3_finalize(backing);
        try sqlite.bindI64(backing, 1, public_reader.content_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(backing));
        try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_column_int(backing, 0));
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(backing, 1));
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(backing));
    }
    var decoded: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try public_reader.read(0, &decoded));
    try std.testing.expectEqualStrings("answer", &decoded);
    public_reader.close();
    const before_answer = try store_core.publicConversationPageForTesting(&storage, .{
        .session = public_request.session,
        .end = public_page.end,
        .before_position = public_page.items[0].position,
    });
    try std.testing.expectEqual(@as(usize, 1), before_answer.count);
    try std.testing.expect(before_answer.items[0].kind == .user);
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
    {
        const resolution = try sqlite.prepare(
            storage.sqliteDatabase(),
            "SELECT resolution_code FROM model_operation WHERE operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(resolution);
        try sqlite.bindU64(resolution, 1, binding.operation_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(resolution));
        var code: protocol.Bounded(protocol.max_code_bytes) = .{};
        try sqlite.readText(resolution, 0, &code);
        try std.testing.expectEqualStrings("answer", code.slice());
    }

    var update: protocol.ConfigureCommand = .{};
    try update.key.set("continued-model-change");
    try update.session.set(created_session_0.slice());
    update.configuration.model.state = .value;
    try update.configuration.model.value.set("model-b");
    const rejected = storage.configure(&update, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(
        protocol.ConfigurationRejection.model_is_immutable,
        rejected.rejected.code,
    );

    const completion_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelSuccess(completion_binding, &output, .{});
    // The same output is an answer both before and after pending input is
    // consumed. Only the owning Turn's completion decision differs.
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_code='answer'", .{}));
    try expectBindingPreserved(&storage, created_session_0.slice(), "after-output");
    const completed = (try storage.observeCommand("continued-first")).message.?.queue.?;
    const completion = switch (completed.state) {
        .completed => |value| value,
        else => return error.ExpectedCompletedObservation,
    };
    try std.testing.expectEqual(completion_binding, completion.binding);
    try std.testing.expectEqual(@as(u64, "answer".len), completion.answer.length);
    try std.testing.expectEqualSlices(
        u8,
        &protocol.contentDigest("answer"),
        &completion.answer.digest,
    );
}

test "failed model settlement recovers uncertainty with a fresh consumed Attempt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "", workspace, "model-a");
    var created_session_0: protocol.Bounded(protocol.max_session_bytes) = undefined;

    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        const created_session_0_reply = storage.configure(&configuration, .{});
        try std.testing.expect(created_session_0_reply == .accepted);
        created_session_0 = created_session_0_reply.accepted.session;
        const message_file = try tmp.dir.createFile(std.testing.io, "failure-message", .{ .read = true });
        try message_file.writeStreamingAll(std.testing.io, "fail");
        try message_file.sync(std.testing.io);
        var message = try completeMessage("failure-message", created_session_0.slice(), message_file, "fail");
        defer message.removeTemporaryContent(std.testing.io) catch unreachable;
        try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try std.testing.expectError(
            error.InjectedCommitFailure,
            storage.settleModelAttemptFailure(
                binding,
                .{ .uncorrelated = "request_preparation_failed" },
                .ordinary,
                .{ .before_commit = true },
            ),
        );
        try storage.close();
    }
    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const observation = (try storage.observeCommand("failure-message")).message.?.queue.?;
        const observed_binding = switch (observation.state) {
            .processing => |value| value,
            else => return error.ExpectedProcessingObservation,
        };
        try std.testing.expectEqual(@as(u64, 1), observed_binding.attempt_ordinal);
        var replacement = (try admitRetryForTesting(&storage)).?;
        const replacement_binding = try replacement.permit.consume();
        try std.testing.expectEqual(@as(u64, 2), replacement_binding.attempt_ordinal);
        try std.testing.expectEqual(
            replacement_binding.operation_id,
            observed_binding.operation_id,
        );
        const recovered = (try storage.observeCommand("failure-message")).message.?.queue.?;
        const recovered_binding = switch (recovered.state) {
            .processing => |value| value,
            else => return error.ExpectedProcessingObservation,
        };
        try std.testing.expectEqual(@as(u64, 2), recovered_binding.attempt_ordinal);

        {
            const force_exhausted = try sqlite.prepare(
                storage.sqliteDatabase(),
                "UPDATE model_operation SET attempt_ordinal=4 WHERE operation_id=?1",
            );
            defer _ = c.sqlite3_finalize(force_exhausted);
            try sqlite.bindU64(force_exhausted, 1, replacement_binding.operation_id);
            try sqlite.expectDone(force_exhausted);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
        }

        const Active = struct {
            fn contains(context: *const anyopaque, operation_id: u64) bool {
                const expected: *const u64 = @ptrCast(@alignCast(context));
                return operation_id == expected.*;
            }
        };
        const active_operation = replacement_binding.operation_id;
        try std.testing.expect(!try storage.recoverOneExhaustedModelAttempt(.{
            .context = &active_operation,
            .containsFn = Active.contains,
            .maximum_exclusions = 1,
        }));
        try std.testing.expect(
            try storage.recoverOneExhaustedModelAttempt(ActiveOperationFilter.empty()),
        );
        const exhausted = (try storage.observeCommand("failure-message")).message.?.queue.?;
        const failure = switch (exhausted.state) {
            .failed => |value| value,
            else => return error.ExpectedFailedObservation,
        };
        try std.testing.expectEqualStrings("retry_exhausted", failure.code.slice());
        try expectActivityOutcome(&storage, created_session_0.slice(), replacement_binding, .provider_unavailable, "retry_exhausted");
    }
}

test "HTTP status failures keep the settling Attempt's provider correlation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "correlation-config");
    try submitTestMessage(&storage, &tmp, "correlation-input", "correlation-message", session.slice(), "retry");
    var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const request_ids = [_][]const u8{ "attempt-1", "", "attempt-3", "attempt-\"4\"" };
    for (request_ids, 1..) |request_id, ordinal| {
        try std.testing.expectEqual(@as(u64, ordinal), binding.attempt_ordinal);
        var failure: ModelFailure = .{ .correlated = .{ .code = "provider_temporary_http_503", .request_id = .{}, .report = "" } };
        try failure.correlated.request_id.set(request_id);
        try storage.settleModelAttemptFailure(binding, failure, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
        var resolution: protocol.Bounded(protocol.max_code_bytes) = .{};
        var recorded: protocol.Bounded(256) = .{};
        {
            const statement = try sqlite.prepare(storage.sqliteDatabase(), "SELECT coalesce(resolution_code,''),coalesce(request_id,'') FROM model_operation WHERE operation_id=?1");
            defer _ = c.sqlite3_finalize(statement);
            try sqlite.bindU64(statement, 1, binding.operation_id);
            try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
            try sqlite.readText(statement, 0, &resolution);
            try sqlite.readText(statement, 1, &recorded);
        }
        if (ordinal < request_ids.len) {
            // A scheduled retry has not settled the Operation; the next
            // Attempt's answer will.
            try std.testing.expectEqualStrings("", resolution.slice());
            try std.testing.expectEqualStrings("", recorded.slice());
            try store_testing.sqlite_only.exec(&storage, "UPDATE model_operation SET retry_due_at_ms=1 WHERE retry_due_at_ms IS NOT NULL", .{});
            binding = (try admitRetryForTesting(&storage)).?.permit.binding;
        } else {
            try std.testing.expectEqualStrings("retry_exhausted", resolution.slice());
            try std.testing.expectEqualStrings(request_id, recorded.slice());
        }
    }

    // An ordinary HTTP failure retains the source bytes too, not a slice of
    // a copied union payload which expires before the SQLite step.
    try submitTestMessage(&storage, &tmp, "correlated-input", "correlated-message", session.slice(), "fail with correlation");
    const correlated = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var ordinary: ModelFailure = .{ .correlated = .{ .code = "provider_http_403", .request_id = .{}, .report = "" } };
    try ordinary.correlated.request_id.set("terminal-\"request\"-é");
    try storage.settleModelAttemptFailure(correlated, ordinary, .ordinary, .{});
    {
        const statement = try sqlite.prepare(storage.sqliteDatabase(), "SELECT request_id FROM model_operation WHERE operation_id=?1");
        defer _ = c.sqlite3_finalize(statement);
        try sqlite.bindU64(statement, 1, correlated.operation_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
        var recorded: protocol.Bounded(256) = .{};
        try sqlite.readText(statement, 0, &recorded);
        try std.testing.expectEqualStrings("terminal-\"request\"-é", recorded.slice());
    }

    // A provider answer without correlation records none.
    try submitTestMessage(&storage, &tmp, "uncorrelated-input", "uncorrelated-message", session.slice(), "fail");
    const terminal = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(terminal, .{ .correlated = .{ .code = "provider_http_401", .request_id = .{}, .report = "" } }, .ordinary, .{});
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE request_id IS NULL AND resolution_code='provider_http_401'", .{}));
}

test "a refresh claim whose UPDATE changes no row answers false and does not fence, as on main" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "claim-race-config");
    try submitTestMessage(&storage, &tmp, "claim-race-input", "claim-race-message", session.slice(), "work");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    // Claims between the read round and the write, so the guarded UPDATE finds no row.
    const Interposed = struct {
        const Inner = store_access.Access(.write, store_core.Ordinary.attempt_binding || error{AuthRefreshUnclaimed});
        inner: *Inner,

        pub fn read(self: *@This(), comptime S: type, args: S.Args, destination: *S.Result) void {
            self.inner.read(S, args, destination);
        }
        pub fn run(self: *@This()) Inner.Error!void {
            return self.inner.run();
        }
        pub fn write(self: *@This(), comptime S: type, args: S.Args) void {
            self.inner.write(S, args);
        }
        pub fn abandon(self: *@This(), faults: store_core.Faults) Inner.Error!void {
            return self.inner.abandon(faults);
        }
        pub fn commit(self: *@This()) Inner.Error!void {
            sqlite.exec(self.inner.store.sqliteDatabase(), "UPDATE model_operation SET auth_refresh_claimed=1") catch unreachable;
            return self.inner.commit();
        }
    };
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var access: Interposed.Inner = .open(&entry);
        defer access.deinit();
        var interposed: Interposed = .{ .inner = &access };
        try std.testing.expect(!try entry.finishTransaction(store_core.Ordinary.attempt_binding, .{}, access.end(.{}, model_settlement_domain.claimModelAuthRefresh(&interposed, binding))));
    }
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE auth_refresh_claimed=1", .{}));
}

test "temporary model failures conserve allowance and exhaust after four Attempts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("retry-config", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&configuration, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    const message_file = try tmp.dir.createFile(std.testing.io, "retry-message", .{ .read = true });
    try message_file.writeStreamingAll(std.testing.io, "retry me");
    try message_file.sync(std.testing.io);
    var message = try completeMessage("retry-message", created_session_0.slice(), message_file, "retry me");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);

    const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const policy = retry_policy.Input{
        .waits_ms = .{ 50, 1, 1 },
        // This valid integer cannot name a deadline at the settlement clock.
        .retry_after_ms = 9_223_372_036_854_775_000,
        // Future eligibility must not assume a commit returns within 50 ms.
        .retry_after_deadline_ms = std.math.maxInt(i64),
    };
    try storage.settleModelAttemptFailure(
        first,
        .{ .uncorrelated = "provider_temporary_http_429" },
        .{ .retryable = policy },
        .{},
    );
    try std.testing.expect(!storage.isFenced());
    try std.testing.expect((try admitRetryForTesting(&storage)) == null);
    {
        const statement = try sqlite.prepare(
            storage.sqliteDatabase(),
            "SELECT resolution_code IS NULL AND retry_due_at_ms IS 0,retry_due_at_ms,last_failure_code,resolution_code " ++
                "FROM model_operation WHERE operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try sqlite.bindU64(statement, 1, first.operation_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
        try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_column_int(statement, 0));
        try std.testing.expectEqual(std.math.maxInt(i64), c.sqlite3_column_int64(statement, 1));
        var failure: protocol.Bounded(protocol.max_code_bytes) = .{};
        try sqlite.readText(statement, 2, &failure);
        try std.testing.expectEqualStrings("provider_temporary_http_429", failure.slice());
        try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(statement, 3));
    }

    // Make this fixture's operation eligible explicitly; admission still uses
    // the real Store transition and checks the allowance and stale binding.
    {
        const due = try sqlite.prepare(storage.sqliteDatabase(), "UPDATE model_operation SET retry_due_at_ms=1 WHERE operation_id=?1");
        defer _ = c.sqlite3_finalize(due);
        try sqlite.bindU64(due, 1, first.operation_id);
        try sqlite.expectDone(due);
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
    }
    const second = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(first.operation_id, second.operation_id);
    try std.testing.expectEqual(@as(u64, 2), second.attempt_ordinal);
    try std.testing.expectError(
        error.StaleAttemptBinding,
        storage.settleModelAttemptFailure(first, .{ .uncorrelated = "late_old_failure" }, .ordinary, .{}),
    );
    try std.testing.expect(!storage.isFenced());

    try storage.settleModelAttemptFailure(
        second,
        .{ .uncorrelated = "provider_transport_failure" },
        .{ .retryable = .{ .waits_ms = policy.waits_ms } },
        .{},
    );
    try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    const third = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(@as(u64, 3), third.attempt_ordinal);
    try storage.settleModelAttemptFailure(
        third,
        .{ .uncorrelated = "provider_temporary_http_503" },
        .{ .retryable = .{ .waits_ms = policy.waits_ms } },
        .{},
    );
    try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    const fourth = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(@as(u64, 4), fourth.attempt_ordinal);
    try storage.settleModelAttemptFailure(
        fourth,
        .{ .uncorrelated = "provider_transport_failure" },
        .{ .retryable = .{ .waits_ms = policy.waits_ms } },
        .{},
    );

    const observation = (try storage.observeCommand("retry-message")).message.?.queue.?;
    const failure = switch (observation.state) {
        .failed => |value| value,
        else => return error.ExpectedFailedObservation,
    };
    try std.testing.expectEqualStrings("retry_exhausted", failure.code.slice());
    try expectActivityOutcome(&storage, created_session_0.slice(), fourth, .provider_unavailable, "retry_exhausted");
    try std.testing.expect((try admitRetryForTesting(&storage)) == null);
    const statement = try sqlite.prepare(
        storage.sqliteDatabase(),
        "SELECT attempt_ordinal,resolution_code IS NULL AND retry_due_at_ms IS 0,retry_due_at_ms,last_failure_code,resolution_code " ++
            "FROM model_operation WHERE operation_id=?1",
    );
    defer _ = c.sqlite3_finalize(statement);
    try sqlite.bindU64(statement, 1, first.operation_id);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
    try std.testing.expectEqual(@as(i64, 4), c.sqlite3_column_int64(statement, 0));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_column_int(statement, 1));
    try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(statement, 2));
    var last_failure: protocol.Bounded(protocol.max_code_bytes) = .{};
    try sqlite.readText(statement, 3, &last_failure);
    try std.testing.expectEqualStrings("provider_transport_failure", last_failure.slice());
    var resolution: protocol.Bounded(protocol.max_code_bytes) = .{};
    try sqlite.readText(statement, 4, &resolution);
    try std.testing.expectEqualStrings("retry_exhausted", resolution.slice());
    try expectDenseSessionPositions(&storage, created_session_0.slice());
}

test "canonical historical read failure fences dispatch without a fabricated outcome" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("historical-config", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&configuration, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    const file = try tmp.dir.createFile(std.testing.io, "historical-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "message");
    try file.sync(std.testing.io);
    var message = try completeMessage("historical-message", created_session_0.slice(), file, "message");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
    var admitted_attempt = (try storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted_attempt.permit.consume();

    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session_revision SET instructions_content_id=9223372036854775807 WHERE session_ref=?1", .{created_session_0.slice()});
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
    var view: HistoricalView = undefined;
    try storage.openHistoricalView(binding, &view);
    defer view.close();
    try std.testing.expectError(error.CorruptStore, testSettings(&view));
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(
        error.StoreFenced,
        storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "request_preparation_failed" }, .ordinary, .{}),
    );
}

test "runnable selection finds age through pending index then groups one session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const statement = try sqlite.prepare(storage.sqliteDatabase(), "EXPLAIN QUERY PLAN " ++ runnable_selection_sql);
    defer _ = c.sqlite3_finalize(statement);
    var uses_pending_index = false;
    var uses_session_index = false;
    while (true) switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {
            const detail = c.sqlite3_column_text(statement, 3);
            if (detail == null) return error.InvalidQueryPlan;
            const length = c.sqlite3_column_bytes(statement, 3);
            if (length < 0) return error.InvalidQueryPlan;
            const text = detail[0..@intCast(length)];
            uses_pending_index = uses_pending_index or
                std.mem.indexOf(u8, text, "message_admission_pending") != null;
            uses_session_index = uses_session_index or
                std.mem.indexOf(u8, text, "message_admission_session_order") != null;
        },
        c.SQLITE_DONE => break,
        else => return error.InvalidQueryPlan,
    };
    try std.testing.expect(uses_pending_index);
    try std.testing.expect(uses_session_index);
}

test "activity revalidation takes the same steps however long a Session's history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");

    var steps: [2]i32 = undefined;
    for ([_]usize{ 10, 10_000 }, &steps) |history, *cost| {
        try store_testing.sqlite_only.exec(&storage, "DELETE FROM message_admission; DELETE FROM session_stop; DELETE FROM turn", .{});
        const insert = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,turn_id,admitted_at) " ++
                "SELECT value,'h1st0r',printf('history-%d',value),1,3*value,value,1 FROM sequence; " ++
                "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_position,outcome_at) " ++
                "SELECT value,'h1st0r',value,value,value,'cancelled',3*value+1,1 FROM sequence; " ++
                "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,position,stopped_at) " ++
                "SELECT printf('stop-%d',value),'h1st0r',value,value,3*value+2,1 FROM sequence",
            .{history},
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.sqliteDatabase(), insert);
        const guard = try sqlite.prepare(storage.sqliteDatabase(), reads_domain.activity_sequence_guard.sql);
        defer _ = c.sqlite3_finalize(guard);
        try sqlite.bindText(guard, 1, "h1st0r");
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(guard));
        cost.* = c.sqlite3_stmt_status(guard, c.SQLITE_STMTSTATUS_VM_STEP, 0);
    }
    try std.testing.expectEqual(steps[0], steps[1]);
}

test "runnable discovery measures eligible ineligible and history populations independently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    // Query-only populations use canonical six-byte fixtures, not named
    // Session creation. Command keys retain their independent text identities.
    const QueryCost = struct {
        const Result = struct {
            steps: i32,
            first_admission: i64,
        };

        fn reset(database: *c.sqlite3, eligible: usize, ineligible: usize, history: usize) !void {
            try sqlite.exec(database, "DELETE FROM message_admission; DELETE FROM session_stop; DELETE FROM model_operation; DELETE FROM turn; DELETE FROM session");
            if (ineligible != 0) {
                try sqlite.exec(
                    database,
                    "INSERT INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tool_set_id,permission_mode," ++
                        "output_schema_content_id,revision,next_position,created_at,created_seq,workspace_digest,workspace_key) " ++
                        "VALUES('st0ped','/','codex','openai-responses/1','model-a',1,1,0,NULL,1,1,1,1000000,zeroblob(32),1000000)",
                );
                const insert = try std.testing.allocator.printSentinel(
                    "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                        "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at) " ++
                        "SELECT value,'st0ped',printf('stopped-%d',value),1,NULL,1 FROM sequence; " ++
                        "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) " ++
                        "VALUES('stop','st0ped',NULL,{0},1)",
                    .{ineligible},
                    0,
                );
                defer std.testing.allocator.free(insert);
                try sqlite.exec(database, insert);
            }
            const eligible_insert = try std.testing.allocator.printSentinel(
                "WITH RECURSIVE sequence(value) AS (VALUES(0) UNION ALL SELECT value+1 FROM sequence WHERE value+1<{0}) " ++
                    "INSERT INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tool_set_id,permission_mode," ++
                    "output_schema_content_id,revision,next_position,created_at,created_seq,workspace_digest,workspace_key) " ++
                    "SELECT printf('%06d',value),'/','codex','openai-responses/1','model-a',1,1,0,NULL,1,1,1,value+1,zeroblob(32),value+1 FROM sequence; " ++
                    "WITH RECURSIVE sequence(value) AS (VALUES(0) UNION ALL SELECT value+1 FROM sequence WHERE value+1<{0}) " ++
                    "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at) " ++
                    "SELECT {1}+value,printf('%06d',value),printf('eligible-%d',value),1,NULL,1 FROM sequence",
                .{ eligible, ineligible + 1 },
                0,
            );
            defer std.testing.allocator.free(eligible_insert);
            try sqlite.exec(database, eligible_insert);
            if (history != 0) {
                const history_insert = try std.testing.allocator.printSentinel(
                    "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                        "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at) " ++
                        "SELECT {1}+value,'h1st0r',printf('history-%d',value),1,value,1 FROM sequence",
                    .{ history, ineligible + eligible },
                    0,
                );
                defer std.testing.allocator.free(history_insert);
                try sqlite.exec(database, history_insert);
            }
        }

        fn measureSelection(database: *c.sqlite3) !Result {
            const statement = try sqlite.prepare(database, runnable_selection_sql);
            defer _ = c.sqlite3_finalize(statement);
            if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.RunnableSelectionFailed;
            var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
            try sqlite.readText(statement, 0, &session_ref);
            if (!session_ref.eql("000000")) return error.RunnableSelectionFailed;
            const first_admission = c.sqlite3_column_int64(statement, 3);
            if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.RunnableSelectionFailed;
            return .{
                .steps = c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 0),
                .first_admission = first_admission,
            };
        }

        fn measureDrain(database: *c.sqlite3, eligible: usize) !i64 {
            const mark = try sqlite.prepare(database, "UPDATE message_admission SET turn_id=admission_id WHERE admission_id=?1");
            defer _ = c.sqlite3_finalize(mark);
            var total_steps: i64 = 0;
            for (0..eligible) |index| {
                const statement = try sqlite.prepare(database, runnable_selection_sql);
                defer _ = c.sqlite3_finalize(statement);
                if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.RunnableSelectionFailed;
                const first_admission = c.sqlite3_column_int64(statement, 3);
                if (first_admission != index + 1) return error.RunnableSelectionFailed;
                if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.RunnableSelectionFailed;
                total_steps += c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 0);

                try sqlite.bindI64(mark, 1, first_admission);
                try sqlite.expectDone(mark);
                if (c.sqlite3_changes(database) != 1) return error.RunnableSelectionFailed;
                if (c.sqlite3_reset(mark) != c.SQLITE_OK) return error.RunnableSelectionFailed;
                if (c.sqlite3_clear_bindings(mark) != c.SQLITE_OK) return error.RunnableSelectionFailed;
            }
            return total_steps;
        }
    };

    var history_selection_costs: [3]i32 = undefined;
    for ([_]usize{ 100, 1_000, 10_000 }, 0..) |history, index| {
        try QueryCost.reset(storage.sqliteDatabase(), 1, 0, history);
        const measured = try QueryCost.measureSelection(storage.sqliteDatabase());
        try std.testing.expectEqual(@as(i64, 1), measured.first_admission);
        history_selection_costs[index] = measured.steps;
    }
    try std.testing.expect(@max(history_selection_costs[0], history_selection_costs[1], history_selection_costs[2]) -
        @min(history_selection_costs[0], history_selection_costs[1], history_selection_costs[2]) <= 32);

    var ineligible_selection_costs: [3]i32 = undefined;
    for ([_]usize{ 10, 100, 1_000 }, 0..) |ineligible, index| {
        try QueryCost.reset(storage.sqliteDatabase(), 1, ineligible, 0);
        const measured = try QueryCost.measureSelection(storage.sqliteDatabase());
        try std.testing.expectEqual(@as(i64, @intCast(ineligible + 1)), measured.first_admission);
        ineligible_selection_costs[index] = measured.steps;
    }
    try std.testing.expect(ineligible_selection_costs[1] > ineligible_selection_costs[0]);
    try std.testing.expect(ineligible_selection_costs[2] > ineligible_selection_costs[1]);

    var eligible_selection_costs: [3]i32 = undefined;
    var eligible_drain_costs: [3]i64 = undefined;
    for ([_]usize{ 10, 100, 1_000 }, 0..) |eligible, index| {
        try QueryCost.reset(storage.sqliteDatabase(), eligible, 0, 0);
        const measured = try QueryCost.measureSelection(storage.sqliteDatabase());
        try std.testing.expectEqual(@as(i64, 1), measured.first_admission);
        eligible_selection_costs[index] = measured.steps;
        try QueryCost.reset(storage.sqliteDatabase(), eligible, 0, 0);
        eligible_drain_costs[index] = try QueryCost.measureDrain(storage.sqliteDatabase(), eligible);
    }
    try std.testing.expect(@max(eligible_selection_costs[0], eligible_selection_costs[1], eligible_selection_costs[2]) -
        @min(eligible_selection_costs[0], eligible_selection_costs[1], eligible_selection_costs[2]) <= 32);
    try std.testing.expect(eligible_drain_costs[1] <= eligible_drain_costs[0] * 12);
    try std.testing.expect(eligible_drain_costs[2] <= eligible_drain_costs[1] * 12);
}

test "retry admission and exhausted recovery use their selection indexes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const queries = [_]struct { sql: [:0]const u8, index: []const u8, no_temporary_sort: bool }{
        .{
            .sql = "EXPLAIN QUERY PLAN SELECT turn_id,operation_id,attempt_ordinal,retry_due_at_ms " ++
                "FROM model_operation INDEXED BY model_operation_retry_due WHERE resolution_code IS NULL " ++
                "AND attempt_ordinal<4 AND retry_due_at_ms<=99 ORDER BY operation_id LIMIT 64",
            .index = "model_operation_retry_due",
            .no_temporary_sort = false,
        },
        .{
            .sql = "EXPLAIN QUERY PLAN SELECT turn_id,operation_id FROM model_operation " ++
                "INDEXED BY model_operation_retry_exhausted WHERE " ++ retry_exhausted_sql ++ " " ++
                "ORDER BY operation_id LIMIT 64",
            .index = "model_operation_retry_exhausted",
            .no_temporary_sort = true,
        },
    };
    for (queries) |query| {
        const statement = try sqlite.prepare(storage.sqliteDatabase(), query.sql);
        defer _ = c.sqlite3_finalize(statement);
        var uses_index = false;
        while (true) switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => {
                const pointer = c.sqlite3_column_text(statement, 3) orelse return error.InvalidQueryPlan;
                const length = c.sqlite3_column_bytes(statement, 3);
                if (length < 0) return error.InvalidQueryPlan;
                const detail = pointer[0..@intCast(length)];
                uses_index = uses_index or std.mem.indexOf(u8, detail, query.index) != null;
                if (query.no_temporary_sort) {
                    try std.testing.expect(std.mem.indexOf(u8, detail, "TEMP B-TREE") == null);
                }
            },
            c.SQLITE_DONE => break,
            else => return error.InvalidQueryPlan,
        };
        try std.testing.expect(uses_index);
    }
}

/// Gives each Session an Operation names a row, for a fixture that inserts
/// Operations with foreign keys off: a writer reads every Session it touches.
fn insertTestingSessionsForOperations(database: *c.sqlite3) !void {
    try sqlite.exec(
        database,
        "INSERT OR IGNORE INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tool_set_id," ++
            "permission_mode,revision,next_position,created_at,created_seq,workspace_digest,workspace_key) " ++
            "SELECT session_ref,'/w','codex','openai-responses/1','m',1,1,0,1,1,1,base+row_number() OVER (ORDER BY session_ref),zeroblob(32),base+1 " ++
            "FROM (SELECT DISTINCT session_ref FROM model_operation),(SELECT coalesce(max(created_seq),0) AS base FROM session)",
    );
}

test "retry due index excludes future population and preserves age ordering" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    const QueryCost = struct {
        fn measure(database: *c.sqlite3, sql: [:0]const u8, snapshot_ms: i64) !i32 {
            const statement = try sqlite.prepare(database, sql);
            defer _ = c.sqlite3_finalize(statement);
            try sqlite.bindI64(statement, 1, snapshot_ms);
            try sqlite.bindI64(statement, 2, 0);
            while (true) switch (c.sqlite3_step(statement)) {
                c.SQLITE_ROW => {},
                c.SQLITE_DONE => break,
                else => return error.RetrySelectionFailed,
            };
            return c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 0);
        }
    };

    var future_costs: [3]i32 = undefined;
    var age_control_costs: [3]i32 = undefined;
    try sqlite.exec(
        storage.sqliteDatabase(),
        "CREATE INDEX test_model_operation_retry_age ON model_operation(operation_id) " ++
            "WHERE resolution_code IS NULL AND attempt_ordinal<4",
    );
    const age_control_sql =
        "SELECT turn_id,operation_id,attempt_ordinal,retry_due_at_ms FROM model_operation " ++
        "INDEXED BY test_model_operation_retry_age WHERE resolution_code IS NULL AND attempt_ordinal<4 " ++
        "AND retry_due_at_ms<=?1 AND operation_id>?2 ORDER BY operation_id LIMIT 2";
    for ([_]usize{ 100, 1_000, 10_000 }, 0..) |future_count, index| {
        try store_testing.sqlite_only.exec(&storage, "DELETE FROM model_operation", .{});
        const insert = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at) " ++
                "SELECT value,value,printf('%06d',value),1,1,1,1,9223372036854775807,0,1 FROM sequence; " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at) VALUES" ++
                "({1},{1},'0der00',1,1,1,1,99,0,1),({2},{2},'ear1er',1,1,1,1,1,0,1)",
            .{ future_count, future_count + 1, future_count + 2 },
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.sqliteDatabase(), insert);
        future_costs[index] = try QueryCost.measure(storage.sqliteDatabase(), retry_admission_select_sql, 99);
        age_control_costs[index] = try QueryCost.measure(storage.sqliteDatabase(), age_control_sql, 99);
    }
    const minimum_future_cost = @min(future_costs[0], future_costs[1], future_costs[2]);
    const maximum_future_cost = @max(future_costs[0], future_costs[1], future_costs[2]);
    try std.testing.expect(maximum_future_cost - minimum_future_cost <= 16);
    try std.testing.expect(age_control_costs[2] > age_control_costs[0] * 10);

    var due_costs: [3]i32 = undefined;
    for ([_]usize{ 10, 100, 1_000 }, 0..) |due_count, index| {
        try store_testing.sqlite_only.exec(&storage, "DELETE FROM model_operation", .{});
        const insert = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{d}) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at) " ++
                "SELECT value,value,printf('%06d',value),1,1,1,1,1,0,1 FROM sequence",
            .{due_count},
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.sqliteDatabase(), insert);
        due_costs[index] = try QueryCost.measure(storage.sqliteDatabase(), retry_admission_select_sql, 99);
    }
    try std.testing.expect(due_costs[1] > due_costs[0]);
    try std.testing.expect(due_costs[2] > due_costs[1]);

    try store_testing.sqlite_only.exec(&storage, "DELETE FROM model_operation", .{});
    try store_testing.sqlite_only.exec(&storage, "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
        "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at) VALUES" ++
        "(1,1,'000001',1,1,1,1,99,0,1)," ++
        "(2,2,'000002',1,1,1,1,50,0,1)," ++
        "(3,3,'000003',1,1,1,1,1,0,1)", .{});
    try insertTestingSessionsForOperations(storage.sqliteDatabase());
    const Active = struct {
        fn contains(_: *const anyopaque, operation_id: u64) bool {
            return operation_id == 1;
        }
    };
    const admitted = (try storage.tryAdmitNextModelRetry(.{
        .context = &empty_active_context,
        .containsFn = Active.contains,
        .maximum_exclusions = 1,
    }, .{})).?;
    try std.testing.expectEqual(@as(u64, 2), admitted.permit.binding.operation_id);
}

const testing_401: ModelFailure = .{ .correlated = .{ .code = "provider_http_401", .request_id = .{}, .report = "" } };

fn settleTransientForTesting(storage: *Store, binding: AttemptBinding) !AttemptBinding {
    try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_temporary_http_503" }, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
    try store_testing.sqlite_only.exec(storage, "UPDATE model_operation SET retry_due_at_ms=1 WHERE resolution_code IS NULL AND retry_due_at_ms!=0", .{});
    return (try admitRetryForTesting(storage)).?.permit.binding;
}

test "a 401 forced refresh is claimed at most once per Operation across failures and restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "refresh-config");

    // Claimed once: the claim commits before any refresh, the Attempt stays
    // uncertain, and a second claim for the same Operation is refused.
    try submitTestMessage(&storage, &tmp, "refresh-a", "refresh-a", session.slice(), "a");
    const a1 = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expect(try storage.claimModelAuthRefresh(a1));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_code IS NULL AND retry_due_at_ms=0 AND auth_refresh_claimed=1", .{}));
    try std.testing.expect(!try storage.claimModelAuthRefresh(a1));
    // A completed refresh makes the one replacement immediately eligible,
    // without generic backoff, and records the 401.
    try storage.settleModelAttemptFailure(a1, testing_401, .refreshed, .{});
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqliteQueryU64(storage.sqliteDatabase(), "SELECT count(*) FROM model_operation WHERE resolution_code IS NULL AND retry_due_at_ms!=0 AND last_failure_code='provider_http_401' AND retry_due_at_ms<=CAST(unixepoch('subsec')*1000 AS INTEGER)", .{}));
    const a2 = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(@as(u64, 2), a2.attempt_ordinal);
    // Counterexample A: a transient failure intervenes; the next 401 must
    // not claim again.
    const a3 = try settleTransientForTesting(&storage, a2);
    try std.testing.expect(!try storage.claimModelAuthRefresh(a3));
    try storage.settleModelAttemptFailure(a3, testing_401, .ordinary, .{});

    // Counterexample B: same saved shape at Attempt 3, but no earlier claim.
    try submitTestMessage(&storage, &tmp, "refresh-b", "refresh-b", session.slice(), "b");
    const b1 = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const b3 = try settleTransientForTesting(&storage, try settleTransientForTesting(&storage, b1));
    try std.testing.expectEqual(@as(u64, 3), b3.attempt_ordinal);
    try std.testing.expect(try storage.claimModelAuthRefresh(b3));
    try storage.settleModelAttemptFailure(b3, testing_401, .refreshed, .{});
    // The replacement consumes the ordinary allowance: Attempt 4 has none
    // left, so a 401 there cannot claim.
    const b4 = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(@as(u64, 4), b4.attempt_ordinal);
    try std.testing.expect(!try storage.claimModelAuthRefresh(b4));
    try storage.settleModelAttemptFailure(b4, testing_401, .ordinary, .{});

    // A stale binding cannot claim, and a refreshed settlement requires the
    // claim.
    try submitTestMessage(&storage, &tmp, "refresh-c", "refresh-c", session.slice(), "c");
    const c1 = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var stale = c1;
    stale.attempt_ordinal = 2;
    try std.testing.expectError(error.StaleAttemptBinding, storage.claimModelAuthRefresh(stale));
    try std.testing.expectError(error.StaleAttemptBinding, storage.settleModelAttemptFailure(c1, testing_401, .refreshed, .{}));

    // Crash after the claim and before settlement: restart replaces the
    // uncertain Attempt under ordinary policy and the claim survives.
    try std.testing.expect(try storage.claimModelAuthRefresh(c1));
    try storage.close();
    storage_open = false;
    var reopened: Store = undefined;
    try testingStore(&reopened, &tmp, std.testing.io);
    defer reopened.close() catch unreachable;
    const c2 = (try admitRetryForTesting(&reopened)).?.permit.binding;
    try std.testing.expectEqual(c1.operation_id, c2.operation_id);
    try std.testing.expectEqual(@as(u64, 2), c2.attempt_ordinal);
    try std.testing.expect(!try reopened.claimModelAuthRefresh(c2));
}

test "retry admission reads past a full page of active Operations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    const insert = try std.testing.allocator.printSentinel(
        "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{d}) " ++
            "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
            "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at) " ++
            "SELECT value,value,printf('%06d',value),1,1,1,1,1,0,1 FROM sequence",
        .{retry_admission_page_rows + 1},
        0,
    );
    defer std.testing.allocator.free(insert);
    try sqlite.exec(storage.sqliteDatabase(), insert);
    try insertTestingSessionsForOperations(storage.sqliteDatabase());
    const Active = struct {
        fn contains(_: *const anyopaque, operation_id: u64) bool {
            return operation_id <= retry_admission_page_rows;
        }
    };
    const active_filter = ActiveOperationFilter{
        .context = &empty_active_context,
        .containsFn = Active.contains,
        .maximum_exclusions = retry_admission_page_rows,
    };
    const admitted = (try storage.tryAdmitNextModelRetry(active_filter, .{})).?;
    try std.testing.expectEqual(@as(u64, retry_admission_page_rows + 1), admitted.permit.binding.operation_id);
}

test "retry transitions preserve age and settle one exhausted outcome per call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    try store_testing.sqlite_only.exec(&storage, "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<201) " ++
        "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
        "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at) " ++
        "SELECT value,value,printf('%06d',value),1,1,1,1," ++
        "CASE WHEN value<=100 THEN 9223372036854775807 ELSE 1 END,0,1 FROM sequence", .{});
    try insertTestingSessionsForOperations(storage.sqliteDatabase());

    const Active = struct {
        const Context = struct {
            operation_ids: *const [100]u64,
            comparisons: *usize,
        };

        fn contains(context: *const anyopaque, operation_id: u64) bool {
            const active: *const Context = @ptrCast(@alignCast(context));
            for (active.operation_ids) |active_id| {
                active.comparisons.* += 1;
                if (operation_id == active_id) return true;
            }
            return false;
        }
    };
    var active_operations: [100]u64 = undefined;
    for (&active_operations, 0..) |*operation_id, index| {
        operation_id.* = 101 + @as(u64, @intCast(index));
    }
    var comparisons: usize = 0;
    const active_context = Active.Context{
        .operation_ids = &active_operations,
        .comparisons = &comparisons,
    };
    const active_filter = ActiveOperationFilter{
        .context = &active_context,
        .containsFn = Active.contains,
        .maximum_exclusions = active_operations.len,
    };

    try std.testing.expectError(
        error.InjectedAttemptCommitFailure,
        storage.tryAdmitNextModelRetry(active_filter, .{ .attempt_before_commit = true }),
    );
    try std.testing.expect(storage.isFenced());
    try std.testing.expectEqual(@as(usize, 5150), comparisons);
    comparisons = 0;
    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    const admitted = (try storage.tryAdmitNextModelRetry(active_filter, .{})).?;
    try std.testing.expectEqual(@as(u64, 201), admitted.permit.binding.operation_id);
    try std.testing.expectEqual(@as(u64, 2), admitted.permit.binding.attempt_ordinal);
    try std.testing.expectEqual(@as(usize, 5150), comparisons);

    try store_testing.sqlite_only.exec(&storage, "DELETE FROM model_operation", .{});
    for (6000..6102) |value| {
        var buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "exhausted-{d}", .{value});
        const session = try configureTestSession(&storage, key);
        const insert_turn = try sqlite.prepare(storage.sqliteDatabase(), "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id) VALUES(?1,?2,1,1,?1)");
        defer _ = c.sqlite3_finalize(insert_turn);
        try sqlite.bindU64(insert_turn, 1, value);
        try sqlite.bindText(insert_turn, 2, session.slice());
        try sqlite.expectDone(insert_turn);
        const insert_operation = try sqlite.prepare(storage.sqliteDatabase(), "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
            "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,attempt_at) " ++
            "VALUES(?1,?1,?2,1,1,1,4,0,0,1)");
        defer _ = c.sqlite3_finalize(insert_operation);
        try sqlite.bindU64(insert_operation, 1, value);
        try sqlite.bindText(insert_operation, 2, session.slice());
        try sqlite.expectDone(insert_operation);
    }
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");

    var active_exhausted: [100]u64 = undefined;
    for (&active_exhausted, 0..) |*operation_id, index| operation_id.* = 6000 + @as(u64, @intCast(index));
    var exhausted_comparisons: usize = 0;
    const exhausted_context = Active.Context{
        .operation_ids = &active_exhausted,
        .comparisons = &exhausted_comparisons,
    };
    try std.testing.expect(try storage.recoverOneExhaustedModelAttempt(.{
        .context = &exhausted_context,
        .containsFn = Active.contains,
        .maximum_exclusions = active_exhausted.len,
    }));
    try std.testing.expectEqual(@as(usize, 5150), exhausted_comparisons);
    const outcomes = try sqlite.prepare(
        storage.sqliteDatabase(),
        "SELECT operation_id,resolution_code FROM model_operation WHERE operation_id IN (6100,6101) ORDER BY operation_id",
    );
    defer _ = c.sqlite3_finalize(outcomes);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(outcomes));
    try std.testing.expectEqual(@as(i64, 6100), c.sqlite3_column_int64(outcomes, 0));
    var resolution: protocol.Bounded(protocol.max_code_bytes) = .{};
    try sqlite.readText(outcomes, 1, &resolution);
    try std.testing.expectEqualStrings("retry_exhausted", resolution.slice());
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(outcomes));
    try std.testing.expectEqual(@as(i64, 6101), c.sqlite3_column_int64(outcomes, 0));
    try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(outcomes, 1));
}

test "public proposal structural corruption fences the activity page" {
    const faults = [_][:0]const u8{
        "UPDATE content SET private=1,payload=zeroblob(byte_length) WHERE content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=0)",
        "DELETE FROM model_tool_call WHERE call_ordinal=0",
        "UPDATE turn SET session_ref='f0re1g'",
        "UPDATE model_tool_call SET name_content_id=(SELECT call_id_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0",
        "UPDATE content SET digest=zeroblob(32) WHERE content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=0)",
    };
    for (faults) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "config");
        try submitTestMessage(&storage, &tmp, "input", "message", session.slice(), "run tools");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const calls = [_]TestingCall{
            .{ .item_id = "original", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            .{ .item_id = "replacement", .name = "unknown", .encoded_call_id = "sibling", .decoded_call_id = "sibling", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        };
        try settleCallsForTesting(&storage, &tmp, binding, "output", &calls);
        var request: protocol.ActivityPage = .{};
        try request.session.set(session.slice());
        const healthy = try store_core.activityPageForTesting(&storage, request);
        const call = for (healthy.items[0..healthy.count]) |item| {
            if (item.value == .call) break item.value.call;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(binding.operation_id, call.operation);
        try std.testing.expectEqual(binding.turn_id, call.turn);
        try std.testing.expectEqual(@as(u64, 0), call.call_ordinal);
        try std.testing.expectEqualSlices(u8, &protocol.contentDigest("unknown"), &call.fields[0].digest);
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        try sqlite.exec(storage.sqliteDatabase(), fault);
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
        try std.testing.expectError(error.CorruptStore, store_core.activityPageForTesting(&storage, request));
        try std.testing.expect(storage.isFenced());
        try std.testing.expectError(error.StoreFenced, store_core.activityPageForTesting(&storage, request));
        try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
    }
}

test "public activity admission corruption fences page and content independently" {
    const faults = [_][:0]const u8{
        "UPDATE message_admission SET admission_position=NULL WHERE command_key='message'",
        "UPDATE core_command SET target='f0re1g' WHERE command_key='message'",
        "DELETE FROM conversation_entry WHERE source_admission_id=(SELECT admission_id FROM message_admission WHERE command_key='message')",
    };
    for (faults) |fault| {
        for ([_]bool{ false, true }) |content_route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "message", session.slice(), "input bytes");
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const queued = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 1), queued.count);
            const item = queued.items[0];
            try std.testing.expectEqualStrings("message", item.value.admission.key.slice());
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest("input bytes"), &item.value.admission.content.digest);
            _ = (try storage.admitNextModelAttempt(.{})).?;
            try sqlite.exec(storage.sqliteDatabase(), fault);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
            request.position = item.position - 1;
            const result: anyerror!void = if (content_route)
                if (storage.openActivityContent(&.{ .session = request.session, .position = item.position })) |value| blk: {
                    var reader: ContentReader = undefined;
                    reader.open(value);
                    reader.close();
                    break :blk {};
                } else |err| err
            else if (store_core.activityPageForTesting(&storage, request)) |_| {} else |err| err;
            try std.testing.expectError(error.CorruptStore, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, store_core.activityPageForTesting(&storage, request));
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
        }
    }
}

test "the queued Messages cost the queue, not the history after a page's end" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    // Messages 1..n wait at positions 2, 4, ...; a stop at 2n+1 excludes all
    // but the newest. A page ending at the first Message has one waiting,
    // as one ending after the stop does.
    var steps: [2][2]i32 = undefined;
    for ([_]usize{ 10, 10_000 }, &steps) |history, *cost| {
        try store_testing.sqlite_only.exec(&storage, "DELETE FROM message_admission; DELETE FROM session_stop", .{});
        const insert = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at) " ++
                "SELECT value,'qu3u3d',printf('queued-%d',value),1,2*value,1 FROM sequence; " ++
                "INSERT INTO session_stop(command_key,session_ref,admission_cutoff,position,stopped_at) VALUES('stop','qu3u3d',{0}-1,2*{0}+1,1)",
            .{history},
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.sqliteDatabase(), insert);
        const statement = try storage.engine.sqlite.cachedTyped(reads_domain.queued);
        for ([_]u64{ 2, 2 * history + 1 }, [_]u64{ 1, history }, cost) |end, newest, *probe| {
            _ = c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 1);
            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            var access: reads_domain.ReadAccess = .open(&entry);
            defer access.deinit();
            var waiting: reads_domain.QueuedMessages = .{};
            access.readEach(reads_domain.queued, .{ .session = "qu3u3d", .position = end }, std.math.maxInt(u64), &waiting);
            try access.run();
            try std.testing.expectEqual(protocol.Queued{ .count = 1, .oldest_position = 2 * newest, .newest_admission = newest, .newest_position = 2 * newest }, waiting.queued);
            probe.* = c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 0);
        }
    }
    try std.testing.expectEqual(steps[0], steps[1]);
}

test "a stop cancels its Actions in pages of one write each, in call order at dense positions" {
    // No Action, one, a page's edges and the next, two pages and one more.
    inline for (.{ 0, 1, 8, 9, 13, 14, 16, 17, 26, 27 }) |count| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "many-config");
        try submitTestMessage(&storage, &tmp, "many-input", "many-input", session.slice(), "propose");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        // With no Action, the model still runs, and the stop interrupts it.
        if (count != 0) {
            var texts: [count][4][96]u8 = undefined;
            var calls: [count]TestingCall = undefined;
            for (&calls, &texts, 0..) |*call, *text, index| {
                const id = try std.fmt.bufPrint(&text[0], "many-{d}", .{index});
                call.* = .{
                    .item_id = id,
                    .name = "bash",
                    .encoded_call_id = id,
                    .decoded_call_id = id,
                    .encoded_arguments = try std.fmt.bufPrint(&text[1], "{{\\\"description\\\":\\\"Run {d}\\\",\\\"cmd\\\":\\\"{d}\\\",\\\"timeout_ms\\\":null}}", .{ index, index }),
                    .decoded_arguments = try std.fmt.bufPrint(&text[2], "{{\"description\":\"Run {d}\",\"cmd\":\"{d}\",\"timeout_ms\":null}}", .{ index, index }),
                };
            }
            try settleCallsForTesting(&storage, &tmp, binding, "many-calls", &calls);
        }
        try std.testing.expectEqual(@as(u64, count), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code IS NULL AND attempt_ordinal=0", .{}));
        var stop = try completeSessionStop("many-stop", session.slice());
        var statements: TestingStatements = .{};
        statements.begin(storage.sqliteDatabase());
        const reply = storage.stopSession(&stop, .{});
        statements.end(storage.sqliteDatabase());
        try std.testing.expect(reply.accepted.completion == .completed);
        // BEGIN, the three reads of round 1, the command, the stop, the
        // Turn's close, the position advance and COMMIT; with no Action the
        // interruption; with Actions the text's lookup and insert, then a
        // page read and a write per `cancel_chunk` (13) Actions.
        const pages = (count + 12) / 13;
        // Closing the Turn also writes its owed ending.
        const expected: u64 = if (count == 0) 11 else 12 + 2 * pages;
        try std.testing.expectEqual(expected, statements.count);
        try std.testing.expectEqual(@as(u64, count), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code='cancelled'", .{}));
        // Acceptance follows call order.
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN action_operation b " ++
            "ON b.parent_operation_id=a.parent_operation_id AND a.call_ordinal<b.call_ordinal WHERE a.acceptance_position>=b.acceptance_position", .{}));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM turn WHERE outcome_code='cancelled'", .{}));
        try expectDenseSessionPositions(&storage, session.slice());
        try std.testing.expect(!storage.isFenced());
    }
}

test "Session work dates a tool group by its last acceptance, even when the clock stepped back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    // Ask: denying one Action leaves the other awaiting, so the Session
    // awaits approval from that denial, though the clock read earlier than
    // at the proposal.
    const ask = try configureTestSessionAsk(&storage, "stepped-ask");
    try submitTestMessage(&storage, &tmp, "stepped-ask-input", "stepped-ask-input", ask.slice(), "propose");
    try settleTwoActionsForTesting(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding, "stepped-ask-calls");
    const first = try store_testing.sqlite_only.queryU64(&storage, "SELECT min(action_id) FROM action_operation", .{});
    try denyForTesting(&storage, ask.slice(), "stepped-deny-first", first);
    try store_testing.sqlite_only.exec(&storage, "UPDATE model_operation SET resolved_at=300;UPDATE action_operation SET resolved_at=100 WHERE resolution_code IS NOT NULL", .{});
    try std.testing.expectEqual(@as(u64, 100), try expectOneWork(&storage, &tmp, ask.slice(), "approval"));
    // Denying the other settles the group: pending from the later denial,
    // whose clock read earlier still.
    try denyForTesting(&storage, ask.slice(), "stepped-deny-second", try store_testing.sqlite_only.queryU64(&storage, "SELECT max(action_id) FROM action_operation", .{}));
    try store_testing.sqlite_only.exec(&storage, "UPDATE action_operation SET resolved_at=" ++
        "CASE WHEN acceptance_position=(SELECT max(acceptance_position) FROM action_operation) THEN 50 ELSE 100 END", .{});
    try std.testing.expectEqual(@as(u64, 50), try expectOneWork(&storage, &tmp, ask.slice(), "pending"));

    // Bypass: both Actions are authorized with the proposal. Once one has
    // run, the other waits for a slot from that run's resolution, not from
    // its own authorization, whatever the clock read.
    const bypass = try configureTestSessionAsk(&storage, "stepped-bypass");
    var update: protocol.ConfigureCommand = .{};
    try update.key.set("stepped-bypass-mode");
    try update.session.set(bypass.slice());
    update.configuration.permission_mode.state = .value;
    try update.configuration.permission_mode.value.set("bypass");
    try std.testing.expect(storage.configure(&update, .{}) == .accepted);
    try submitTestMessage(&storage, &tmp, "stepped-bypass-input", "stepped-bypass-input", bypass.slice(), "propose");
    try settleTwoActionsForTesting(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding, "stepped-bypass-calls");
    const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
    _ = try storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{});
    var sql: [256]u8 = undefined;
    try sqlite.exec(storage.sqliteDatabase(), try std.fmt.bufPrintSentinel(&sql, "UPDATE model_operation SET resolved_at=300 WHERE session_ref='{0s}';" ++
        "UPDATE action_operation SET decided_at=300 WHERE session_ref='{0s}';" ++
        "UPDATE action_operation SET resolved_at=70 WHERE session_ref='{0s}' AND resolution_code IS NOT NULL", .{bypass.slice()}, 0));
    try std.testing.expectEqual(@as(u64, 70), try expectOneWork(&storage, &tmp, bypass.slice(), "pending"));
    try std.testing.expect(!storage.isFenced());
}

test "persisted tool label corruption fences every publication route" {
    const invalid = [_]struct { sql: []const u8, failure: anyerror = error.CorruptStore }{
        .{ .sql = "' '" },
        .{ .sql = "'Read' || char(10) || 'files'" },
        .{ .sql = "char(160)" },
        .{ .sql = "'Read' || char(8232) || 'files'" },
        // The typed row's Bounded text rejects malformed UTF-8 before
        // semantic validation; a typed decode failure is CorruptStore.
        .{ .sql = "CAST(X'80' AS TEXT)" },
    };
    for (invalid) |description| {
        for ([_]enum { current, full, live_activity, settled_activity, conversation }{ .current, .full, .live_activity, .settled_activity, .conversation }) |route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "label-config");
            try submitTestMessage(&storage, &tmp, "label-input", "label-input", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "label-calls");
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            request.direction = .backward;
            const healthy = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(u64, 2), healthy.call_activity.total);
            try std.testing.expectEqualStrings("Run first command", healthy.call_activity.entries[0].presentation.description.?.slice());
            if (route == .settled_activity or route == .conversation) {
                var stop = try completeSessionStop("label-stop", session.slice());
                try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                try std.testing.expectEqual(@as(usize, 3), (try store_core.publicConversationPageForTesting(&storage, .{ .session = request.session })).count);
            }
            var sql: [256]u8 = undefined;
            try sqlite.exec(storage.sqliteDatabase(), try std.fmt.bufPrintSentinel(&sql, "UPDATE model_tool_call SET description={s} WHERE call_ordinal=0", .{description.sql}, 0));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
            const result: anyerror!void = switch (route) {
                .current, .full => if (testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, if (route == .full) .full else .current)) |bytes| blk: {
                    std.testing.allocator.free(bytes);
                    break :blk {};
                } else |err| err,
                .live_activity, .settled_activity => if (store_core.activityPageForTesting(&storage, request)) |_| {} else |err| err,
                .conversation => if (store_core.publicConversationPageForTesting(&storage, .{ .session = request.session })) |_| {} else |err| err,
            };
            try std.testing.expectError(description.failure, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, store_core.activityPageForTesting(&storage, request));
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
        }
    }
}

test "an Activity page costs the same steps after 10 or 10,000 earlier rows" {
    // Each Store holds `history` earlier units, a Message, its call item, the
    // call's rejection and its Turn's outcome, then the same Session tail: a
    // Message, twenty rejected calls and a stop. The opening's page and a
    // forward page from the tail's first row read only the tail.
    var steps: [2][2]i64 = undefined;
    for ([_]usize{ 10, 10_000 }, &steps) |history, *cost| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "cost-config");
        // Foreign keys are off: each history Message names its Turn before
        // the Turn row exists, which an immediate key would refuse.
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        const insert = try std.testing.allocator.printSentinel(
            "CREATE TEMP TABLE history AS WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "SELECT value,next_position+4*(value-1) AS position,instructions_content_id AS content FROM sequence,session; " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,turn_id,admitted_at) " ++
                "SELECT value,'{1s}',printf('history-%d',value),content,position,value,1 FROM history; " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,attempt_ordinal,resolution_code,resolved_at) " ++
                "SELECT value,value,'{1s}',1,value,position,0,1,'tool_proposals',1 FROM history; " ++
                "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,extras_content_id,part_count) " ++
                "SELECT value,0,'{1s}',position+1,3,1,zeroblob(32),0,content,0 FROM history; " ++
                "INSERT INTO model_tool_call(operation_id,session_ref,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id,field_metadata,rejection_code,rejection_content_id,acceptance_position) " ++
                "SELECT value,'{1s}',0,0,content,content,content,zeroblob(120),'unknown_tool',content,position+2 FROM history; " ++
                "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_position,outcome_at) " ++
                "SELECT value,'{1s}',value,value,value,'completed',position+3,1 FROM history; " ++
                "UPDATE session SET next_position=next_position+4*{0}; DROP TABLE history",
            .{ history, session.slice() },
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.sqliteDatabase(), insert);
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
        // The history rows bypass the Host's ids.
        try store_core.reloadIdentitiesForTesting(&storage);
        const tail = (try store_core.readSessionForTesting(&storage, session.slice())).?.next_position;
        try submitTestMessage(&storage, &tmp, "cost-input", "input", session.slice(), "propose");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        var identities: [20][24]u8 = undefined;
        var calls: [20]TestingCall = undefined;
        for (&calls, &identities, 0..) |*call, *identity, index| {
            const id = try std.fmt.bufPrint(identity, "cost-{d}", .{index});
            call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "", .decoded_arguments = "" };
        }
        try settleCallsForTesting(&storage, &tmp, binding, "cost-calls", &calls);
        var stop = try completeSessionStop("cost-stop", session.slice());
        try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);

        var opening: protocol.ActivityPage = .{ .direction = .backward };
        try opening.session.set(session.slice());
        cost[0] = try activityPageSteps(&storage, opening);
        const page = try store_core.activityPageForTesting(&storage, opening);
        try std.testing.expect(page.more);
        var forward: protocol.ActivityPage = .{ .end = page.end, .position = tail - 1 };
        try forward.session.set(session.slice());
        cost[1] = try activityPageSteps(&storage, forward);
        const later = try store_core.activityPageForTesting(&storage, forward);
        try std.testing.expect(later.more);
        try std.testing.expectEqual(tail, later.items[0].position);
    }
    try std.testing.expectEqual(steps[0], steps[1]);
}

test "a one-row page of a person's Messages costs the same steps after 10 or 10,000 received ones" {
    // Ctrl-P from the end passes over every Message another Session sent
    // to reach the person's first one, through their own index.
    var steps: [2]i64 = undefined;
    for ([_]usize{ 10, 10_000 }, &steps) |history, *cost| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "recall-config");
        const peer = try configureTestSession(&storage, "recall-peer");
        try submitTestMessage(&storage, &tmp, "recall-first", "first", session.slice(), "first");
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        const insert = try std.testing.allocator.printSentinel(
            "CREATE TEMP TABLE history AS WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "SELECT value,next_position+value-1 AS position,instructions_content_id AS content FROM sequence,session WHERE session_ref='{1s}'; " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,sender_session_ref,sender_position) " ++
                "SELECT 1000+value,'{1s}',printf('received-%d',value),content,position,1,'{2s}',value FROM history; " ++
                "UPDATE session SET next_position=next_position+{0} WHERE session_ref='{1s}'; DROP TABLE history",
            .{ history, session.slice(), peer.slice() },
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.sqliteDatabase(), insert);
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
        try store_core.reloadIdentitiesForTesting(&storage);
        var request: protocol.ActivityPage = .{ .direction = .backward, .kinds = .initOne(.admission), .limit = 1 };
        try request.session.set(session.slice());
        cost.* = try activityPageSteps(&storage, request);
        const page = try store_core.activityPageForTesting(&storage, request);
        try std.testing.expect(page.count == 1 and page.items[0].value == .admission and !page.more);
    }
    try std.testing.expectEqual(steps[0], steps[1]);
}

test "a forward one-row page of a person's Messages costs the same steps past 10 or 10,000 tool groups" {
    // Ctrl-N from the first Message steps to the second, with every tool
    // group completed between it and the third. The page lists no calls, so it reads no
    // call activity.
    var steps: [2]i64 = undefined;
    for ([_]usize{ 10, 10_000 }, &steps) |history, *cost| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "forward-config");
        try submitTestMessage(&storage, &tmp, "forward-first", "first", session.slice(), "first");
        try submitTestMessage(&storage, &tmp, "forward-second", "second", session.slice(), "second");
        const first = try store_testing.sqlite_only.queryU64(&storage, "SELECT min(admission_position) FROM message_admission", .{});
        // Foreign keys are off: each tool group names its Turn before the
        // Turn row exists. A cancelled Turn needs no answer content.
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        const insert = try std.testing.allocator.printSentinel(
            "CREATE TEMP TABLE history AS WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "SELECT 1000+value AS value,next_position+3*(value-1) AS position,instructions_content_id AS content FROM sequence,session WHERE session_ref='{1s}'; " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,attempt_ordinal,resolution_code,resolved_at) " ++
                "SELECT value,value,'{1s}',1,value,position,0,1,'tool_proposals',1 FROM history; " ++
                "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,extras_content_id,part_count) " ++
                "SELECT value,0,'{1s}',position,3,1,zeroblob(32),0,content,0 FROM history; " ++
                "INSERT INTO model_tool_call(operation_id,session_ref,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id,field_metadata,rejection_code,rejection_content_id,acceptance_position) " ++
                "SELECT value,'{1s}',0,0,content,content,content,zeroblob(120),'unknown_tool',content,position+1 FROM history; " ++
                "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_position,outcome_at) " ++
                "SELECT value,'{1s}',value,value,value,'cancelled',position+2,1 FROM history; " ++
                "UPDATE session SET next_position=next_position+3*{0} WHERE session_ref='{1s}'; DROP TABLE history",
            .{ history, session.slice() },
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.sqliteDatabase(), insert);
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
        try store_core.reloadIdentitiesForTesting(&storage);
        try submitTestMessage(&storage, &tmp, "forward-third", "third", session.slice(), "third");
        var request: protocol.ActivityPage = .{ .position = first, .kinds = .initOne(.admission), .limit = 1 };
        try request.session.set(session.slice());
        cost.* = try activityPageSteps(&storage, request);
        const page = try store_core.activityPageForTesting(&storage, request);
        try std.testing.expect(page.count == 1 and page.items[0].position > first and page.more);
        try std.testing.expectEqual(@as(u64, 0), page.call_activity.total);
    }
    try std.testing.expectEqual(steps[0], steps[1]);
}

test "a one-row page of a person's Messages costs the same steps past 100 or 10,000 waiting ones" {
    // Ctrl-P from the end reads the newest Message, with every other one
    // still waiting. The page is filtered, so it reads no queue footer.
    // Each Store holds more waiting Messages than a page source reads.
    var steps: [2]i64 = undefined;
    for ([_]usize{ 100, 10_000 }, &steps) |history, *cost| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "waiting-config");
        const insert = try std.testing.allocator.printSentinel(
            "CREATE TEMP TABLE history AS WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "SELECT value,next_position+value-1 AS position,instructions_content_id AS content FROM sequence,session WHERE session_ref='{1s}'; " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at) " ++
                "SELECT 1000+value,'{1s}',printf('waiting-%d',value),content,position,1 FROM history; " ++
                "UPDATE session SET next_position=next_position+{0} WHERE session_ref='{1s}'; DROP TABLE history",
            .{ history, session.slice() },
            0,
        );
        defer std.testing.allocator.free(insert);
        // Foreign keys are off: the waiting Messages have no commands.
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        try sqlite.exec(storage.sqliteDatabase(), insert);
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
        try store_core.reloadIdentitiesForTesting(&storage);
        try submitTestMessage(&storage, &tmp, "waiting-newest", "newest", session.slice(), "newest");
        var request: protocol.ActivityPage = .{ .direction = .backward, .kinds = .initOne(.admission), .limit = 1 };
        try request.session.set(session.slice());
        cost.* = try activityPageSteps(&storage, request);
        const page = try store_core.activityPageForTesting(&storage, request);
        try std.testing.expect(page.count == 1 and page.items[0].value.admission.state == .queued and page.more);
        try std.testing.expectEqual(@as(u64, 0), page.queued.count);
    }
    try std.testing.expectEqual(steps[0], steps[1]);
}

/// The VM steps every statement of the Store's connection takes to read one
/// Activity page.
fn activityPageSteps(storage: *Store, request: protocol.ActivityPage) !i64 {
    var statement = c.sqlite3_next_stmt(storage.sqliteDatabase(), null);
    while (statement) |each| : (statement = c.sqlite3_next_stmt(storage.sqliteDatabase(), each))
        _ = c.sqlite3_stmt_status(each, c.SQLITE_STMTSTATUS_VM_STEP, 1);
    _ = try store_core.activityPageForTesting(storage, request);
    var total: i64 = 0;
    statement = c.sqlite3_next_stmt(storage.sqliteDatabase(), null);
    while (statement) |each| : (statement = c.sqlite3_next_stmt(storage.sqliteDatabase(), each))
        total += c.sqlite3_stmt_status(each, c.SQLITE_STMTSTATUS_VM_STEP, 0);
    return total;
}

test "activity judges every candidate Operation's tool outcomes, not only its kept calls" {
    // The page keeps three calls' presentations; the rule must still reach
    // the fourth call, by one read per Operation while there are at most
    // `max_operations`, 32, and by one read over them all past that.
    for ([_]enum { one_operation, many_operations }{ .one_operation, .many_operations }) |shape| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "outcome-config");
        try submitTestMessage(&storage, &tmp, "outcome-input", "input", session.slice(), "propose");
        switch (shape) {
            .one_operation => {
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var calls: [4]TestingCall = undefined;
                var ids: [4][16]u8 = undefined;
                for (&calls, &ids, 0..) |*call, *id_buffer, index| {
                    const id = try std.fmt.bufPrint(id_buffer, "outcome-{d}", .{index});
                    call.* = .{
                        .item_id = id,
                        .name = "bash",
                        .encoded_call_id = id,
                        .decoded_call_id = id,
                        .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                        .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
                    };
                }
                try settleCallsForTesting(&storage, &tmp, binding, "outcome-calls", &calls);
            },
            .many_operations => for (0..40) |index| {
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var identity: [24]u8 = undefined;
                const id = try std.fmt.bufPrint(&identity, "ops-{d}", .{index});
                var prefix: [24]u8 = undefined;
                const calls = [_]TestingCall{.{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "", .decoded_arguments = "" }};
                try settleCallsForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&prefix, "ops-calls-{d}", .{index}), &calls);
            },
        }
        var request: protocol.ActivityPage = .{};
        try request.session.set(session.slice());
        const page = try store_core.activityPageForTesting(&storage, request);
        try std.testing.expectEqual(@as(usize, 3), page.call_activity.count);
        try std.testing.expect(page.call_activity.total >= 4);
        // One call each, so as many candidate Operations as calls.
        if (shape == .many_operations) try std.testing.expect(page.call_activity.total > 32);
        // The last candidate call's item stops being a call item; no kept
        // presentation reads that call.
        try store_testing.sqlite_only.exec(&storage, "UPDATE model_output_item SET item_kind=1 WHERE (operation_id,item_ordinal)=" ++
            "(SELECT operation_id,item_ordinal FROM model_tool_call ORDER BY operation_id DESC,call_ordinal DESC LIMIT 1)", .{});
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
        try std.testing.expectError(error.CorruptStore, store_core.activityPageForTesting(&storage, request));
        try std.testing.expect(storage.isFenced());
    }
}

test "the tool outcome rule counts an Operation's calls against its call items" {
    // One call's item stops being a call item: every call left is valid
    // and as many as the call items, so only the count of calls differs.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "count-config");
    try submitTestMessage(&storage, &tmp, "count-input", "input", session.slice(), "propose");
    try settleTwoActionsForTesting(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding, "count-calls");
    try store_testing.sqlite_only.exec(&storage, "UPDATE model_output_item SET item_kind=1 WHERE item_kind=3 AND item_ordinal=" ++
        "(SELECT item_ordinal FROM model_tool_call WHERE call_ordinal=1)", .{});
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
    try std.testing.expectError(error.CorruptStore, testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024));
    try std.testing.expect(storage.isFenced());
}

test "the Current report fences an unauthorized Action proposed under bypass" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "unauthorized-config");
    var update: protocol.ConfigureCommand = .{};
    try update.key.set("unauthorized-mode");
    try update.session.set(session.slice());
    update.configuration.permission_mode.state = .value;
    try update.configuration.permission_mode.value.set("bypass");
    try std.testing.expect(storage.configure(&update, .{}) == .accepted);
    try submitTestMessage(&storage, &tmp, "unauthorized-input", "input", session.slice(), "propose");
    try settleTwoActionsForTesting(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding, "unauthorized-calls");
    // The CHECK pairs a grant with its decision, so the damage clears both.
    try store_testing.sqlite_only.exec(&storage, "UPDATE action_operation SET authorized=0,decided_at=NULL WHERE call_ordinal=1", .{});
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
    try std.testing.expectError(error.CorruptStore, testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024));
    try std.testing.expect(storage.isFenced());
}

fn configureTestEffort(storage: *Store, key: []const u8, session: []const u8, state: protocol.FieldState, value: []const u8) !ConfigureReply {
    var command: protocol.ConfigureCommand = .{};
    try command.key.set(key);
    try command.session.set(session);
    command.configuration.reasoning_effort.state = state;
    if (state == .value) try command.configuration.reasoning_effort.value.set(value);
    return storage.configure(&command, .{});
}

fn testingRevisionEfforts(storage: *Store, session: []const u8, destination: []?protocol.ReasoningEffort) !usize {
    const statement = try sqlite.prepare(storage.sqliteDatabase(), "SELECT reasoning_effort FROM session_revision WHERE session_ref=?1 ORDER BY revision");
    defer _ = c.sqlite3_finalize(statement);
    try sqlite.bindText(statement, 1, session);
    var count: usize = 0;
    while (c.sqlite3_step(statement) == c.SQLITE_ROW) : (count += 1) {
        destination[count] = try sqlite.readNullableEffort(statement, 0);
    }
    return count;
}

test "reasoning effort overrides are model-checked and frozen on each admitted Operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);

    var create = try completeConfiguration("effort-create", "", workspace, "gpt-6-luna");
    create.configuration.reasoning_effort.state = .value;
    try create.configuration.reasoning_effort.value.set("high");
    const created = storage.configure(&create, .{});
    try std.testing.expect(created == .accepted);
    const session = created.accepted.session;
    var observed = try storage.inspectSessionForTesting(session.slice());
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .high), observed.reasoning_effort);
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .high), observed.reasoning_effort_override);

    try submitTestMessage(&storage, &tmp, "effort-one", "effort-one", session.slice(), "first");
    const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

    // Clearing the override selects the catalog default for later work only.
    try std.testing.expect(try configureTestEffort(&storage, "effort-clear", session.slice(), .explicit_null, "") == .accepted);
    observed = try storage.inspectSessionForTesting(session.slice());
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .medium), observed.reasoning_effort);
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, null), observed.reasoning_effort_override);

    // A replacement Attempt keeps its Operation's frozen effort.
    try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "temporary" }, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
    try store_testing.sqlite_only.exec(&storage, "UPDATE model_operation SET retry_due_at_ms=1 WHERE resolution_code IS NULL", .{});
    const retry = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(first.operation_id, retry.operation_id);
    {
        var view: HistoricalView = undefined;
        try storage.openHistoricalView(retry, &view);
        defer view.close();
        try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .high), (try testSettings(&view)).reasoning_effort);
    }

    // Unsupported and outside-grammar values reject without a revision.
    const revision = observed.revision;
    for ([_][]const u8{ "none", "ultra", "HIGH", "" }, 0..) |invalid, index| {
        var key: [32]u8 = undefined;
        const rejected = try configureTestEffort(&storage, try std.fmt.bufPrint(&key, "effort-invalid-{d}", .{index}), session.slice(), .value, invalid);
        try std.testing.expect(rejected == .rejected);
        try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_reasoning_effort, rejected.rejected.code);
        try std.testing.expectEqual(revision, (try storage.inspectSessionForTesting(session.slice())).revision);
    }
    // An omitted field preserves the saved override.
    try std.testing.expect(try configureTestEffort(&storage, "effort-low", session.slice(), .value, "low") == .accepted);
    try std.testing.expect(try configureTestEffort(&storage, "effort-omitted", session.slice(), .omitted, "") == .accepted);
    observed = try storage.inspectSessionForTesting(session.slice());
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .low), observed.reasoning_effort_override);
    var revisions: [8]?protocol.ReasoningEffort = undefined;
    const revision_count = try testingRevisionEfforts(&storage, session.slice(), &revisions);
    try std.testing.expectEqualSlices(?protocol.ReasoningEffort, &.{ .high, null, .low, .low }, revisions[0..revision_count]);

    // A binding without a catalog default has no effective effort and
    // rejects every explicit value.
    const unknown = try configureTestSession(&storage, "effort-unknown");
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, null), (try storage.inspectSessionForTesting(unknown.slice())).reasoning_effort);
    const unknown_rejected = try configureTestEffort(&storage, "effort-unknown-low", unknown.slice(), .value, "low");
    try std.testing.expect(unknown_rejected == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_reasoning_effort, unknown_rejected.rejected.code);

    // A new Operation freezes the effective effort current at its admission,
    // and the frozen value survives reopening.
    try storage.settleModelAttemptFailure(retry, .{ .uncorrelated = "permanent" }, .ordinary, .{});
    try submitTestMessage(&storage, &tmp, "effort-two", "effort-two", session.slice(), "second");
    const second = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expect(try configureTestEffort(&storage, "effort-xhigh", session.slice(), .value, "xhigh") == .accepted);
    try storage.close();
    storage_open = false;
    var reopened: Store = undefined;
    try testingStore(&reopened, &tmp, std.testing.io);
    defer reopened.close() catch unreachable;
    var view: HistoricalView = undefined;
    try reopened.openHistoricalView(second, &view);
    defer view.close();
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .low), (try testSettings(&view)).reasoning_effort);
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .xhigh), (try reopened.inspectSessionForTesting(session.slice())).reasoning_effort);
}

test "historical accepted output completeness and provenance fence both read paths" {
    for ([_]enum { no_base, base, suffix, tied_base, tied_suffix }{ .no_base, .base, .suffix, .tied_base, .tied_suffix }) |scenario| {
        for ([_][:0]const u8{
            "DELETE FROM model_output_item WHERE operation_id=?1",
            "UPDATE model_operation SET output_item_count=output_item_count+1 WHERE operation_id=?1",
            "UPDATE model_operation SET output_item_count=output_item_count-1 WHERE operation_id=?1",
            "DELETE FROM model_output_item WHERE operation_id=?1 AND item_ordinal=2",
            "DELETE FROM model_output_item WHERE operation_id=?1 AND item_ordinal=1",
            "DELETE FROM model_output_item WHERE operation_id=?1 AND item_ordinal=0",
            "UPDATE model_output_item SET item_ordinal=8 WHERE operation_id=?1 AND item_ordinal=1",
            "UPDATE model_output_item SET session_ref='f0re1g' WHERE operation_id=?1",
            "UPDATE model_output_item SET attempt_ordinal=99 WHERE operation_id=?1",
            "UPDATE model_output_item SET session_position=session_position+1000 WHERE operation_id=?1",
        }) |sql| {
            for ([_]bool{ false, true }) |context_read| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try testingStore(&storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
                var output = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var corrupt_id = output.operation_id;
                var tied_id: ?u64 = null;
                if (scenario != .no_base) {
                    try storage.settleModelAttemptFailure(output, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                    const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try settleCompactionForTesting(&storage, &tmp, base, &.{ .reasoning, .compaction, .message });
                    corrupt_id = base.operation_id;
                    if (scenario == .tied_base) tied_id = base.operation_id;
                    output = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                }
                if (scenario == .tied_suffix) {
                    try submitTestMessage(&storage, &tmp, "between", "between", session.slice(), "between");
                    try settleCompactionForTesting(&storage, &tmp, output, &.{ .reasoning, .message });
                    tied_id = output.operation_id;
                    output = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                }
                if (scenario != .base) corrupt_id = output.operation_id;
                try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "later");
                try settleCompactionForTesting(&storage, &tmp, output, &.{ .reasoning, .message, .reasoning });
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                if (tied_id) |previous| {
                    const tie = try sqlite.prepare(storage.sqliteDatabase(), "UPDATE model_operation SET admission_position=" ++
                        "(SELECT admission_position FROM model_operation WHERE operation_id=?1) WHERE operation_id=?2");
                    defer _ = c.sqlite3_finalize(tie);
                    try sqlite.bindU64(tie, 1, previous);
                    try sqlite.bindU64(tie, 2, output.operation_id);
                    try sqlite.expectDone(tie);
                }
                // Message entries now reference their exact raw items. Bypass
                // that FK only while injecting the intended missing-item fault.
                try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
                const mutation = try sqlite.prepare(storage.sqliteDatabase(), sql);
                defer _ = c.sqlite3_finalize(mutation);
                try sqlite.bindU64(mutation, 1, corrupt_id);
                try sqlite.expectDone(mutation);
                try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
                var view: HistoricalView = undefined;
                try storage.openHistoricalView(next, &view);
                defer view.close();
                if (context_read) {
                    try std.testing.expectError(error.CorruptStore, view.coverage());
                } else {
                    try std.testing.expectError(error.CorruptStore, view.nextEntry(0));
                }
                try std.testing.expect(storage.isFenced());
                try std.testing.expectError(error.StoreFenced, testSettings(&view));
            }
        }
    }
}

test "historical context selection work excludes nonmatching Operation population" {
    const Measure = struct {
        steps: u64 = 0,

        fn progress(context: ?*anyopaque) callconv(.c) c_int {
            const counter: *@This() = @ptrCast(@alignCast(context orelse return 1));
            counter.steps += 1;
            return 0;
        }

        fn run(population: usize, with_base: bool) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "retain");
            var current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            if (with_base) {
                try storage.settleModelAttemptFailure(current, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCompactionForTesting(&storage, &tmp, current, &.{ .reasoning, .compaction, .message });
                current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }
            // Isolate search work from payload work: failed assistant/compaction
            // Operations have no accepted output. Their population must not be
            // scanned inside one source/frontier/anchor selection step.
            try store_testing.sqlite_only.exec(&storage, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL", .{});
            const insert = try sqlite.prepare(storage.sqliteDatabase(), "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL " ++
                "SELECT value+1 FROM sequence WHERE value<?1) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose," ++
                "output_reservation,attempt_ordinal,resolution_code,resolved_at) " ++
                "SELECT 100+value,current.turn_id,current.session_ref,current.settings_revision,current.input_cutoff,100+value,value%2," ++
                "0,1,'failed',1 FROM sequence CROSS JOIN model_operation current WHERE current.operation_id=?2");
            defer _ = c.sqlite3_finalize(insert);
            try sqlite.bindU64(insert, 1, population);
            try sqlite.bindU64(insert, 2, current.operation_id);
            try sqlite.expectDone(insert);

            var view: HistoricalView = undefined;
            try storage.openHistoricalView(current, &view);
            defer view.close();
            var measured: @This() = .{};
            c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, progress, &measured);
            defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
            while (!try view.validateOutputsStep()) {}
            try std.testing.expectEqual(with_base, (try view.coverage()).anchor != null);
            return measured.steps;
        }
    };
    for ([_]bool{ false, true }) |with_base| {
        const small = try Measure.run(8, with_base);
        const large = try Measure.run(1024, with_base);
        try std.testing.expect(large <= small + 100);
    }
}

test "model admission work excludes failed historical Operation population" {
    const Measure = struct {
        steps: u64 = 0,

        fn progress(context: ?*anyopaque) callconv(.c) c_int {
            const counter: *@This() = @ptrCast(@alignCast(context orelse return 1));
            counter.steps += 1;
            return 0;
        }

        fn run(population: usize, overflow: bool) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "retain");
            const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            // Keep the actual current Operation newer than all injected history.
            try store_testing.sqlite_only.exec(&storage, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL; UPDATE session SET next_position=100001", .{});
            const insert = try sqlite.prepare(storage.sqliteDatabase(), "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL " ++
                "SELECT value+1 FROM sequence WHERE value<?1) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose," ++
                "output_reservation,attempt_ordinal,resolution_code,resolved_at) " ++
                "SELECT 100+value,current.turn_id,current.session_ref,current.settings_revision,current.input_cutoff,100+value,value%2," ++
                "0,1,'failed',1 FROM sequence CROSS JOIN model_operation current WHERE current.operation_id=?2");
            defer _ = c.sqlite3_finalize(insert);
            try sqlite.bindU64(insert, 1, population);
            try sqlite.bindU64(insert, 2, current.operation_id);
            try sqlite.expectDone(insert);
            try storage.settleModelAttemptFailure(current, .{ .uncorrelated = if (overflow) "overflow" else "provider_http_422" }, if (overflow) .context_overflow else .ordinary, .{});
            try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "pending input");

            var measured: @This() = .{};
            const admitted = blk: {
                c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, progress, &measured);
                defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
                break :blk (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            };
            try std.testing.expectEqual(if (overflow) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(admitted));
            try std.testing.expectEqual(@as(u64, if (overflow) 1 else 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
            return measured.steps;
        }
    };
    for ([_]bool{ false, true }) |overflow| {
        const small = try Measure.run(8, overflow);
        const large = try Measure.run(1024, overflow);
        try std.testing.expect(large <= small + 100);
    }
}

test "model admission work excludes accepted compaction base history" {
    const Measure = struct {
        steps: u64 = 0,
        const Suffix = enum { unchanged, low, high, missing };

        fn progress(context: ?*anyopaque) callconv(.c) c_int {
            const counter: *@This() = @ptrCast(@alignCast(context orelse return 1));
            counter.steps += 1;
            return 0;
        }

        fn run(population: usize, suffix: Suffix) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "retain");
            var current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            for (0..population) |index| {
                try storage.settleModelAttemptFailure(current, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(base));
                try settleCompactionForTesting(&storage, &tmp, base, &.{.compaction});
                current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                if (index + 1 != population) {
                    // Provider-only suffix allows the next overflow recovery
                    // without accumulating retained host input.
                    const call = TestingCall{ .item_id = "old-item", .name = "unknown", .encoded_call_id = "old-call", .decoded_call_id = "old-call", .encoded_arguments = "{}", .decoded_arguments = "{}" };
                    try settleCallsForTestingWithFaults(&storage, &tmp, current, "old-output", &.{call}, .{}, null);
                    current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                }
            }
            if (suffix == .unchanged) {
                try storage.settleModelAttemptFailure(current, .{ .uncorrelated = "network" }, .ordinary, .{});
            } else {
                const call = TestingCall{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" };
                try settleCallsForTestingWithFaults(&storage, &tmp, current, "output", &.{call}, .{}, switch (suffix) {
                    .low => "{\"input_tokens\":1,\"output_tokens\":0}",
                    .high => "{\"input_tokens\":1000,\"output_tokens\":0}",
                    .missing => null,
                    .unchanged => unreachable,
                });
            }
            var patch: protocol.ConfigureCommand = .{};
            try patch.key.set("policy");
            try patch.session.set(session.slice());
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("1000");
            try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "");
            var measured: @This() = .{};
            const admitted = blk: {
                c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, progress, &measured);
                defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
                break :blk (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            };
            try std.testing.expectEqual(if (suffix == .high) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(admitted));
            try std.testing.expectEqual(@as(u64, if (suffix == .high) 1 else 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
            return measured.steps;
        }
    };
    var bounded = true;
    for ([_]Measure.Suffix{ .unchanged, .low, .high, .missing }) |suffix| {
        const small = try Measure.run(8, suffix);
        const large = try Measure.run(128, suffix);
        bounded = bounded and large <= small + 200;
    }
    try std.testing.expect(bounded);
}

test "model admission work excludes usage-covered accepted tool and instruction history" {
    const Measure = struct {
        steps: u64 = 0,
        const Population = enum { rejection, action, instruction };

        fn progress(context: ?*anyopaque) callconv(.c) c_int {
            const counter: *@This() = @ptrCast(@alignCast(context orelse return 1));
            counter.steps += 1;
            return 0;
        }

        fn run(population: usize, kind: Population, compact: bool) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            if (kind == .action) {
                var tools: protocol.ConfigureCommand = .{};
                try tools.key.set("tools");
                try tools.session.set(session.slice());
                tools.configuration.tools.state = .value;
                tools.configuration.tools = try .of(&.{"bash"});
                tools.configuration.permission_mode.state = .value;
                try tools.configuration.permission_mode.value.set("bypass");
                try std.testing.expect(storage.configure(&tools, .{}) == .accepted);
            }
            const call = TestingCall{ .item_id = "item", .name = if (kind == .action) "bash" else "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = if (kind == .action) "{\\\"description\\\":\\\"Run no-op\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}" else "{}", .decoded_arguments = if (kind == .action) "{\"description\":\"Run no-op\",\"cmd\":\"true\",\"timeout_ms\":null}" else "{}" };
            const instructions: [400]u8 = @splat('x');
            for (0..population + 1) |index| {
                var key: [64]u8 = undefined;
                if (kind == .instruction) {
                    var patch: protocol.ConfigureCommand = .{};
                    try patch.key.set(try std.fmt.bufPrint(&key, "instructions-{d}", .{index}));
                    try patch.session.set(session.slice());
                    patch.configuration.instructions = try testingBytesContent(&tmp, "instruction", &instructions);
                    defer patch.removeTemporaryContent(std.testing.io) catch unreachable;
                    try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
                }
                const message_key = try std.fmt.bufPrint(&key, "message-{d}", .{index});
                try submitTestMessage(&storage, &tmp, "input", message_key, session.slice(), "old input");
                const binding = (try storage.admitNextModelAttempt(.{}) orelse return error.MissingPressureInput).permit.binding;
                if (kind == .instruction and index != population) {
                    // Isolate revision history from accepted-output population.
                    try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
                } else {
                    try settleCallsForTestingWithFaults(&storage, &tmp, binding, "output", &.{call}, .{}, if (index == population) (if (compact) (if (kind == .instruction) "{\"input_tokens\":99900,\"output_tokens\":0}" else "{\"input_tokens\":99999,\"output_tokens\":0}") else "{\"input_tokens\":1,\"output_tokens\":0}") else null);
                }
                if (kind == .action) {
                    const action = (try storage.admitNextActionAttempt(1000, .{}) orelse return error.MissingPressureAction).permit.binding;
                    _ = try storage.settleActionAttempt(action, .succeeded, "result", .{});
                    // Measure the actual tool successor: the producer's result
                    // is after its usage/output and must remain in pressure.
                    if (index != population) {
                        const continuation = (try storage.admitNextModelAttempt(.{}) orelse return error.MissingPressureContinuation).permit.binding;
                        try storage.settleModelAttemptFailure(continuation, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
                    }
                }
            }
            var patch: protocol.ConfigureCommand = .{};
            try patch.key.set("policy");
            try patch.session.set(session.slice());
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("100000");
            if (kind == .instruction) {
                // Same-text updates are new input, not content deduplication.
                patch.configuration.instructions = try testingBytesContent(&tmp, "pending-instruction", &instructions);
            }
            defer patch.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
            if (kind == .instruction) {
                var clear: protocol.ConfigureCommand = .{};
                try clear.key.set("clear");
                try clear.session.set(session.slice());
                clear.configuration.instructions = try testingBytesContent(&tmp, "clear-instruction", "");
                defer clear.removeTemporaryContent(std.testing.io) catch unreachable;
                try std.testing.expect(storage.configure(&clear, .{}) == .accepted);
            }
            try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "");
            var measured: @This() = .{};
            const admitted = blk: {
                c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, progress, &measured);
                defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
                break :blk (try storage.admitNextModelAttempt(.{}) orelse return error.MissingPressureAdmission).permit.binding;
            };
            try std.testing.expectEqual(if (compact) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(admitted));
            try std.testing.expectEqual(@as(u64, if (compact) 1 else 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
            if (kind == .instruction) try std.testing.expectEqual(@as(u64, @intCast(population + 1 + @as(usize, if (compact) 0 else 2))), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM conversation_entry WHERE source_revision IS NOT NULL", .{}));
            return measured.steps;
        }
    };
    var bounded = true;
    for ([_]Measure.Population{ .rejection, .action, .instruction }) |kind| {
        for ([_]bool{ false, true }) |compact| {
            const small = try Measure.run(8, kind, compact);
            const large = try Measure.run(128, kind, compact);
            bounded = bounded and large <= small + 200;
        }
    }
    try std.testing.expect(bounded);
}

test "admission fails before COMMIT when a counted write changes other than its selection's rows" {
    const Case = struct { trigger: [:0]const u8, expected: anyerror };
    for ([_]Case{
        .{ .trigger = "CREATE TEMP TRIGGER skip_bind BEFORE UPDATE OF turn_id ON main.message_admission BEGIN SELECT RAISE(IGNORE); END", .expected = error.SelectionChanged },
        .{ .trigger = "CREATE TEMP TRIGGER skip_message BEFORE INSERT ON main.conversation_entry WHEN NEW.entry_kind=1 BEGIN SELECT RAISE(IGNORE); END", .expected = error.ProjectionFailed },
        .{ .trigger = "CREATE TEMP TRIGGER skip_instruction BEFORE INSERT ON main.conversation_entry WHEN NEW.entry_kind=2 BEGIN SELECT RAISE(IGNORE); END", .expected = error.InstructionSelectionFailed },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "counted-admission-config");
        var patch: protocol.ConfigureCommand = .{};
        try patch.key.set("counted-admission-instructions");
        try patch.session.set(session.slice());
        patch.configuration.instructions = try testingBytesContent(&tmp, "counted-admission-instruction", "an instruction");
        defer patch.removeTemporaryContent(std.testing.io) catch unreachable;
        try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
        try submitTestMessage(&storage, &tmp, "counted-admission-input", "counted-admission-message", session.slice(), "work");
        try sqlite.exec(storage.sqliteDatabase(), case.trigger);
        try std.testing.expectError(case.expected, storage.admitModelAttempt(.message, .{}));
        try std.testing.expect(storage.isFenced());
        // The round failed before COMMIT: no Turn, entry or bound Message stays.
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM turn", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM conversation_entry", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE turn_id IS NOT NULL", .{}));
    }
}

test "a failed Turn whose diagnostic is not UTF-8 gives no reset time, as on main" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "diagnostic-bytes");
    try submitTestMessage(&storage, &tmp, "diagnostic-bytes-input", "diagnostic-bytes-message", session.slice(), "q");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(binding, .{ .rejected = .{ .code = "provider_quota", .diagnostic = "{\"refusal\":\"quota\",\"resets_at\":5}", .request_id = .{}, .report = "" } }, .ordinary, .{});
    // The saved record's first byte made one no UTF-8 decoder accepts.
    try sqlite.exec(storage.sqliteDatabase(), "UPDATE content SET payload=CAST(X'FF'||substr(payload,2) AS BLOB) WHERE payload=CAST('{\"refusal\":\"quota\",\"resets_at\":5}' AS BLOB)");
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT changes()", .{}));
    var request: protocol.ActivityPage = .{};
    try request.session.set(session.slice());
    const failed = (try store_core.activityPageForTesting(&storage, request)).work.work.state.failed;
    try std.testing.expectEqualStrings("provider_quota", failed.code.slice());
    try std.testing.expectEqual(@as(?u64, null), failed.resets_at);
    var listed = try testingListRow(&storage, &tmp, session.slice());
    defer listed.deinit();
    try std.testing.expectEqualStrings("failed", listed.get(&.{ "work", "state", "kind" }).string);
    try std.testing.expect(!storage.isFenced());
}

/// The rendered text of the one statement `report_domain.report_failures`
/// names `failed` whose text holds `fragment`.
fn reportStatementForTesting(comptime failed: anyerror, comptime fragment: []const u8) [:0]const u8 {
    return namedStatementForTesting(report_domain.report_failures, failed, fragment);
}

/// Fails the statement whose text is `sql` as a one-row list page reads
/// it, and expects `expected`: main's name for that read's failed step.
fn expectListStepFailure(sql: [:0]const u8, expected: anyerror) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    // A queued Message: the work reads its latest Turn, then the queue.
    const session = try configureTestSession(&storage, "list-names-config");
    try submitTestMessage(&storage, &tmp, "list-names-input", "list-names-message", session.slice(), "q");
    var used = std.atomic.Value(u64).init(0);
    var fault: TestingStatementFault = .{ .sql = sql };
    fault.arm(storage.sqliteDatabase());
    defer fault.disarm(storage.sqliteDatabase());
    try std.testing.expectError(expected, testingSessionList(&storage, &tmp, .{}, &used, 5));
    try std.testing.expect(fault.failed > 0);
    try std.testing.expect(storage.isFenced());
}

test "a list page whose page read fails answers main's SessionReadFailed" {
    try expectListStepFailure(reportStatementForTesting(error.SessionReadFailed, "FROM session WHERE created_seq>?1"), error.SessionReadFailed);
}

test "a list row whose latest Turn read fails answers main's TurnReadFailed" {
    try expectListStepFailure(reportStatementForTesting(error.TurnReadFailed, "SELECT t.turn_id,t.operation_id"), error.TurnReadFailed);
}

test "a list row whose queue read fails answers main's MessageAdmissionReadFailed" {
    try expectListStepFailure(reportStatementForTesting(error.MessageAdmissionReadFailed, "admission_id>?2"), error.MessageAdmissionReadFailed);
}

test "a list row whose settings read fails answers SessionReadFailed" {
    // Main named a failed settings step so, and a failed first Message
    // step CorruptStore; this one read holds both.
    try expectListStepFailure(reportStatementForTesting(error.SessionReadFailed, "JOIN message_admission m"), error.SessionReadFailed);
}

test "a list row that fails to render reports its error before a later row's failed step" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    // The first row has no Message and a label no Session may hold; the
    // second has a first Message, so its settings step is `list_row`'s.
    const first = try configureTestSession(&storage, "render-order-first");
    const second = try configureTestSession(&storage, "render-order-second");
    try submitTestMessage(&storage, &tmp, "render-order-input", "render-order-message", second.slice(), "q");
    var update: [160]u8 = undefined;
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=ON");
    try sqlite.exec(storage.sqliteDatabase(), try std.fmt.bufPrintSentinel(&update, "UPDATE session SET label='two'||char(10)||'lines' WHERE session_ref='{s}'", .{first.slice()}, 0));
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=OFF");
    var used = std.atomic.Value(u64).init(0);
    var fault: TestingStatementFault = .{ .sql = reportStatementForTesting(error.SessionReadFailed, "JOIN message_admission m") };
    fault.arm(storage.sqliteDatabase());
    defer fault.disarm(storage.sqliteDatabase());
    // Main read and rendered the first row before the second's step.
    try std.testing.expectError(error.CorruptStore, testingSessionList(&storage, &tmp, .{}, &used, 5));
    try std.testing.expect(fault.failed > 0);
}

test "a list row whose first Message is missing is CorruptStore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "missing-first-config");
    try submitTestMessage(&storage, &tmp, "missing-first-input", "missing-first-message", session.slice(), "q");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    // The first Turn still names the admission, whose content is gone, so
    // the row's settings read finds no row.
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    try store_testing.sqlite_only.exec(&storage, "DELETE FROM content WHERE content_id IN (SELECT content_id FROM message_admission WHERE session_ref=?1)", .{session.slice()});
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
    var used = std.atomic.Value(u64).init(0);
    try std.testing.expectError(error.CorruptStore, testingSessionList(&storage, &tmp, .{}, &used, 5));
}

test "a list page of mixed work takes its deepest row's rounds, and a pass per row a statement repeats for" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    inline for (0..protocol.session_list_page_size) |index| {
        const shape: TestingWorkShape = @fromBackingInt(@intCast(index % 4));
        _ = try shape.make(&storage, &tmp, std.fmt.comptimePrint("mixed-rounds-{d}", .{index}));
    }
    var root: [protocol.max_store_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &root);
    var used = std.atomic.Value(u64).init(0);
    var capture: report_domain.SessionReportCapture = .{ .io = std.testing.io, .writer = null, .budget = .{ .used = &used, .limit = 1024 * 1024 } };
    try capture.create(root[0..length], 1, false);
    defer capture.deinit();
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    var a: reads_domain.ReadAccess = .open(&entry);
    defer a.deinit();
    const before = storage.testing_content_work.rounds;
    try report_domain.renderSessionList(&a, &.{}, &capture);
    const rounds = storage.testing_content_work.rounds - before;
    var report = try capture.seal();
    defer report.deinit();
    var bytes: [8192]u8 = undefined;
    const read = try report.read(0, bytes[0..@intCast(@min(report.length, bytes.len))]);
    for ([_][]const u8{ "\"kind\":\"idle\"", "\"kind\":\"finished\"", "\"kind\":\"stopped\"", "\"kind\":\"approval\"" }) |kind|
        std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes[0..read], kind)) catch |err| {
            std.debug.print("{s}\n", .{bytes[0..read]});
            return err;
        };
    // The stopped rows' seven: the page; the latest Turns and first-Message
    // seeks; the cutoff, the queue after it, the excluded Message and its
    // stop; the rows' settings. The awaiting rows end after their Actions.
    try std.testing.expectEqual(7, rounds);
    // A pass ends where a round queues a statement again, so a round takes
    // as many as its most repeated statement's rows: 1 for the page, 8 for
    // the rows' first reads, 6 cutoffs, 6 queue seeks, 2 excluded seeks, 2
    // stops, and 6 settings reads of a row with a first Message.
    try std.testing.expectEqual(1 + 8 + 6 + 6 + 2 + 2 + 6, a.passes);
}

test "a Current report's step faults answer the name of the earliest round that steps the table" {
    // Each read keeps main's name; when reads in two rounds fail, the
    // earlier round's name wins. The Action count steps after the tool
    // outcome rule in their round, so a faulted action_operation answers
    // the rule's CallReadFailed, as on main. A list with nothing to show
    // is not read, where main read every list and answered
    // ActionReadFailed for a faulted session_revision.
    inline for (.{
        .{ TestingWorkShape.awaiting, "model_tool_call", error.CallReadFailed },
        .{ TestingWorkShape.awaiting, "action_operation", error.CallReadFailed },
        .{ TestingWorkShape.awaiting, "session_revision", error.ActionReadFailed },
        .{ TestingWorkShape.idle, "session_revision", null },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try case[0].make(&storage, &tmp, "fault-names");
        try store_testing.failReadsOf(&storage, case[1]);
        if (comptime @TypeOf(case[2]) == @TypeOf(null)) {
            std.testing.allocator.free(try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024));
        } else try std.testing.expectError(case[2], testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024));
    }
}

/// Fails the statement whose text is `sql` while `route` reads `session`,
/// and expects `expected`.
fn expectRouteStepFailure(storage: *Store, tmp: *std.testing.TmpDir, route: enum { report, inspection, activity }, session: []const u8, sql: [:0]const u8, expected: anyerror) !void {
    var fault: TestingStatementFault = .{ .sql = sql };
    fault.arm(storage.sqliteDatabase());
    defer fault.disarm(storage.sqliteDatabase());
    const result: anyerror!void = switch (route) {
        .report => if (testingSessionReport(storage, tmp, session, 1024 * 1024)) |report| std.testing.allocator.free(report) else |err| err,
        .inspection => if (storage.inspectSessionForTesting(session)) |_| {} else |err| err,
        .activity => blk: {
            var request: protocol.ActivityPage = .{ .direction = .backward };
            try request.session.set(session);
            break :blk if (store_core.activityPageForTesting(storage, request)) |_| {} else |err| err;
        },
    };
    try std.testing.expectError(expected, result);
    try std.testing.expect(fault.failed > 0);
    try std.testing.expect(storage.isFenced());
}

test "a Proposal check folded into the tool outcome rule answers the rule's CallReadFailed" {
    // Main checked each call's Proposal in a statement of its own, whose
    // failed step went through as StatementFailed; the rule's read now
    // checks it, on an Activity page (`operation_outcome`) and in the
    // Current report (`active_tool_calls`), and answers that read's name.
    inline for (.{
        .{ .activity, namedStatementForTesting(reads_domain.read_failures, null, "SELECT DISTINCT ?1 AS operation_id") },
        .{ .report, namedStatementForTesting(report_domain.session_count_failures, null, "SELECT DISTINCT operation.operation_id") },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try TestingWorkShape.awaiting.make(&storage, &tmp, "proposal-fold");
        try expectRouteStepFailure(&storage, &tmp, case[0], session.slice(), case[1], error.CallReadFailed);
    }
}

test "a Current report's presentation reads answer their list's name" {
    // Main read each listed call's line and fields apart and named their
    // failed steps CorruptStore; they are the list's own columns now. The
    // Turn proposes an asked-for call, whose Action waits, and a call of
    // an unknown tool, which is rejected.
    inline for (.{
        .{ namedStatementForTesting(report_domain.current_failures, null, "a.resolution_code IS NULL ORDER BY a.action_id"), error.ActionReadFailed },
        .{ namedStatementForTesting(report_domain.current_failures, null, "CROSS JOIN content rejection"), error.CallReadFailed },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "presentation-fold");
        try submitTestMessage(&storage, &tmp, "presentation-fold-input", "presentation-fold-message", session.slice(), "call");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const calls = [_]TestingCall{
            .{ .item_id = "presentation-fold-asked", .name = "bash", .encoded_call_id = "presentation-fold-asked", .decoded_call_id = "presentation-fold-asked", .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}" },
            .{ .item_id = "presentation-fold-unknown", .name = "unknown", .encoded_call_id = "presentation-fold-unknown", .decoded_call_id = "presentation-fold-unknown", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        };
        try settleCallsForTesting(&storage, &tmp, binding, "presentation-fold-output", &calls);
        try expectRouteStepFailure(&storage, &tmp, .report, session.slice(), case[0], case[1]);
    }
}

test "admission's context read answers CorruptStore, as admission names it" {
    // Main checked whether the context changed in a statement of its own,
    // whose failed step went through as StatementFailed, and named the
    // estimate's CorruptStore; `admission_context` reads both. The second
    // Message follows a Turn with usage under a trigger, so admission
    // weighs the context, and the report estimates it.
    for ([_]bool{ false, true }) |report| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "context-fold");
        var patch: protocol.ConfigureCommand = .{};
        try patch.key.set("context-fold-trigger");
        try patch.session.set(session.slice());
        patch.configuration.compaction_trigger.state = .value;
        try patch.configuration.compaction_trigger.value.set("1000");
        try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
        try submitTestMessage(&storage, &tmp, "context-fold-one", "context-fold-one", session.slice(), "one");
        const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try submitTestMessage(&storage, &tmp, "context-fold-two", "context-fold-two", session.slice(), "two");
        try settleCallsForTestingWithFaults(&storage, &tmp, first, "context-fold-output", &.{}, .{}, "{\"input_tokens\":10,\"output_tokens\":0}");
        var fault: TestingStatementFault = .{ .sql = namedStatementForTesting(model_admission_domain.compaction_failures, null, "since AS (SELECT") };
        fault.arm(storage.sqliteDatabase());
        defer fault.disarm(storage.sqliteDatabase());
        if (report)
            try std.testing.expectError(error.CorruptStore, testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024))
        else
            try std.testing.expectError(error.CorruptStore, storage.admitNextModelAttempt(.{}));
        try std.testing.expect(fault.failed > 0);
        try std.testing.expect(storage.isFenced());
    }
}

test "a round's failed step is named by the statement that failed" {
    // `failedOn` records the failed runner's text; each pair of a round
    // names its own failure, and a statement that did not fail names none.
    const Pair = struct {
        const first = rsql.Read(.{
            .sql = "SELECT count(*) AS sessions FROM session WHERE session_ref<>?1",
            .Args = struct { session_ref: []const u8 },
            .Row = struct { sessions: u64 },
            .cardinality = .one,
        });
        const second = rsql.Read(.{
            .sql = "SELECT count(*) AS revisions FROM session_revision WHERE session_ref<>?1",
            .Args = struct { session_ref: []const u8 },
            .Row = struct { revisions: u64 },
            .cardinality = .one,
        });
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    _ = try configureTestSession(&storage, "failed-on");
    inline for (.{ .{ Pair.first, error.FirstFailed }, .{ Pair.second, error.SecondFailed } }) |case| {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var a: reads_domain.ReadAccess = .open(&entry);
        defer a.deinit();
        var first: Pair.first.Result = undefined;
        var second: Pair.second.Result = undefined;
        a.read(Pair.first, .{ .session_ref = "" }, &first);
        a.read(Pair.second, .{ .session_ref = "" }, &second);
        var fault: TestingStatementFault = .{ .sql = case[0].sql };
        fault.arm(storage.sqliteDatabase());
        defer fault.disarm(storage.sqliteDatabase());
        try std.testing.expectError(case[1], store_access.runNamed(&a, .{ .{ Pair.first, error.FirstFailed }, .{ Pair.second, error.SecondFailed } }, error.OtherFailed));
        try std.testing.expect(fault.failed > 0);
        try std.testing.expect(a.failedOn(case[0]));
        try std.testing.expect(a.failedOn(Pair.first) != a.failedOn(Pair.second));
    }
}

test "Session inspection's count reads answer main's names" {
    // Inspection reads the Current report's counts and the rule in the
    // same rounds, under main's names.
    inline for (.{
        .{ "SELECT operation.operation_id FROM", error.CallReadFailed },
        .{ "SELECT DISTINCT operation.operation_id", error.CallReadFailed },
        .{ "count(*) AS actions", error.ActionReadFailed },
        .{ "count(*) AS rejected", error.CallReadFailed },
        .{ "count(*) AS pending", error.MessageAdmissionReadFailed },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try TestingWorkShape.awaiting.make(&storage, &tmp, "inspection-names");
        // A queued Message, so the pending count steps.
        try submitTestMessage(&storage, &tmp, "inspection-names-queued", "inspection-names-queued", session.slice(), "later");
        try expectRouteStepFailure(&storage, &tmp, .inspection, session.slice(), namedStatementForTesting(report_domain.session_count_failures, null, case[0]), case[1]);
    }
}

/// The statements the Store's cached statements ran and the VM steps they
/// took since the last call, which resets them.
fn cachedWorkForTesting(storage: *Store) struct { statements: i64, steps: i64 } {
    var statements: i64 = 0;
    var steps: i64 = 0;
    for (storage.engine.sqlite.statements.slots) |slot| if (slot.statement) |statement| {
        statements += c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_RUN, 1);
        steps += c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 1);
    };
    return .{ .statements = statements, .steps = steps };
}

/// The cost fixture: an answered greeting, a reconfigure, `cycles` tool
/// cycles, a stopped Turn with a Message the stop excluded, and a Turn
/// awaiting one asked Bash call beside a rejected unknown one.
fn costFixtureForTesting(storage: *Store, tmp: *std.testing.TmpDir, cycles: usize) !protocol.Bounded(protocol.max_session_bytes) {
    const session = try configureTestSessionAsk(storage, "probe-config");
    const answer = [_]TestingAnswerPart{.{ .encoded = "hello there", .decoded = "hello there" }};
    try answerTestTurn(storage, tmp, session.slice(), "probe-greeting", &answer);
    var reconfigure: protocol.ConfigureCommand = .{};
    try reconfigure.key.set("probe-reconfigure");
    try reconfigure.session.set(session.slice());
    reconfigure.configuration.instructions = try testingBytesContent(tmp, "probe-instructions", "Be brief and careful.");
    reconfigure.configuration.label.state = .value;
    try reconfigure.configuration.label.value.set("probe label");
    try std.testing.expect(storage.configure(&reconfigure, .{}) == .accepted);
    for (0..cycles) |index| try costCycleForTesting(storage, tmp, session.slice(), index);
    try submitTestMessage(storage, tmp, "probe-stopped-input", "probe-stopped-key", session.slice(), "start something long");
    _ = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
    try submitTestMessage(storage, tmp, "probe-excluded-input", "probe-excluded-key", session.slice(), "and then this");
    var stop = try completeSessionStop("probe-stop", session.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    var late_stop = try completeSessionStop("probe-stop-idle", session.slice());
    _ = storage.stopSession(&late_stop, .{});
    try submitTestMessage(storage, tmp, "probe-awaiting-input", "probe-awaiting-key", session.slice(), "check the disk");
    const binding = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-d", .name = "bash", .encoded_call_id = "call-d", .decoded_call_id = "call-d", .encoded_arguments = "{\\\"description\\\":\\\"Disk usage\\\",\\\"cmd\\\":\\\"df -h\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Disk usage\",\"cmd\":\"df -h\",\"timeout_ms\":null}" },
        .{ .item_id = "item-e", .name = "unknown", .encoded_call_id = "call-e", .decoded_call_id = "call-e", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    };
    try settleCallsForTesting(storage, tmp, binding, "probe-awaiting-calls", &calls);
    return session;
}

test "a Current report and inspection do no more work than main at the cost fixture" {
    // Main's counts at 72db6de9, each the second, cached, run on this
    // fixture: statements run and VM steps, the report then inspection.
    inline for (.{
        .{ 1, [4]i64{ 37, 2954, 12, 633 } },
        .{ 8, [4]i64{ 37, 5674, 12, 633 } },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try costFixtureForTesting(&storage, &tmp, case[0]);
        std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024 * 1024, .current));
        _ = cachedWorkForTesting(&storage);
        std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024 * 1024, .current));
        const report = cachedWorkForTesting(&storage);
        _ = try storage.inspectSessionForTesting(session.slice());
        _ = cachedWorkForTesting(&storage);
        _ = try storage.inspectSessionForTesting(session.slice());
        const inspection = cachedWorkForTesting(&storage);
        const main = case[1];
        try std.testing.expect(report.statements > 0 and inspection.statements > 0);
        std.testing.expect(report.statements <= main[0] and report.steps <= main[1] and inspection.statements <= main[2] and inspection.steps <= main[3]) catch |err| {
            std.debug.print("report {d} statements, {d} steps; inspection {d}, {d}\n", .{ report.statements, report.steps, inspection.statements, inspection.steps });
            return err;
        };
    }
}

test "a Current report's work grows linearly in one Operation's calls, as main's did" {
    // Main's counts at 3b3d941a, each the second, cached, report: its
    // statements and VM steps with 16, 64 and 256 rejected calls in one
    // Operation. Each listed call's publication is its Operation's, read
    // once per Operation, not once per call.
    inline for (.{
        .{ 16, [2]i64{ 93, 12411 } },
        .{ 64, [2]i64{ 285, 47067 } },
        .{ 256, [2]i64{ 1053, 185691 } },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try rejectedCallsForTesting(&storage, &tmp, case[0]);
        std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024 * 1024, .current));
        _ = cachedWorkForTesting(&storage);
        std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024 * 1024, .current));
        const report = cachedWorkForTesting(&storage);
        try std.testing.expect(report.statements > 0);
        std.testing.expect(report.statements <= case[1][0] and report.steps <= case[1][1]) catch |err| {
            std.debug.print("{d} calls: {d} statements, {d} steps\n", .{ case[0], report.statements, report.steps });
            return err;
        };
    }
}

/// How many times `S` ran since the last call for it.
fn testingRuns(storage: *Store, comptime S: type) i64 {
    const statement = storage.engine.sqlite.statements.find(S.sql.ptr) orelse return 0;
    return c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_RUN, 1);
}

/// How many VM steps `S` took since the last call for it.
fn testingSteps(storage: *Store, comptime S: type) i64 {
    const statement = storage.engine.sqlite.statements.find(S.sql.ptr) orelse return 0;
    return c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 1);
}

test "Full interruptions seek their Session's commands, within 90% of main's steps" {
    // Main's interruption statement stepped 6612, 22540 and 90124 times on
    // these Sessions (origin/main 2e8e8353, the same rejected commands),
    // scanning every interruption and sorting the Session's. Each chunk
    // here seeks `core_command_target_order` from where the one before
    // stopped; a chunk that scanned and sorted again took 8 times main's
    // steps at 4096. Its interruption row is a LEFT JOIN (`rsql.Page`),
    // about 4 steps a row more than the CROSS JOIN before it.
    const main_steps = [_]i64{ 6612, 22540, 90124 };
    for ([_]usize{ 300, 1024, 4096 }, main_steps) |count, main| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "interruptions-scale-config");
        for (0..count) |index| {
            var key: [32]u8 = undefined;
            var command: protocol.ModelInterruptionCommand = .{ .turn_id = 0, .operation_id = 1 };
            try command.key.set(try std.fmt.bufPrint(&key, "i-{d}", .{index}));
            try command.session.set(session.slice());
            try std.testing.expect(storage.interruptModel(&command, .{}) == .rejected);
        }
        std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024 * 1024, .full));
        _ = testingSteps(&storage, report_domain.full_interruptions);
        _ = testingRuns(&storage, report_domain.full_interruptions);
        const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024 * 1024, .full);
        defer std.testing.allocator.free(full);
        const steps = testingSteps(&storage, report_domain.full_interruptions);
        // 5747, 19565 and 78305 steps when this was written.
        if (steps * 10 > main * 9) std.debug.print("{d} interruptions: {d} steps, main {d}\n", .{ count, steps, main });
        try std.testing.expect(steps * 10 <= main * 9);
        // One statement per 256 rows.
        try std.testing.expectEqual(@as(i64, @intCast((count - 1) / 256 + 1)), testingRuns(&storage, report_domain.full_interruptions));
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
        defer parsed.deinit();
        const listed = parsed.value.object.get("full").?.object.get("model_interruptions").?.array.items;
        try std.testing.expectEqual(count, listed.len);
        for (listed, 0..) |row, index| {
            var key: [32]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&key, "i-{d}", .{index}), row.object.get("command_key").?.string);
        }
    }
}

/// The SQLite plan line a Page arm's first SEARCH must be, from what it
/// walks: e.g. `SEARCH tool_call USING INDEX model_tool_call_session_order
/// (session_ref=? AND (operation_id,call_ordinal)>(?,?))`, with `COVERING`
/// before `INDEX` when `covering`.
fn keysetPlanLine(comptime arm: rsql.Walk.Arm, comptime covering: bool) []const u8 {
    comptime {
        var text: []const u8 = "SEARCH " ++ arm.alias ++ " USING " ++ (if (arm.index) |index| (if (covering) "COVERING " else "") ++ "INDEX " ++ index else "PRIMARY KEY") ++ " (";
        for (arm.prefix) |column| text = text ++ column ++ "=? AND ";
        if (arm.key.len == 1) return text ++ arm.key[0] ++ ">?)";
        var columns: []const u8 = "";
        var parameters: []const u8 = "";
        for (arm.key, 0..) |column, k| {
            columns = columns ++ (if (k == 0) "" else ",") ++ column;
            parameters = parameters ++ (if (k == 0) "" else ",") ++ "?";
        }
        return text ++ "(" ++ columns ++ ")>(" ++ parameters ++ "))";
    }
}

/// Fails unless `S`'s plan starts each arm, outside its subqueries, with
/// exactly the SEARCH its walk derives (`keysetPlanLine`), merges a
/// compound's arms without a sort, and has no SCAN and no temporary
/// B-tree anywhere, subqueries included.
fn expectKeysetPlan(storage: *Store, comptime S: type) !void {
    const walk = S.page_walk;
    const text = "EXPLAIN QUERY PLAN " ++ S.sql;
    var statement: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(storage.sqliteDatabase(), text.ptr, @intCast(text.len), &statement, null));
    defer _ = c.sqlite3_finalize(statement);
    var subqueries: [64]c_int = undefined;
    var subquery_count: usize = 0;
    var searched: [64]c_int = undefined;
    var arm: usize = 0;
    var merged = false;
    var plan: [4096]u8 = undefined;
    var plan_length: usize = 0;
    const sound = while (c.sqlite3_step(statement) == c.SQLITE_ROW) {
        const id = c.sqlite3_column_int(statement, 0);
        const parent = c.sqlite3_column_int(statement, 1);
        const detail = std.mem.span(c.sqlite3_column_text(statement, 3));
        if (std.fmt.bufPrint(plan[plan_length..], "  {d} {d} {s}\n", .{ id, parent, detail })) |line| plan_length += line.len else |_| {}
        if (std.mem.indexOf(u8, detail, "TEMP B-TREE") != null or std.mem.startsWith(u8, detail, "SCAN ")) break false;
        if (std.mem.eql(u8, detail, "MERGE (UNION ALL)")) merged = true;
        if (std.mem.indexOf(u8, detail, "SUBQUERY") != null or std.mem.indexOfScalar(c_int, subqueries[0..subquery_count], parent) != null) {
            subqueries[subquery_count] = id;
            subquery_count += 1;
            continue;
        }
        if (!std.mem.startsWith(u8, detail, "SEARCH ")) continue;
        if (std.mem.indexOfScalar(c_int, searched[0..arm], parent) != null) continue;
        if (arm == walk.arms.len) break false;
        const matched = inline for (walk.arms, 0..) |path, i| {
            if (i == arm) break std.mem.eql(u8, detail, comptime keysetPlanLine(path, false)) or std.mem.eql(u8, detail, comptime keysetPlanLine(path, true));
        } else false;
        if (!matched) break false;
        searched[arm] = parent;
        arm += 1;
    } else arm == walk.arms.len and (walk.arms.len == 1 or merged);
    if (sound) return;
    std.debug.print("{s}\n{s}", .{ S.sql, plan[0..plan_length] });
    inline for (walk.arms) |path| std.debug.print("expected: {s}\n", .{comptime keysetPlanLine(path, false)});
    return error.TestUnexpectedResult;
}

test "every Full list walks its own index from the keyset: a chunk seeks, and sorts nothing" {
    // Each list's Page names the index each arm walks on its own table,
    // and the plan's first SEARCH of each arm must be exactly that
    // index's range from the keyset. A chunk that sorted (P2 #2), started
    // on another table (P2 #1) or searched a parent's rows (P2 #3) read
    // again rows the chunks before it read: one Operation's 4096 rejected
    // calls took 89777216 steps.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    inline for (report_domain.full_pages) |S| try expectKeysetPlan(&storage, S);
}

/// Codex's mixed history at `count`: one Operation with `count` calls,
/// Bash and unknown in turn, every Bash call's Action denied (last first,
/// so acceptance order is not call order), then `count` answered Turns
/// with no call; and another Session's `count` rejected calls. Returns
/// each Full statement's steps for the second of two reports.
fn mixedHistorySteps(count: usize) ![report_domain.full_pages.len]i64 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = [_][]const u8{"{\"type\":\"message\",\"id\":\"mixed-answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Done.\"}]}"};
    const other = try configureTestSessionAsk(&storage, "mixed-other-config");
    const session = try configureTestSessionAsk(&storage, "mixed-config");
    for ([_][]const u8{ other.slice(), session.slice() }, [_]bool{ false, true }) |target, mine| {
        try submitTestMessage(&storage, &tmp, if (mine) "mixed-input" else "mixed-other-input", if (mine) "mixed-key" else "mixed-other-key", target, "many calls");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const calls = try arena.allocator().alloc(TestingCall, count);
        for (calls, 0..) |*call, index| {
            const bash = mine and index % 2 == 0;
            const id = try std.fmt.allocPrint(arena.allocator(), "{s}-{d}", .{ if (mine) "mixed" else "other", index });
            call.* = .{
                .item_id = id,
                .name = if (bash) "bash" else "unknown",
                .encoded_call_id = id,
                .decoded_call_id = id,
                .encoded_arguments = if (bash) "{\\\"description\\\":\\\"List files\\\",\\\"cmd\\\":\\\"ls\\\",\\\"timeout_ms\\\":null}" else "{}",
                .decoded_arguments = if (bash) "{\"description\":\"List files\",\"cmd\":\"ls\",\"timeout_ms\":null}" else "{}",
            };
        }
        try settleCallsForTesting(&storage, &tmp, binding, if (mine) "mixed" else "mixed-other", calls);
        if (!mine) {
            const answered = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
            try settleItemsForTesting(&storage, &tmp, answered, &items, "Done.");
            continue;
        }
        const last = try store_testing.sqlite_only.queryU64(&storage, "SELECT max(action_id) FROM action_operation", .{});
        for (0..count / 2) |step| {
            var key: [32]u8 = undefined;
            try denyForTesting(&storage, target, try std.fmt.bufPrint(&key, "mixed-deny-{d}", .{step}), last - step);
        }
        const continued = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
        try settleItemsForTesting(&storage, &tmp, continued, &items, "Done.");
        for (0..count) |index| {
            var name: [32]u8 = undefined;
            var key: [32]u8 = undefined;
            try submitTestMessage(&storage, &tmp, try std.fmt.bufPrint(&name, "mixed-in-{d}", .{index}), try std.fmt.bufPrint(&key, "mixed-turn-{d}", .{index}), target, "input");
            const turn = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleItemsForTesting(&storage, &tmp, turn, &items, "Done.");
        }
    }
    std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 256 * 1024 * 1024, .full));
    inline for (report_domain.full_pages) |S| _ = testingSteps(&storage, S);
    const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 256 * 1024 * 1024, .full);
    defer std.testing.allocator.free(full);
    var steps: [report_domain.full_pages.len]i64 = undefined;
    inline for (report_domain.full_pages, 0..) |S, i| steps[i] = testingSteps(&storage, S);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
    defer parsed.deinit();
    const lists = parsed.value.object.get("full").?.object;
    try std.testing.expectEqual(count, lists.get("tool_calls").?.array.items.len);
    try std.testing.expectEqual(count, lists.get("tool_results").?.array.items.len);
    try std.testing.expectEqual(count / 2, lists.get("actions").?.array.items.len);
    try std.testing.expectEqual(count + 2, lists.get("model_operations").?.array.items.len);
    return steps;
}

test "Full lists grow linearly on a mixed history" {
    // Pins growth, not counts: each Full statement's steps at 4N are at
    // most 4.5 times those at N. A statement whose chunks reopened a walk
    // of the call-free Operations after the current one grew 10 and 12
    // times (a9a0f7eb's calls, 15413 to 160133 steps, and results, 23494
    // to 290902).
    const small = try mixedHistorySteps(128);
    const large = try mixedHistorySteps(512);
    var linear = true;
    inline for (report_domain.full_pages, small, large) |S, at_n, at_4n| {
        if (at_4n * 2 > at_n * 9) {
            std.debug.print("{d} steps at N, {d} at 4N: {s}\n", .{ at_n, at_4n, S.sql });
            linear = false;
        }
    }
    try std.testing.expect(linear);
}

test "Full calls and results of one Operation take a seek per chunk, within twice main's steps" {
    // One Operation's 4096 rejected calls: main's two statements stepped
    // 249888 times (origin/main 2e8e8353), and read each content's
    // metadata apart, 245810 more; these read it in their rows. A chunk
    // that searched the Operation's calls again took 89777216 steps for
    // the report.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "one-operation-config");
    try submitTestMessage(&storage, &tmp, "one-operation-input", "one-operation-key", session.slice(), "many calls");
    const binding = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
    const count = 4096;
    const calls = try std.testing.allocator.alloc(TestingCall, count);
    defer std.testing.allocator.free(calls);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (calls, 0..) |*call, index| {
        const id = try std.fmt.allocPrint(arena.allocator(), "one-{d}", .{index});
        call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "{}", .decoded_arguments = "{}" };
    }
    try settleCallsForTesting(&storage, &tmp, binding, "one-operation", calls);
    std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 256 * 1024 * 1024, .full));
    _ = testingSteps(&storage, report_domain.full_calls);
    _ = testingSteps(&storage, report_domain.full_results);
    const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 256 * 1024 * 1024, .full);
    defer std.testing.allocator.free(full);
    const steps = testingSteps(&storage, report_domain.full_calls) + testingSteps(&storage, report_domain.full_results);
    // 480136 when this was written.
    try std.testing.expect(steps <= 2 * 249888);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
    defer parsed.deinit();
    for ([_][]const u8{ "tool_calls", "tool_results" }) |name| {
        const listed = parsed.value.object.get("full").?.object.get(name).?.array.items;
        try std.testing.expectEqual(@as(usize, count), listed.len);
        for (listed, 0..) |row, index| {
            var ordinal: [16]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&ordinal, "{d}", .{index}), row.object.get("call_ordinal").?.string);
        }
    }
}

test "a Full list takes a statement per 256 rows, and lists each row once in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "chunked-stops-config");
    // An interrupted Operation: the interruptions list follows the stops
    // in their run, and renders only once the stops finished.
    try submitTestMessage(&storage, &tmp, "chunked-interrupt", "chunked-interrupt", session.slice(), "interrupt me");
    const interrupted = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var interrupt = try completeModelInterruption("chunked-interrupt-command", session.slice(), interrupted);
    try std.testing.expect(storage.interruptModel(&interrupt, .{}) == .accepted);
    if (try storage.admitNextModelAttempt(.{})) |successor| {
        const items = [_][]const u8{"{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}"};
        try settleItemsForTesting(&storage, &tmp, successor.permit.binding, &items, "ok");
    }
    for ([_]usize{ 256, 257, 513 }) |rows| {
        while (try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM core_command WHERE kind=3", .{}) < rows) {
            var key: [32]u8 = undefined;
            var stop = try completeSessionStop(try std.fmt.bufPrint(&key, "chunked-stop-{d:0>4}", .{try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM core_command WHERE kind=3", .{})}), session.slice());
            // An idle Session accepts each stop.
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
        }
        _ = testingRuns(&storage, report_domain.full_stops);
        _ = testingRuns(&storage, report_domain.full_interruptions);
        _ = testingRuns(&storage, report_domain.full_results);
        const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 8 * 1024 * 1024, .full);
        defer std.testing.allocator.free(full);
        // 256 rows and the 257th row's absence fit one statement; a 257th
        // row takes a second, and a 513th a third. The interruptions, read
        // ahead beside the stops' first chunk only, are read again once
        // the stops finish; the results, read ahead and found empty, are
        // not.
        const chunks: i64 = @intCast((rows + 255) / 256);
        try std.testing.expectEqual(chunks, testingRuns(&storage, report_domain.full_stops));
        try std.testing.expectEqual(@min(chunks, 2), testingRuns(&storage, report_domain.full_interruptions));
        try std.testing.expectEqual(@as(i64, 1), testingRuns(&storage, report_domain.full_results));
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
        defer parsed.deinit();
        const stops = parsed.value.object.get("full").?.object.get("session_stops").?.array.items;
        try std.testing.expectEqual(rows, stops.len);
        for (stops, 0..) |stop, index| {
            var key: [32]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&key, "chunked-stop-{d:0>4}", .{index}), stop.object.get("command_key").?.string);
        }
        const interruptions = parsed.value.object.get("full").?.object.get("model_interruptions").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), interruptions.len);
        try std.testing.expectEqualStrings("chunked-interrupt-command", interruptions[0].object.get("command_key").?.string);
    }
    try std.testing.expect(!storage.isFenced());
}

test "Full revisions read no statement past a last revision that shows content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "last-revision-config");
    var reconfigure: protocol.ConfigureCommand = .{};
    try reconfigure.key.set("last-revision");
    try reconfigure.session.set(session.slice());
    reconfigure.configuration.instructions = try testingBytesContent(&tmp, "last-revision-instructions", "Be brief.");
    try std.testing.expect(storage.configure(&reconfigure, .{}) == .accepted);
    _ = testingRuns(&storage, report_domain.full_revisions);
    std.testing.allocator.free(try testingFullHistory(&storage, &tmp, session.slice(), null));
    // The chunk stops after the second revision to stream its
    // instructions; its row's `newest` says no revision follows.
    try std.testing.expectEqual(@as(i64, 1), testingRuns(&storage, report_domain.full_revisions));
}

test "a Full list keeps the rows whose content it shows whole for after their chunk, in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "chunked-messages-config");
    // Each Message's text is longer than one content window. Two chunks'
    // kept rows take two statements, the second finding no row after its
    // last; one more row takes a third.
    const pending = report_domain.Messages.kept_rows;
    var text: [2100]u8 = undefined;
    var count: usize = 0;
    for ([_]usize{ 2 * pending, 2 * pending + 1 }, [_]i64{ 2, 3 }) |rows, statements| {
        while (count < rows) : (count += 1) {
            var name: [32]u8 = undefined;
            var key: [32]u8 = undefined;
            @memset(&text, @intCast('a' + count));
            try submitTestMessage(&storage, &tmp, try std.fmt.bufPrint(&name, "chunked-message-{d}", .{count}), try std.fmt.bufPrint(&key, "chunked-message-{d}", .{count}), session.slice(), &text);
        }
        _ = testingRuns(&storage, report_domain.full_messages);
        const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 8 * 1024 * 1024, .full);
        defer std.testing.allocator.free(full);
        try std.testing.expectEqual(statements, testingRuns(&storage, report_domain.full_messages));
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
        defer parsed.deinit();
        const messages = parsed.value.object.get("full").?.object.get("messages").?.array.items;
        try std.testing.expectEqual(rows, messages.len);
        for (messages, 0..) |message, index| {
            var key: [32]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&key, "chunked-message-{d}", .{index}), message.object.get("command_key").?.string);
            @memset(&text, @intCast('a' + index));
            try std.testing.expectEqualStrings(&text, message.object.get("content").?.object.get("text").?.string);
        }
    }
}

test "Full Messages refuse a position that leaves one out or lists one before an earlier admission" {
    const faults = [_][:0]const u8{
        "UPDATE message_admission SET admission_position=NULL WHERE command_key='ordered-message-1'",
        "UPDATE message_admission SET admission_position=1000000 WHERE command_key='ordered-message-0'",
        // A repeated position: the keyset does not grow.
        "UPDATE message_admission SET admission_position=(SELECT admission_position FROM message_admission WHERE command_key='ordered-message-0') WHERE command_key='ordered-message-1'",
    };
    for ([_]?[:0]const u8{null} ++ faults) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "ordered-messages-config");
        try submitTestMessage(&storage, &tmp, "ordered-message-0", "ordered-message-0", session.slice(), "first");
        try submitTestMessage(&storage, &tmp, "ordered-message-1", "ordered-message-1", session.slice(), "second");
        if (fault) |sql| {
            try sqlite.exec(storage.sqliteDatabase(), sql);
            try std.testing.expectError(error.CorruptStore, testingFullHistory(&storage, &tmp, session.slice(), null));
        } else std.testing.allocator.free(try testingFullHistory(&storage, &tmp, session.slice(), null));
    }
}

test "Full history refuses a decision or interruption command without its row, or one naming another Session" {
    // Main joined each row to its command and skipped a command without
    // one; the Page walks the commands and LEFT JOINs the row.
    const faults = [_][:0]const u8{
        "DELETE FROM permission_decision_command WHERE command_key='missing-row-decision'",
        "DELETE FROM model_interruption_command WHERE command_key='missing-row-interruption'",
        "UPDATE model_interruption_command SET session_ref='elsewhere' WHERE command_key='missing-row-interruption'",
    };
    for ([_]?[:0]const u8{null} ++ faults) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "missing-row-config");
        var decision: protocol.PermissionDecisionCommand = .{ .action_id = 999999, .decision = .deny };
        try decision.key.set("missing-row-decision");
        try decision.session.set(session.slice());
        try std.testing.expect(storage.decidePermission(&decision, .{}) == .rejected);
        var interruption: protocol.ModelInterruptionCommand = .{ .turn_id = 0, .operation_id = 1 };
        try interruption.key.set("missing-row-interruption");
        try interruption.session.set(session.slice());
        try std.testing.expect(storage.interruptModel(&interruption, .{}) == .rejected);
        if (fault) |sql| {
            try sqlite.exec(storage.sqliteDatabase(), sql);
            try std.testing.expectError(error.CorruptStore, testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full));
        } else std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full));
    }
}

test "Full history reads a payload's declared bytes: a short one fails, a longer one shows its prefix, as on main" {
    // `content`'s CHECK keeps payload and byte_length equal; the test
    // turns it off to store a payload of the wrong length.
    for ([_][]const u8{ "", "short", "longer" }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "payload-config");
        try submitTestMessage(&storage, &tmp, "payload-message", "payload-message", session.slice(), "payload");
        const id = "(SELECT content_id FROM message_admission WHERE command_key='payload-message')";
        if (std.mem.eql(u8, case, "short")) {
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=ON; UPDATE content SET payload=CAST('pay' AS BLOB) WHERE content_id=" ++ id ++ "; PRAGMA ignore_check_constraints=OFF");
            try std.testing.expectError(error.ContentReadFailed, testingFullHistory(&storage, &tmp, session.slice(), null));
            continue;
        }
        if (std.mem.eql(u8, case, "longer")) try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=ON; UPDATE content SET payload=CAST('payload and more' AS BLOB) WHERE content_id=" ++ id ++ "; PRAGMA ignore_check_constraints=OFF");
        const full = try testingFullHistory(&storage, &tmp, session.slice(), null);
        defer std.testing.allocator.free(full);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
        defer parsed.deinit();
        const message = parsed.value.object.get("full").?.object.get("messages").?.array.items[0];
        try std.testing.expectEqualStrings("payload", message.object.get("content").?.object.get("text").?.string);
    }
}

test "Full history answers a later row's failure before a kept row's content, where main read the content first" {
    // The first Message shows its content whole, so its chunk keeps it;
    // the second is listed ahead of an earlier admission, which its row
    // check refuses in the pass, before the first's short payload is read.
    for ([_]bool{ false, true }) |later_fails| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "double-fault-config");
        try submitTestMessage(&storage, &tmp, "double-fault-0", "double-fault-0", session.slice(), "first");
        try submitTestMessage(&storage, &tmp, "double-fault-1", "double-fault-1", session.slice(), "second");
        try submitTestMessage(&storage, &tmp, "double-fault-2", "double-fault-2", session.slice(), "third");
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA ignore_check_constraints=ON; UPDATE content SET payload=CAST('fi' AS BLOB) " ++
            "WHERE content_id=(SELECT content_id FROM message_admission WHERE command_key='double-fault-0'); PRAGMA ignore_check_constraints=OFF");
        if (later_fails) {
            // The third is listed between the first and the second.
            try store_testing.sqlite_only.exec(&storage, "UPDATE message_admission SET admission_position=(SELECT admission_position FROM message_admission WHERE command_key='double-fault-0') " ++
                "WHERE command_key='double-fault-2'; UPDATE message_admission SET admission_position=admission_position+10 WHERE command_key='double-fault-1'", .{});
            try std.testing.expectError(error.CorruptStore, testingFullHistory(&storage, &tmp, session.slice(), null));
        } else try std.testing.expectError(error.ContentReadFailed, testingFullHistory(&storage, &tmp, session.slice(), null));
    }
}

test "Full history's step faults keep main's names, and its content and stop reads take their list's" {
    // Main read the Messages' stops in a statement of their own
    // (SessionStopReadFailed) and every content's metadata apart
    // (CorruptStore); each is a column of its list's statement now. The
    // Current facts read both tables first, so only the history alone
    // reaches them. A decision's and an interruption's row is read by
    // its command's key, so the Session holds one rejected command of
    // each.
    inline for (.{
        .{ "session_stop", error.MessageReadFailed, false },
        .{ "content", error.SessionReadFailed, false },
        .{ "permission_decision_command", error.PermissionReadFailed, true },
        .{ "model_interruption_command", error.InterruptionReadFailed, true },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "history-faults-config");
        // A Message no Turn took, so its stop is looked for.
        try submitTestMessage(&storage, &tmp, "history-faults-message", "history-faults-message", session.slice(), "queued");
        var decision: protocol.PermissionDecisionCommand = .{ .action_id = 999999, .decision = .deny };
        try decision.key.set("history-faults-decision");
        try decision.session.set(session.slice());
        try std.testing.expect(storage.decidePermission(&decision, .{}) == .rejected);
        var interruption: protocol.ModelInterruptionCommand = .{ .turn_id = 0, .operation_id = 1 };
        try interruption.key.set("history-faults-interruption");
        try interruption.session.set(session.slice());
        try std.testing.expect(storage.interruptModel(&interruption, .{}) == .rejected);
        try store_testing.failReadsOf(&storage, case[0]);
        if (case[2]) {
            try std.testing.expectError(case[1], testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full));
        } else try std.testing.expectError(case[1], testingFullHistory(&storage, &tmp, session.slice(), null));
    }
}

/// The statements and VM steps the Store's statements ran since the last
/// call, without the test-only touch oracle's.
fn statementWorkSince(database: *c.sqlite3) [2]i64 {
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

test "Attempt checks, prefix seals and content lookups do no more work than main" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const attempt = try TestingAttempt.admit(&storage, &tmp);
    // Main's statements and VM steps at 72db6de9 and again at 2e8e8353,
    // each on its warm second call: opening a view, its Attempt check,
    // recording a seal, the Operation's kind, a dispatch handoff and a
    // content lookup.
    const main_work = [_][2]i64{ .{ 2, 24 }, .{ 2, 24 }, .{ 6, 125 }, .{ 3, 32 }, .{ 2, 24 }, .{ 1, 14 } };
    for (0..2) |call| {
        var work: [main_work.len][2]i64 = undefined;
        _ = statementWorkSince(storage.sqliteDatabase());
        var view: HistoricalView = undefined;
        try storage.openHistoricalView(attempt.binding, &view);
        defer view.close();
        work[0] = statementWorkSince(storage.sqliteDatabase());
        try view.checkAttempt();
        work[1] = statementWorkSince(storage.sqliteDatabase());
        try view.recordPrefixSeal(&TestingAttempt.seal);
        work[2] = statementWorkSince(storage.sqliteDatabase());
        _ = try storage.modelOperationKind(attempt.binding);
        work[3] = statementWorkSince(storage.sqliteDatabase());
        try storage.withDispatchHandoff(attempt.binding, {}, TestingAttempt.handoff);
        work[4] = statementWorkSince(storage.sqliteDatabase());
        _ = try storage.openContent(attempt.content);
        work[5] = statementWorkSince(storage.sqliteDatabase());
        if (call == 0) continue;
        for (work, main_work) |measured, main| {
            try std.testing.expect(measured[0] <= main[0]);
            try std.testing.expect(measured[1] <= main[1]);
        }
    }
    // Rounds, where main took 2 for a view, a check or a handoff, 3 for
    // the Operation's kind, 5 for a seal and 1 for a content lookup: each
    // Attempt check is one read, a seal one read and its commit.
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    {
        var a: store_access.Access(.read, error{}) = .open(&entry);
        defer a.deinit();
        const before = storage.testing_content_work.rounds;
        _ = try model_settlement_domain.attemptKind(&a, attempt.binding);
        try std.testing.expectEqual(1, storage.testing_content_work.rounds - before);
    }
    {
        var a: store_access.Access(.write, error{}) = .open(&entry);
        defer a.deinit();
        const before = storage.testing_content_work.rounds;
        try historical_domain.sealOn(&a, attempt.binding, &TestingAttempt.seal);
        try std.testing.expectEqual(2, storage.testing_content_work.rounds - before);
    }
    {
        var a: store_access.Access(.read, error{}) = .open(&entry);
        defer a.deinit();
        const before = storage.testing_content_work.rounds;
        _ = try content_domain.contentIdOf(&a, attempt.content, false);
        try std.testing.expectEqual(1, storage.testing_content_work.rounds - before);
    }
}

test "a prefix seal on a full disk answers CanonicalStorageFull and fences" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const attempt = try TestingAttempt.admit(&storage, &tmp);
    var view: HistoricalView = undefined;
    try storage.openHistoricalView(attempt.binding, &view);
    defer view.close();
    // The seal rewrites a few bytes of one Session row in place, which a
    // capped file still holds, so a trigger grows the file as it writes.
    try sqlite.exec(storage.sqliteDatabase(), "CREATE TABLE ballast(b BLOB)");
    const page_count = try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA page_count");
    var limit_buffer: [64:0]u8 = undefined;
    try sqlite.exec(storage.sqliteDatabase(), try std.fmt.bufPrintSentinel(&limit_buffer, "PRAGMA max_page_count={d}", .{page_count}, 0));
    try sqlite.exec(storage.sqliteDatabase(), "CREATE TEMP TRIGGER seal_grows AFTER UPDATE OF prefix_seal ON main.session BEGIN INSERT INTO main.ballast VALUES(zeroblob(65536)); END");
    try std.testing.expectError(error.CanonicalStorageFull, view.recordPrefixSeal(&TestingAttempt.seal));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
    try std.testing.expect(storage.isFenced());
}

fn openRaw(path: []const u8) !*c.sqlite3 {
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
fn writeRows(database: *c.sqlite3, out: *std.Io.Writer) !void {
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
fn freshStoreWithExpectedRows(path: []const u8, root: []const u8) !void {
    var storage: Store = undefined;
    try storage.open(std.testing.io, path, root);
    try storage.close();
    {
        const raw = try openRaw(path);
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw, "PRAGMA foreign_keys=OFF");
        // The rows hold the catalog the open saved, under their own ids.
        try sqlite.exec(raw, "DELETE FROM host_catalog; DELETE FROM tool_set_member; DELETE FROM tool_set; DELETE FROM tool_record; DELETE FROM content");
        try sqlite.exec(raw, store_testing.expected_rows);
        const violations = try sqlite.prepare(raw, "PRAGMA foreign_key_check");
        defer _ = c.sqlite3_finalize(violations);
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(violations));
    }
    try storage.open(std.testing.io, path, root);
    try storage.close();
}

test "a Store at the migration baseline with its rows takes every migration at open and reads as a fresh Store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var migrated_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const migrated = try std.fmt.bufPrint(&migrated_buffer, "{s}/migrated.sqlite3", .{root});
    var fresh_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const fresh = try std.fmt.bufPrint(&fresh_buffer, "{s}/fresh.sqlite3", .{root});
    {
        const raw = try openRaw(migrated);
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
        try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d};PRAGMA user_version={d}", .{ store_schema.application_id, store_schema.migration_baseline }));
        const meta = try sqlite.prepare(raw, std.fmt.comptimePrint("INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version',?1),('store_selector',?2),('format','{d}')", .{store_schema.migration_baseline}));
        defer _ = c.sqlite3_finalize(meta);
        try sqlite.bindText(meta, 1, protocol.wire_version);
        try sqlite.bindText(meta, 2, root);
        try sqlite.expectDone(meta);
        try sqlite.exec(raw, "PRAGMA foreign_keys=OFF");
        try sqlite.exec(raw, store_testing.baseline_rows);
    }
    var storage: Store = undefined;
    storage.open(std.testing.io, migrated, root) catch |err| {
        std.debug.print("the Store at the migration baseline did not open: {s}\n", .{@errorName(err)});
        return err;
    };
    try storage.close();
    try freshStoreWithExpectedRows(fresh, root);

    var migrated_rows: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer migrated_rows.deinit();
    var fresh_rows: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fresh_rows.deinit();
    {
        const raw = try openRaw(migrated);
        defer _ = c.sqlite3_close(raw);
        try std.testing.expectEqual(store_schema.schema_version, try sqlite.pragmaInt(raw, "PRAGMA user_version"));
        try writeRows(raw, &migrated_rows.writer);
    }
    // Format 54 draws each migrated Store its own id.
    try std.testing.expect(!std.mem.eql(u8, &try storeId(migrated), &try storeId(fresh)));
    {
        const raw = try openRaw(fresh);
        defer _ = c.sqlite3_close(raw);
        try writeRows(raw, &fresh_rows.writer);
    }
    try std.testing.expect(migrated_rows.written().len > 1000);
    try std.testing.expectEqualStrings(fresh_rows.written(), migrated_rows.written());
}

test "a migration whose step fails leaves its backup and the original Store readable, and replaces an earlier backup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const store = try storeAtFormat(&tmp, &path_buffer, &root_buffer, 7);
    const backup_name = "store.backup";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = backup_name, .data = "earlier" });
    // Names that only begin like the copy's are someone else's.
    for ([_][]const u8{ "store.sqlite3.kept", "store.backup.saved", "store.backup-old" }) |kept| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = kept, .data = "kept" });
    }
    {
        const raw = try openRaw(store.path);
        defer _ = c.sqlite3_close(raw);
        try std.testing.expectError(error.MigrationBrokeForeignKey, store_schema.migrate(std.testing.io, raw, store.root, 7, &.{.{ .from = 7, .sqlite = &.{"DELETE FROM session"}, .mysql = &.{} }}));
    }
    for ([_][]const u8{ "store.sqlite3.kept", "store.backup.saved", "store.backup-old" }) |kept| {
        var kept_buffer: [8]u8 = undefined;
        try std.testing.expectEqualStrings("kept", try tmp.dir.readFile(std.testing.io, kept, &kept_buffer));
    }
    var backup_path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const backup_path = try std.fmt.bufPrint(&backup_path_buffer, "{s}/" ++ backup_name, .{store.root});
    for ([_][]const u8{ store.path, backup_path }) |path| {
        const raw = try openRaw(path);
        defer _ = c.sqlite3_close(raw);
        try std.testing.expectEqual(@as(u32, 7), try sqlite.pragmaInt(raw, "PRAGMA user_version"));
        try std.testing.expectEqual(@as(u32, 7), try sqlite.pragmaInt(raw, "SELECT CAST(meta_value AS INTEGER) FROM store_meta WHERE meta_key='format'"));
        try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "SELECT count(*) FROM session"));
        try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "SELECT count(*) FROM session_revision"));
        try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "SELECT count(*) FROM pragma_integrity_check WHERE integrity_check='ok'"));
    }
    // A backup that cannot be written refuses the Store before any step runs.
    try tmp.dir.deleteFile(std.testing.io, backup_name);
    try tmp.dir.createDir(std.testing.io, backup_name, .default_dir);
    {
        const raw = try openRaw(store.path);
        defer _ = c.sqlite3_close(raw);
        try std.testing.expectError(error.MigrationBackupFailed, store_schema.migrate(std.testing.io, raw, store.root, 7, &.{.{ .from = 7, .sqlite = &.{"DELETE FROM session_revision"}, .mysql = &.{} }}));
        try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "SELECT count(*) FROM session_revision"));
        try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "PRAGMA foreign_keys"));
    }
    try std.testing.expect((try tmp.dir.statFile(std.testing.io, backup_name, .{})).kind == .directory);
}

test "a Store at the maximum path backs itself up before a migration" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store_buffer: [protocol.max_store_bytes]u8 = undefined;
    const store_path = try createMaximumCanonicalStore(&tmp, &store_buffer);
    const paths = try platform.resolveClientPaths(io, store_path);
    const database = paths.database.slice();
    try std.testing.expectEqual(@as(usize, platform.max_database_path_bytes), database.len);
    {
        var storage: Store = undefined;
        try storage.open(io, database, paths.store.slice());
        defer storage.close() catch unreachable;
        _ = try configureTestSession(&storage, "migration-session");
    }
    const raw = try openRaw(database);
    defer _ = c.sqlite3_close(raw);
    try sqlite.exec(raw, "UPDATE store_meta SET meta_value='7' WHERE meta_key='format';PRAGMA user_version=7");
    try std.testing.expectError(error.MigrationBrokeForeignKey, store_schema.migrate(io, raw, paths.store.slice(), 7, &.{.{ .from = 7, .sqlite = &.{"DELETE FROM session"}, .mysql = &.{} }}));
    var backup_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const backup = try std.fmt.bufPrint(&backup_buffer, "{s}/rui.backup", .{paths.store.slice()});
    try std.testing.expect((try std.Io.Dir.cwd().statFile(io, backup, .{})).size > 0);
}

/// `object`'s CREATE text in the current schema.
fn objectSql(comptime name: []const u8) [:0]const u8 {
    comptime {
        for (store_schema.objects(.sqlite)) |object| if (std.mem.eql(u8, object.name, name)) {
            const terminated = object.sql ++ "\x00";
            return terminated[0..object.sql.len :0];
        };
        @compileError("no schema object " ++ name);
    }
}

/// A current Store whose store_meta format reads `from`, with one Session.
fn storeAtFormat(tmp: *std.testing.TmpDir, path_buffer: []u8, root_buffer: []u8, comptime from: u32) !struct { path: []const u8, root: []const u8 } {
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, root_buffer)];
    const path = try std.fmt.bufPrint(path_buffer, "{s}/store.sqlite3", .{root});
    var storage: Store = undefined;
    try storage.open(std.testing.io, path, root);
    _ = try configureTestSession(&storage, "migration-session");
    try storage.close();
    const raw = try openRaw(path);
    defer _ = c.sqlite3_close(raw);
    try sqlite.exec(raw, std.fmt.comptimePrint("UPDATE store_meta SET meta_value='{d}' WHERE meta_key='format';PRAGMA user_version={d}", .{ from, from }));
    return .{ .path = path, .root = root };
}

test "a migration that rebuilds a referenced table from the schema's text keeps its rows and references, and the Store opens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const store = try storeAtFormat(&tmp, &path_buffer, &root_buffer, 7);
    const rebuild = comptime blk: {
        var statements: []const [:0]const u8 = &.{ "ALTER TABLE session RENAME TO session_old", objectSql("session"), "INSERT INTO session SELECT * FROM session_old", "DROP TABLE session_old" };
        for (store_schema.indexes) |index| if (std.mem.eql(u8, index.table, "session")) {
            statements = statements ++ .{objectSql(index.name)};
        };
        break :blk statements;
    };
    {
        const raw = try openRaw(store.path);
        defer _ = c.sqlite3_close(raw);
        try store_schema.migrate(std.testing.io, raw, store.root, 7, &.{.{ .from = 7, .sqlite = rebuild, .mysql = &.{} }});
    }
    var storage: Store = undefined;
    try storage.open(std.testing.io, store.path, store.root);
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision", .{}));
}

test "a migration that leaves other text than bootstrap's, or a broken reference, or runs on another format, commits nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const store = try storeAtFormat(&tmp, &path_buffer, &root_buffer, 7);
    // SQLite splices an added column into the table's text, so the column
    // bootstrap would write in place reads differently.
    const added = "ALTER TABLE session ADD COLUMN migration_probe INTEGER";
    const Case = struct { from: u32, statements: []const [:0]const u8, refusal: anyerror };
    const cases = [_]Case{
        .{ .from = 7, .statements = &.{added}, .refusal = error.WrongStoreSchema },
        .{ .from = 7, .statements = &.{"DELETE FROM session"}, .refusal = error.MigrationBrokeForeignKey },
        .{ .from = 6, .statements = &.{}, .refusal = error.WrongStoreVersion },
    };
    const raw = try openRaw(store.path);
    defer _ = c.sqlite3_close(raw);
    for (cases) |case| {
        try std.testing.expectError(case.refusal, store_schema.migrate(std.testing.io, raw, store.root, case.from, &.{.{ .from = case.from, .sqlite = case.statements, .mysql = &.{} }}));
        try std.testing.expectEqual(@as(u32, 7), try sqlite.pragmaInt(raw, "PRAGMA user_version"));
        try std.testing.expectEqual(@as(u32, 7), try sqlite.pragmaInt(raw, "SELECT CAST(meta_value AS INTEGER) FROM store_meta WHERE meta_key='format'"));
        try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "SELECT count(*) FROM session"));
        try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(raw, "SELECT count(*) FROM pragma_table_info('session') WHERE name='migration_probe'"));
        try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(raw, "PRAGMA foreign_keys"));
    }
}

test "a page of approval requests costs the same however many calls ran without asking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try tests.configureTestSessionAsk(&storage, "approval-steps-config");
    try submitTestMessage(&storage, &tmp, "approval-steps-input", "approval-steps-input", session.slice(), "propose");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try tests.settleTwoActionsForTesting(&storage, &tmp, binding, "approval-steps-calls");
    var request: protocol.ActivityPage = .{ .kinds = .initOne(.approval_requested) };
    try request.session.set(session.slice());
    const Page = struct {
        fn steps(store: *Store, page_request: protocol.ActivityPage) !u64 {
            // The first read prepares the page's statements.
            _ = try store_core.activityPageForTesting(store, page_request);
            var counter: TestingSteps = .{};
            counter.begin(store.sqliteDatabase());
            defer counter.end(store.sqliteDatabase());
            const page = try store_core.activityPageForTesting(store, page_request);
            try std.testing.expectEqual(@as(usize, 2), page.count);
            return counter.steps;
        }
        /// `copies` more of the Session's calls and Actions that never
        /// asked: copies of its own, without an approval position.
        fn addBypassed(store: *Store, ref: []const u8, comptime first: u64) !void {
            const sequence = std.fmt.comptimePrint("WITH RECURSIVE sequence(value) AS (VALUES({d}) UNION ALL SELECT value+1 FROM sequence WHERE value<{d}) ", .{ first, first + 999 });
            try store_testing.sqlite_only.withoutForeignKeys(store, sequence ++
                "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,message_content_id,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count,description,call_failed) " ++
                "SELECT operation_id+value*1000,item_ordinal,session_ref,session_position+value*10+1000000,item_kind,message_content_id,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count,description,call_failed " ++
                "FROM model_output_item CROSS JOIN sequence WHERE session_ref=?1 AND item_kind=3 AND operation_id<1000", .{ref});
            try store_testing.sqlite_only.withoutForeignKeys(store, sequence ++
                "INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,authorized,decided_at) " ++
                "SELECT action_id+value*1000,parent_operation_id+value*1000,call_ordinal,session_ref,tool_kind,permission_revision,1,1 FROM action_operation CROSS JOIN sequence WHERE session_ref=?1 AND action_id<1000", .{ref});
        }
    };
    const few = try Page.steps(&storage, request);
    try Page.addBypassed(&storage, session.slice(), 1);
    const thousand = try Page.steps(&storage, request);
    try Page.addBypassed(&storage, session.slice(), 1001);
    try std.testing.expectEqual(@as(u64, 4002), try store_testing.sqliteQueryU64(storage.sqliteDatabase(), "SELECT count(*) FROM action_operation", .{}));
    // A fixed cost: the seek past the bypassed rows is one step, whatever
    // their number.
    try std.testing.expect(thousand - few <= 1);
    try std.testing.expectEqual(thousand, try Page.steps(&storage, request));
}

test "a compaction's floor counts the output bytes a request sends, and none its base covers" {
    // A 200,000-byte answer with no usage passes level 2's 128,000 bytes,
    // unless a compaction base covers it and the request sends none of it.
    const answer = try std.testing.allocator.alloc(u8, 200_000);
    defer std.testing.allocator.free(answer);
    @memset(answer, 'a');
    const item = try std.fmt.allocPrint(std.testing.allocator, "{{\"type\":\"message\",\"id\":\"a1\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":\"{s}\"}}]}}", .{answer});
    defer std.testing.allocator.free(item);
    for ([_]bool{ false, true }) |covered| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try tests.configureTestSessionAsk(&storage, "floor-bytes-config");
        try submitTestMessage(&storage, &tmp, "floor-bytes-first", "floor-bytes-first", session.slice(), "first");
        const answered = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try settleItemsForTesting(&storage, &tmp, answered, &.{item}, answer);
        if (covered) {
            try submitTestMessage(&storage, &tmp, "floor-bytes-covered", "floor-bytes-covered", session.slice(), "c");
            const call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(call, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
            const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCompactionForTesting(&storage, &tmp, base, &.{.compaction});
        }
        try submitTestMessage(&storage, &tmp, "floor-bytes-small", "floor-bytes-small", session.slice(), "small");
        const call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try storage.settleModelAttemptFailure(call, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
        const compaction = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var a: historical_domain.ReadAccess = .open(&entry);
        defer a.deinit();
        const room = try history_floor_domain.deeperFloor(&a, compaction.operation_id);
        if (covered) {
            try std.testing.expect(room == null);
        } else {
            // The floor drops the answer and keeps "small" above it.
            const position = try store_testing.sqliteQueryU64(storage.sqliteDatabase(), "SELECT admission_position FROM model_operation WHERE operation_id=?1", .{answered.operation_id});
            try std.testing.expectEqual(@as(u8, 2), room.?.choice.level);
            try std.testing.expect(room.?.choice.floor >= position);
        }
    }
}

test "a compaction's floor read costs the same however long its Session's history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try tests.configureTestSessionAsk(&storage, "floor-steps-config");
    // 200 KB Messages: level 1's 512,000 bytes are past at the fourth.
    const text = try std.testing.allocator.alloc(u8, 200_000);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');
    try submitTestMessage(&storage, &tmp, "floor-steps-first", "floor-steps-first", session.slice(), "first");
    try submitTestMessage(&storage, &tmp, "floor-steps-big", "floor-steps-big", session.slice(), text);
    const call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(call, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
    const compaction = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const Walk = struct {
        fn steps(store: *Store, operation: u64) !u64 {
            // The first read prepares the walk's statements.
            _ = try deeper(store, operation);
            var counter: TestingSteps = .{};
            counter.begin(store.sqliteDatabase());
            defer counter.end(store.sqliteDatabase());
            try std.testing.expect(try deeper(store, operation) != null);
            return counter.steps;
        }
        fn deeper(store: *Store, operation: u64) !?history_floor_domain.Room {
            const entry = try store_core.enter(store, .none);
            defer entry.release();
            var a: historical_domain.ReadAccess = .open(&entry);
            defer a.deinit();
            return history_floor_domain.deeperFloor(&a, operation);
        }
        /// 1,000 more copies of the big Message, older than the rest: the
        /// first Message moves past them, as the walk keeps it either way.
        fn addOlder(store: *Store, ref: []const u8, comptime first: u64) !void {
            const sequence = std.fmt.comptimePrint("WITH RECURSIVE sequence(value) AS (VALUES({d}) UNION ALL SELECT value+1 FROM sequence WHERE value<{d}) ", .{ first, first + 999 });
            try store_testing.sqlite_only.withoutForeignKeys(store, sequence ++
                "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,content_id,recorded_at) " ++
                "SELECT session_ref,entry_ordinal+value*10,session_position-value-1,entry_kind,turn_id,source_admission_id+value*10,NULL,NULL,content_id,recorded_at " ++
                "FROM conversation_entry CROSS JOIN sequence WHERE session_ref=?1 AND entry_ordinal=2", .{ref});
        }
    };
    try store_testing.sqlite_only.withoutForeignKeys(&storage, "UPDATE conversation_entry SET session_position=session_position+3000 WHERE session_ref=?1", .{session.slice()});
    try store_testing.sqlite_only.withoutForeignKeys(&storage, "UPDATE model_operation SET admission_position=admission_position+3000 WHERE session_ref=?1", .{session.slice()});
    try store_testing.sqlite_only.withoutForeignKeys(&storage, "UPDATE session SET next_position=next_position+3000 WHERE session_ref=?1", .{session.slice()});
    try Walk.addOlder(&storage, session.slice(), 1);
    const thousand = try Walk.steps(&storage, compaction.operation_id);
    try Walk.addOlder(&storage, session.slice(), 1001);
    try std.testing.expectEqual(@as(u64, 2002), try store_testing.sqliteQueryU64(storage.sqliteDatabase(), "SELECT count(*) FROM conversation_entry", .{}));
    try std.testing.expectEqual(thousand, try Walk.steps(&storage, compaction.operation_id));
}

/// A Session that offers only `message_agent`, under an `ask` revision, so
/// a core call that needed a person would wait.
fn configureMessagingSession(storage: *Store, key: []const u8) !protocol.Bounded(protocol.max_session_bytes) {
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try store_testing.canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try store_testing.completeConfiguration(key, "", workspace, "model-a");
    command.configuration.tools.state = .value;
    command.configuration.tools = try .of(&.{"message_agent"});
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set("ask");
    const reply = storage.configure(&command, .{});
    try std.testing.expect(reply == .accepted);
    return reply.accepted.session;
}

test "a message_agent call runs as one core command: the Message is admitted from its Session and the call resolves" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const caller = try configureMessagingSession(&storage, "agent-caller");
    const receiver = try configureTestSession(&storage, "agent-receiver");
    try submitTestMessage(&storage, &tmp, "agent-task", "agent-task", caller.slice(), "ask the receiver");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var arguments_buffer: [96]u8 = undefined;
    const arguments = try std.fmt.bufPrint(&arguments_buffer, "{{\"id\":\"{s}\",\"text\":\"report back\"}}", .{receiver.slice()});
    var encoded_buffer: [128]u8 = undefined;
    const encoded = try std.fmt.bufPrint(&encoded_buffer, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"report back\\\"}}", .{receiver.slice()});
    const calls = [_]TestingCall{
        .{ .item_id = "agent-item", .name = "message_agent", .encoded_call_id = "agent-call", .decoded_call_id = "agent-call", .encoded_arguments = encoded, .decoded_arguments = arguments },
        .{ .item_id = "agent-missing-item", .name = "message_agent", .encoded_call_id = "agent-missing", .decoded_call_id = "agent-missing", .encoded_arguments = "{\\\"id\\\":\\\"zzzzzz\\\",\\\"text\\\":\\\"hi\\\"}", .decoded_arguments = "{\"id\":\"zzzzzz\",\"text\":\"hi\"}" },
    };
    try settleCallsForTesting(&storage, &tmp, model, "agent-metadata", &calls);

    // Both calls are decided at once under `ask`, described by the core,
    // and never reach the Bash runner.
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE authorized=1 AND approval_position IS NULL", .{}));
    var line_buffer: [32]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buffer, "Message {s}", .{receiver.slice()});
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE description=?1", .{line}));
    try std.testing.expect(try storage.admitNextActionAttempt(300_000, .{}) == null);

    const first = (try storage.nextCoreWork()).?.action;
    try std.testing.expectEqualStrings(caller.slice(), first.session.slice());
    try std.testing.expectEqual(command_domain.AgentDelivery.delivered, try storage.deliverAgentMessage(first.binding, receiver.slice(), "report back", .{}));
    const second = (try storage.nextCoreWork()).?.action;
    try std.testing.expect(second.binding.action_id != first.binding.action_id);
    try std.testing.expectEqual(command_domain.AgentDelivery.failed, try storage.deliverAgentMessage(second.binding, "zzzzzz", "hi", .{}));
    try std.testing.expect(try storage.nextCoreWork() == null);
    // A resolved call is not run again.
    try std.testing.expectError(error.StaleActionAttemptBinding, storage.deliverAgentMessage(first.binding, receiver.slice(), "report back", .{}));

    // The receiver holds one Message from the caller, waiting for a Turn.
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1 AND sender_session_ref=?2 AND turn_id IS NULL", .{ receiver.slice(), caller.slice() }));
    const text_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT content_id FROM message_admission WHERE session_ref=?1", .{receiver.slice()});
    try expectContent(&storage, try testingContentReference(&storage, text_id), "report back");
    // Each call resolved with what happened, and the caller's Turn can continue.
    var delivered_buffer: [32]u8 = undefined;
    for ([_]struct { []const u8, []const u8 }{
        .{ "succeeded", try std.fmt.bufPrint(&delivered_buffer, "Delivered to {s}.", .{receiver.slice()}) },
        .{ "failed", "No Session zzzzzz in this Store; nothing was sent." },
    }) |case| {
        const result_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT resolution_content_id FROM action_operation WHERE resolution_code=?1", .{case[0]});
        try expectContent(&storage, try testingContentReference(&storage, result_id), case[1]);
    }
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM turn WHERE session_ref=?1 AND outcome_code IS NULL AND continuation_operation_id=operation_id", .{caller.slice()}));
    try expectDenseSessionPositions(&storage, caller.slice());
    try expectDenseSessionPositions(&storage, receiver.slice());
}

test "a message_agent call of the longest escaped text is read back past one content window and delivered whole" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const caller = try configureMessagingSession(&storage, "long-caller");
    const receiver = try configureTestSession(&storage, "long-receiver");
    try submitTestMessage(&storage, &tmp, "long-task", "long-task", caller.slice(), "send it all");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const gpa = std.testing.allocator;
    // Every byte of the text is a quote, so the arguments hold twice the
    // text and are read in more than one window.
    const text = try gpa.alloc(u8, tool_catalog.core_tools.message_agent_max_text_bytes);
    defer gpa.free(text);
    @memset(text, '"');
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(gpa);
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(gpa);
    try decoded.print(gpa, "{{\"id\":\"{s}\",\"text\":\"", .{receiver.slice()});
    try encoded.print(gpa, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"", .{receiver.slice()});
    for (text) |_| {
        try decoded.appendSlice(gpa, "\\\"");
        try encoded.appendSlice(gpa, "\\\\\\\"");
    }
    try decoded.appendSlice(gpa, "\"}");
    try encoded.appendSlice(gpa, "\\\"}");
    try std.testing.expect(decoded.items.len > content_domain.ContentReader.content_window_bytes);
    const calls = [_]TestingCall{.{ .item_id = "long-item", .name = "message_agent", .encoded_call_id = "long-call", .decoded_call_id = "long-call", .encoded_arguments = encoded.items, .decoded_arguments = decoded.items }};
    try settleCallsForTesting(&storage, &tmp, model, "long-metadata", &calls);

    const input = (try storage.nextCoreWork()).?.action;
    const bytes = try gpa.alloc(u8, @intCast(input.arguments.length));
    defer gpa.free(bytes);
    try storage.readCoreArguments(&input, bytes);
    try std.testing.expectEqualStrings(decoded.items, bytes);
    var source: tool_catalog.core_tools.SliceSource = .{ .bytes = bytes };
    const Text = struct {
        list: std.ArrayList(u8) = .empty,

        pub fn writeAll(self: *@This(), part: []const u8) !void {
            try self.list.appendSlice(std.testing.allocator, part);
        }
    };
    var read_text: Text = .{};
    defer read_text.list.deinit(gpa);
    const check = try tool_catalog.core_tools.checkMessageAgent(&source, &read_text);
    try std.testing.expect(check == .accepted);
    try std.testing.expectEqualStrings(text, read_text.list.items);
    try std.testing.expectEqual(command_domain.AgentDelivery.delivered, try storage.deliverAgentMessage(input.binding, check.accepted.id.slice(), read_text.list.items, .{}));
    const text_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT content_id FROM message_admission WHERE session_ref=?1", .{receiver.slice()});
    var reader: content_domain.ContentReader = undefined;
    reader.open(try storage.openContent(try testingContentReference(&storage, text_id)));
    defer reader.close();
    const delivered = try gpa.alloc(u8, text.len + 1);
    defer gpa.free(delivered);
    var count: usize = 0;
    while (true) {
        const read = try reader.read(count, delivered[count..@min(delivered.len, count + content_domain.ContentReader.content_window_bytes)]);
        if (read == 0) break;
        count += read;
    }
    try std.testing.expectEqualStrings(text, delivered[0..count]);
}

test "a stop or a context full ending stops every attached child below it, each as its own stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    // parent -> child -> grandchild are attached; standalone has no parent.
    const parent = try configureTestSession(&storage, "tree-parent");
    const child = try configureTestSession(&storage, "tree-child");
    const grandchild = try configureTestSession(&storage, "tree-grandchild");
    const standalone = try configureTestSession(&storage, "tree-standalone");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ child.slice(), grandchild.slice() });
    try submitTestMessage(&storage, &tmp, "tree-child-task", "tree-child-task", child.slice(), "work");
    try std.testing.expect(try storage.nextCoreWork() == null);

    var stop = try completeSessionStop("tree-stop", parent.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    // The child owes a stop keyed by its cause; nothing else does yet.
    const owed = (try storage.nextCoreWork()).?.stop;
    try std.testing.expectEqualStrings(child.slice(), owed.session.slice());
    const stop_position = try store_testing.sqlite_only.queryU64(&storage, "SELECT position FROM session_stop WHERE command_key='tree-stop'", .{});
    var key_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&key_buffer, "rui.core/stop/{s}/{s}/{d}", .{ child.slice(), parent.slice(), stop_position }), owed.key.slice());
    // A replayed parent stop owes nothing again.
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop_owed", .{}));

    // The child's stop is an ordinary stop: it excludes the child's queued
    // task, settles what it owed and passes the stop down.
    var child_stop = try completeSessionStop(owed.key.slice(), owed.session.slice());
    try std.testing.expect(storage.stopOwedSession(&child_stop, .{}) == .accepted);
    const next = (try storage.nextCoreWork()).?.stop;
    try std.testing.expectEqualStrings(grandchild.slice(), next.session.slice());
    var grandchild_stop = try completeSessionStop(next.key.slice(), next.session.slice());
    try std.testing.expect(storage.stopOwedSession(&grandchild_stop, .{}) == .accepted);
    try std.testing.expect(try storage.nextCoreWork() == null);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop WHERE session_ref=?1", .{child.slice()}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop WHERE session_ref=?1", .{standalone.slice()}));
    try std.testing.expect(try storage.admitNextModelAttempt(.{}) == null);
    try expectDenseSessionPositions(&storage, child.slice());
    try expectDenseSessionPositions(&storage, grandchild.slice());

    // A Turn that ends out of context stops the children too.
    try submitTestMessage(&storage, &tmp, "tree-parent-task", "tree-parent-task", parent.slice(), "too long");
    const attempt = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(attempt, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
    // The overflow compacts first; the compaction overflowing too, with
    // nothing to drop, ends the Turn out of context.
    const compaction = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(compaction, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM turn WHERE session_ref=?1 AND outcome_code='ResourceExceeded'", .{parent.slice()}));
    const full = (try storage.nextCoreWork()).?.stop;
    try std.testing.expectEqualStrings(child.slice(), full.session.slice());
    const close_position = try store_testing.sqlite_only.queryU64(&storage, "SELECT outcome_position FROM turn WHERE session_ref=?1", .{parent.slice()});
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&key_buffer, "rui.core/stop/{s}/{s}/{d}", .{ child.slice(), parent.slice(), close_position }), full.key.slice());
    try expectDenseSessionPositions(&storage, parent.slice());
}

test "child endings deliver once with their answer and sender; standalone endings owe nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const parent = try configureTestSession(&storage, "ending-parent");
    const child = try configureTestSession(&storage, "ending-child");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
    try submitTestMessage(&storage, &tmp, "ending-task", "ending-task", child.slice(), "answer");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const item = "{\"type\":\"message\",\"id\":\"ending-answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hello\"}]}";
    try settleItemsForTesting(&storage, &tmp, model, &.{item}, "hello");
    const ending = (try storage.nextCoreWork()).?.ending;
    try std.testing.expectEqual(.done, ending.ending);
    try std.testing.expect(!ending.quiet);
    try expectContent(&storage, ending.answer.?, "hello");
    try std.testing.expect(try storage.deliverChildEnding(ending.turn_id, .{}));
    try std.testing.expect(!try storage.deliverChildEnding(ending.turn_id, .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1 AND sender_session_ref=?2", .{ parent.slice(), child.slice() }));
    // The Message is the saved answer itself, not a copy.
    try std.testing.expectEqual(
        try store_testing.sqlite_only.queryU64(&storage, "SELECT outcome_content_id FROM turn WHERE turn_id=?1", .{ending.turn_id}),
        try store_testing.sqlite_only.queryU64(&storage, "SELECT content_id FROM message_admission WHERE session_ref=?1", .{parent.slice()}),
    );
    try std.testing.expect(try storage.nextCoreWork() == null);
    // A standalone Turn has no parent to notify.
    const solo = try configureTestSession(&storage, "ending-solo");
    try submitTestMessage(&storage, &tmp, "solo-task", "solo-task", solo.slice(), "answer");
    while (try storage.admitNextModelAttempt(.{})) |attempt| {
        try settleItemsForTesting(&storage, &tmp, attempt.permit.binding, &.{item}, "hello");
    }
    try std.testing.expect(try storage.nextCoreWork() == null);
}

test "a client stopped child delivers a nonquiet stopped ending" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const parent = try configureTestSession(&storage, "client-ending-parent");
    const child = try configureTestSession(&storage, "client-ending-child");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
    try submitTestMessage(&storage, &tmp, "client-ending-task", "client-ending-task", child.slice(), "work");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    var stop = try completeSessionStop("client-ending-stop", child.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    const ending = (try storage.nextCoreWork()).?.ending;
    try std.testing.expectEqual(.stopped, ending.ending);
    try std.testing.expect(!ending.quiet);
    try std.testing.expect(try storage.deliverChildEnding(ending.turn_id, .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1 AND sender_session_ref=?2", .{ parent.slice(), child.slice() }));
}

test "a child's core call selected before its parent stopped runs only after the stop it owes, which cancels it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const parent = try configureTestSession(&storage, "priority-parent");
    const child = try configureMessagingSession(&storage, "priority-child");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
    try submitTestMessage(&storage, &tmp, "priority-task", "priority-task", child.slice(), "message your parent");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var arguments_buffer: [96]u8 = undefined;
    const arguments = try std.fmt.bufPrint(&arguments_buffer, "{{\"id\":\"{s}\",\"text\":\"late\"}}", .{parent.slice()});
    var encoded_buffer: [128]u8 = undefined;
    const encoded = try std.fmt.bufPrint(&encoded_buffer, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"late\\\"}}", .{parent.slice()});
    const calls = [_]TestingCall{.{ .item_id = "priority-item", .name = "message_agent", .encoded_call_id = "priority-call", .decoded_call_id = "priority-call", .encoded_arguments = encoded, .decoded_arguments = arguments }};
    try settleCallsForTesting(&storage, &tmp, model, "priority-metadata", &calls);
    const selected = (try storage.nextCoreWork()).?.action;

    var stop = try completeSessionStop("priority-stop", parent.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    try std.testing.expectEqual(command_domain.AgentDelivery.stopped, try storage.deliverAgentMessage(selected.binding, parent.slice(), "late", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{parent.slice()}));
    const owed = (try storage.nextCoreWork()).?.stop;
    var owed_stop = try completeSessionStop(owed.key.slice(), owed.session.slice());
    try std.testing.expect(storage.stopOwedSession(&owed_stop, .{}) == .accepted);
    const ending = (try storage.nextCoreWork()).?.ending;
    try std.testing.expect(ending.quiet);
    try std.testing.expect(try storage.deliverChildEnding(ending.turn_id, .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{parent.slice()}));
    try std.testing.expect(try storage.nextCoreWork() == null);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code='cancelled'", .{}));
}

test "an owed stop a client's stop already settled, or a newer one replaced, runs nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const parent = try configureTestSession(&storage, "stale-parent");
    const child = try configureTestSession(&storage, "stale-child");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
    var stop = try completeSessionStop("stale-stop", parent.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    const selected = (try storage.nextCoreWork()).?.stop;

    // A client stops the child under its own key, then sends it a Message.
    var client = try completeSessionStop("stale-client-stop", child.slice());
    try std.testing.expect(storage.stopSession(&client, .{}) == .accepted);
    try submitTestMessage(&storage, &tmp, "stale-after", "stale-after", child.slice(), "after the stop");
    var stale = try completeSessionStop(selected.key.slice(), selected.session.slice());
    try std.testing.expect(storage.stopOwedSession(&stale, .{}) == .conflict);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop WHERE session_ref=?1", .{child.slice()}));
    try std.testing.expect(try storage.admitNextModelAttempt(.{}) != null);

    // A newer obligation is not consumed by the stale key, only by its own.
    var again = try completeSessionStop("stale-stop-again", parent.slice());
    try std.testing.expect(storage.stopSession(&again, .{}) == .accepted);
    const newer = (try storage.nextCoreWork()).?.stop;
    try std.testing.expect(!std.mem.eql(u8, newer.key.slice(), selected.key.slice()));
    try std.testing.expect(storage.stopOwedSession(&stale, .{}) == .conflict);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop_owed", .{}));
    var owed = try completeSessionStop(newer.key.slice(), newer.session.slice());
    try std.testing.expect(storage.stopOwedSession(&owed, .{}) == .accepted);
    const ending = (try storage.nextCoreWork()).?.ending;
    try std.testing.expect(ending.quiet);
    try std.testing.expect(try storage.deliverChildEnding(ending.turn_id, .{}));
    try std.testing.expect(try storage.nextCoreWork() == null);
    try std.testing.expect(!storage.isFenced());
}

test "a stop that selects a message_agent call's Turn cancels it before it runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const caller = try configureMessagingSession(&storage, "stopped-caller");
    try submitTestMessage(&storage, &tmp, "stopped-task", "stopped-task", caller.slice(), "message yourself");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var arguments_buffer: [96]u8 = undefined;
    const arguments = try std.fmt.bufPrint(&arguments_buffer, "{{\"id\":\"{s}\",\"text\":\"later\"}}", .{caller.slice()});
    var encoded_buffer: [128]u8 = undefined;
    const encoded = try std.fmt.bufPrint(&encoded_buffer, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"later\\\"}}", .{caller.slice()});
    const calls = [_]TestingCall{.{ .item_id = "stopped-item", .name = "message_agent", .encoded_call_id = "stopped-call", .decoded_call_id = "stopped-call", .encoded_arguments = encoded, .decoded_arguments = arguments }};
    try settleCallsForTesting(&storage, &tmp, model, "stopped-metadata", &calls);
    const pending = (try storage.nextCoreWork()).?.action;
    var stop = try completeSessionStop("stopped-stop", caller.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    try std.testing.expect(try storage.nextCoreWork() == null);
    try std.testing.expectError(error.StaleActionAttemptBinding, storage.deliverAgentMessage(pending.binding, caller.slice(), "later", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code='cancelled'", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{caller.slice()}));
}

test "a Session with message_agent keeps it through its list row and report, as the client reads them" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, io);
    defer storage.close() catch unreachable;
    const session = try configureMessagingSession(&storage, "listed-messaging");
    const file = try tmp.dir.createFile(io, "client-reply", .{ .read = true });
    defer file.close(io);

    var used = std.atomic.Value(u64).init(0);
    const listed = try testingSessionList(&storage, &tmp, .{}, &used, 1);
    defer std.testing.allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"tools\":[\"message_agent\"]") != null);
    try file.writePositionalAll(io, listed, 0);
    const list = try protocol_reply.SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = listed.len } });
    try std.testing.expectEqual(@as(usize, 1), list.page.count);
    try std.testing.expect(std.mem.eql(u8, list.page.rows[0].tools.names.slice(), "message_agent"));

    // A call waiting to run shows as the core tool's, which needed no
    // permission decision under `ask`.
    try submitTestMessage(&storage, &tmp, "listed-task", "listed-task", session.slice(), "tell yourself");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var arguments_buffer: [64]u8 = undefined;
    const arguments = try std.fmt.bufPrint(&arguments_buffer, "{{\"id\":\"{s}\",\"text\":\"hi\"}}", .{session.slice()});
    var encoded_buffer: [96]u8 = undefined;
    const encoded = try std.fmt.bufPrint(&encoded_buffer, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"hi\\\"}}", .{session.slice()});
    const calls = [_]TestingCall{.{ .item_id = "listed-item", .name = "message_agent", .encoded_call_id = "listed-call", .decoded_call_id = "listed-call", .encoded_arguments = encoded, .decoded_arguments = arguments }};
    try settleCallsForTesting(&storage, &tmp, model, "listed-metadata", &calls);

    const reported = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
    defer std.testing.allocator.free(reported);
    try std.testing.expect(std.mem.indexOf(u8, reported, "\"tool\":\"message_agent\",\"permission_revision\":\"1\",\"authorization\":\"core\"") != null);
    try file.setLength(io, 0);
    try file.writePositionalAll(io, reported, 0);
    const current = try protocol_reply.CurrentReply.decode(io, file, session.slice(), .{ .report = .{ .bytes = reported.len } });
    try std.testing.expect(current.current.settings.tools.set.eql(.initOne(.message_agent)));
    const Sink = struct {
        core_calls: usize = 0,
        pub fn visit(self: *@This(), attention: protocol_reply.Current.Attention) !void {
            switch (attention) {
                .unresolved => |row| {
                    try std.testing.expect(row.tool.value == .message_agent and row.authorization.value == .core);
                    self.core_calls += 1;
                },
                else => {},
            }
        }
    };
    var sink: Sink = .{};
    try current.current.traverse(io, file, &sink);
    try std.testing.expectEqual(@as(usize, 1), sink.core_calls);
}

test "a start_agent call creates its agent where its caller works, with the task from the caller, and may only narrow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try store_testing.canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try store_testing.completeConfiguration("starting-caller", "", workspace, "model-a");
    command.configuration.tools.state = .value;
    command.configuration.tools = try .of(&.{ "message_agent", "start_agent" });
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set("ask");
    const caller = storage.configure(&command, .{}).accepted.session;
    try submitTestMessage(&storage, &tmp, "start-task", "start-task", caller.slice(), "split the work");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "attached-item", .name = "start_agent", .encoded_call_id = "attached", .decoded_call_id = "attached", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "standalone-item", .name = "start_agent", .encoded_call_id = "standalone", .decoded_call_id = "standalone", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "wider-item", .name = "start_agent", .encoded_call_id = "wider", .decoded_call_id = "wider", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "bypass-item", .name = "start_agent", .encoded_call_id = "bypass", .decoded_call_id = "bypass", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    };
    try settleCallsForTesting(&storage, &tmp, model, "start-metadata", &calls);
    // Decided at once under `ask`, and never a Bash Attempt.
    try std.testing.expectEqual(@as(u64, 4), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE authorized=1 AND approval_position IS NULL", .{}));
    try std.testing.expect(try storage.admitNextActionAttempt(300_000, .{}) == null);

    const attached = (try storage.nextCoreWork()).?.action;
    try std.testing.expect(attached.tool == .start_agent);
    var spec = try tests.testingAgentSpec(&.{"message_agent"}, "ask");
    try std.testing.expectEqual(command_domain.AgentStart.started, try storage.startAgent(attached.binding, caller.slice(), "read the tests", true, &spec, null, .{}));
    const standalone = (try storage.nextCoreWork()).?.action;
    spec = try tests.testingAgentSpec(&.{}, "ask");
    try std.testing.expectEqual(command_domain.AgentStart.started, try storage.startAgent(standalone.binding, caller.slice(), "read the docs", false, &spec, null, .{}));
    const wider = (try storage.nextCoreWork()).?.action;
    spec = try tests.testingAgentSpec(&.{"bash"}, "ask");
    try std.testing.expectEqual(command_domain.AgentStart.failed, try storage.startAgent(wider.binding, caller.slice(), "run things", true, &spec, null, .{}));
    const bypass = (try storage.nextCoreWork()).?.action;
    spec = try tests.testingAgentSpec(&.{"message_agent"}, "bypass");
    try std.testing.expectEqual(command_domain.AgentStart.failed, try storage.startAgent(bypass.binding, caller.slice(), "run freely", true, &spec, null, .{}));
    try std.testing.expect(try storage.nextCoreWork() == null);

    // Two agents, both in the caller's Workspace with its provider; only
    // the attached one is its child.
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref<>?1 AND workspace=?2 AND provider=(SELECT provider FROM session WHERE session_ref=?1)", .{ caller.slice(), workspace }));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session WHERE parent_ref=?1", .{caller.slice()}));
    // Each task is its agent's first Message, from the caller, under the
    // call's own command key.
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE sender_session_ref=?1 AND admission_position=1 AND command_key LIKE 'rui.core/start_agent/%'", .{caller.slice()}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission m JOIN session s ON s.session_ref=m.session_ref JOIN content c ON c.content_id=m.content_id WHERE s.parent_ref=?1 AND c.byte_length=14", .{caller.slice()}));
    // The refusals name the field and start nothing.
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code='succeeded'", .{}));
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code='failed'", .{}));
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE CAST(c.payload AS TEXT) LIKE 'Started %'", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE CAST(c.payload AS TEXT) LIKE 'spec.tools: bash is not one of your tools.%'", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE CAST(c.payload AS TEXT) LIKE 'spec.permissionMode:%'", .{}));
}

test "a catalog at its bound saves and opens again" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const count = tool_catalog.max_catalog_records - 4;
    var names: [count][9]u8 = undefined;
    var records: [count + 4]tool_catalog.Record = undefined;
    var digests: [count + 4][32]u8 = undefined;
    records[0] = tool_catalog.bash_record;
    records[1] = tool_catalog.message_agent_record;
    records[2] = tool_catalog.start_agent_record;
    for (&names, records[3 .. count + 3], 0..) |*name, *record, index| {
        _ = try std.fmt.bufPrint(name, "tool_{d:0>4}", .{index});
        record.* = .{ .name = name, .owner = .rui, .description = "A tool among many.", .input_schema = "{\"type\":\"object\"}" };
    }
    records[count + 3] = tool_catalog.web_search_record;
    for (&records, &digests) |*record, *digest| digest.* = tool_catalog.recordDigest(record);
    const catalog: tool_catalog.Catalog = .{ .records = &records, .digests = &digests };
    var storage: Store = undefined;
    try testingStoreCatalog(&storage, &tmp, std.testing.io, &catalog);
    try storage.close();
    try testingStoreCatalog(&storage, &tmp, std.testing.io, &catalog);
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(u64, count + 4), try store_testing.queryU64(&storage, "SELECT max(member_count) FROM tool_set", .{}));
}

/// The testing catalog with an MCP server's tool beside it.
const mcp_record: tool_catalog.Record = .{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a page from the docs server.", .input_schema = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"}}}" };
const mcp_records = [_]tool_catalog.Record{ tool_catalog.bash_record, mcp_record, tool_catalog.message_agent_record, tool_catalog.start_agent_record, testing_record, tool_catalog.web_search_record };
const mcp_digests = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: [mcp_records.len][32]u8 = undefined;
    for (&mcp_records, &out) |*each, *digest| digest.* = tool_catalog.recordDigest(each);
    break :blk out;
};
const mcp_catalog: tool_catalog.Catalog = .{ .records = &mcp_records, .digests = &mcp_digests };

fn expectCatalog(expected: *const tool_catalog.Catalog, saved: *const store_core.SavedCatalog) !void {
    try std.testing.expectEqual(expected.records.len, saved.records.len);
    for (expected.records, saved.records, expected.digests, saved.digests) |want, got, want_digest, got_digest| {
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqual(want.owner, got.owner);
        try std.testing.expectEqualStrings(want.server, got.server);
        try std.testing.expectEqualStrings(want.description, got.description);
        try std.testing.expectEqualStrings(want.input_schema, got.input_schema);
        try std.testing.expectEqualSlices(u8, &want_digest, &got_digest);
    }
}

test "a Store opened without a catalog reads back the last one saved, an MCP server's tools included" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStoreCatalog(&storage, &tmp, std.testing.io, null);
    try std.testing.expect(try storage.readCatalog(std.testing.allocator) == null);
    try storage.saveCatalog(&mcp_catalog);
    try storage.close();

    try testingStoreCatalog(&storage, &tmp, std.testing.io, null);
    {
        var saved = (try storage.readCatalog(std.testing.allocator)).?;
        defer saved.deinit(std.testing.allocator);
        try expectCatalog(&mcp_catalog, &saved);
        // The Host saves what it read when it reaches no server.
        const read = saved.catalog();
        try storage.saveCatalog(&read);
    }
    // A later catalog without the server's tool replaces it, and saving
    // the earlier one again finds its set.
    try storage.saveCatalog(&testing_catalog);
    {
        var saved = (try storage.readCatalog(std.testing.allocator)).?;
        defer saved.deinit(std.testing.allocator);
        try expectCatalog(&testing_catalog, &saved);
    }
    const sets = try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_set", .{});
    try storage.saveCatalog(&mcp_catalog);
    try std.testing.expectEqual(sets, try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_set", .{}));
    var saved = (try storage.readCatalog(std.testing.allocator)).?;
    defer saved.deinit(std.testing.allocator);
    try expectCatalog(&mcp_catalog, &saved);
    try storage.close();
}

test "a saved catalog whose text no longer matches its digest fences the Store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStoreCatalog(&storage, &tmp, std.testing.io, null);
    defer storage.close() catch unreachable;
    try storage.saveCatalog(&mcp_catalog);
    try sqlite.exec(storage.sqliteDatabase(), "UPDATE content SET payload=CAST(upper(CAST(payload AS TEXT)) AS BLOB) WHERE content_id=(SELECT description_content_id FROM tool_record WHERE owner='mcp')");
    try std.testing.expectError(error.CorruptStore, storage.readCatalog(std.testing.allocator));
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.readCatalog(std.testing.allocator));
}

test "a Session offering an MCP server's tool is listed, reported and settled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStoreCatalog(&storage, &tmp, std.testing.io, &mcp_catalog);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("mcp-config", "", workspace, "model-a");
    command.configuration.tools = try .of(&.{ "bash", "fetch_page" });
    const reply = storage.configure(&command, .{});
    try std.testing.expect(reply == .accepted);
    const session = reply.accepted.session;
    // Reading and reconfiguring it neither refuses nor fences.
    _ = try storage.inspectSessionForTesting(session.slice());
    var reworded: protocol.ConfigureCommand = .{};
    try reworded.key.set("mcp-reconfigure");
    reworded.session = session;
    reworded.configuration.tools = try .of(&.{ "bash", "fetch_page", "test_tool" });
    try std.testing.expect(storage.configure(&reworded, .{}) == .accepted);
    reworded = .{};
    try reworded.key.set("mcp-reconfigure-back");
    reworded.session = session;
    reworded.configuration.tools = try .of(&.{ "bash", "fetch_page" });
    try std.testing.expect(storage.configure(&reworded, .{}) == .accepted);
    try std.testing.expect(!storage.isFenced());

    try submitTestMessage(&storage, &tmp, "mcp-message", "mcp-message", session.slice(), "fetch");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    // Rui runs no MCP tool yet, so its call is unknown; bash still runs.
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"one\\\"}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"one\"}" },
        .{ .item_id = "item-2", .name = "fetch_page", .encoded_call_id = "call-2", .decoded_call_id = "call-2", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "mcp-metadata", &calls);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE call_ordinal=0", .{}));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=1 AND rejection_code='unknown_tool'", .{}));

    const offered = "\"tools\":[\"bash\",\"fetch_page\"]";
    for ([_]protocol.ReportProfile{ .current, .full }) |profile| {
        const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, profile);
        defer std.testing.allocator.free(report);
        try std.testing.expect(std.mem.indexOf(u8, report, offered) != null);
        // The full profile's revision lists them too.
        if (profile == .full) try std.testing.expect(std.mem.indexOf(u8, report[std.mem.indexOf(u8, report, offered).? + 1 ..], offered) != null);
        if (profile == .current) {
            // A client reads the names back.
            const file = try tmp.dir.createFile(std.testing.io, "mcp-current", .{ .read = true });
            defer file.close(std.testing.io);
            try file.writePositionalAll(std.testing.io, report, 0);
            const decoded = try protocol_reply.CurrentReply.decode(std.testing.io, file, session.slice(), .{ .report = .{ .bytes = report.len } });
            try std.testing.expectEqualStrings("bash fetch_page", decoded.current.settings.tools.names.names.slice());
            try std.testing.expect(decoded.current.settings.tools.set.contains(.bash) and !decoded.current.settings.tools.set.contains(.web_search));
        }
    }
    var used = std.atomic.Value(u64).init(0);
    const list = try testingSessionList(&storage, &tmp, .{}, &used, 1);
    defer std.testing.allocator.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, session.slice()) != null);
    try std.testing.expect(std.mem.indexOf(u8, list, offered) != null);
}

test "a record names a server exactly when an MCP server owns it" {
    try std.testing.expect(tool_catalog.validServer(&mcp_record));
    try std.testing.expect(!tool_catalog.validServer(&.{ .name = "fetch_page", .owner = .mcp }));
    try std.testing.expect(!tool_catalog.validServer(&.{ .name = "fetch_page", .owner = .mcp, .server = "docs server" }));
    try std.testing.expect(!tool_catalog.validServer(&.{ .name = "bash", .owner = .rui, .server = "docs" }));
    // Moving servers makes another record.
    var moved = mcp_record;
    moved.server = "wiki";
    try std.testing.expect(!std.mem.eql(u8, &tool_catalog.recordDigest(&mcp_record), &tool_catalog.recordDigest(&moved)));
}

test "a failed model fact batch rolls back overwritten rows and source together" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/facts.sqlite3", .{root});
    var storage: Store = undefined;
    try storage.open(std.testing.io, path, root);
    {
        defer storage.close() catch unreachable;
        try storage.saveModelFacts(&.{.{ .id = "kept", .context_window = 100, .efforts = .{}, .openai = true }}, "\"old\"");
        // The first row is overwritten and stepped before the second row's
        // constraint fails. Neither that overwrite nor publication may stick.
        try std.testing.expectError(error.StatementFailed, storage.saveModelFacts(&.{
            .{ .id = "kept", .context_window = 200, .efforts = .{}, .openai = false },
            .{ .id = "", .context_window = null, .efforts = .{}, .openai = false },
        }, "\"new\""));
        try std.testing.expect(storage.isFenced());
    }
    try storage.open(std.testing.io, path, root);
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(?u32, 100), (try storage.modelFact("kept")).?.context_window);
    const source = (try storage.readModelCatalogSource()).?;
    try std.testing.expectEqual(@as(u64, 1), source.generation);
    try std.testing.expectEqualStrings("\"old\"", source.etag.?.slice());
}
