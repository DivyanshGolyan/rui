//! Access SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const store_access = @import("../access.zig");
const transition = @import("../transition.zig");
const rsql = @import("../rsql.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const command_domain = @import("../domain/command.zig");
const configuration_domain = @import("../domain/configuration.zig");
const reads_domain = @import("../domain/reads.zig");
const store_schema = @import("../schema.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const ActionSettlement = action_domain.ActionSettlement;
const AttemptBinding = store_core.AttemptBinding;
const ConfigureReply = configuration_domain.ConfigureReply;
const MessageReply = command_domain.MessageReply;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const completeMessage = store_testing.completeMessage;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = tests.TestingCall;
const TestingRound = tests.TestingRound;
const completeSessionStop = tests.completeSessionStop;
const configureTestSessionAsk = tests.configureTestSessionAsk;
const settleCallsForTesting = tests.settleCallsForTesting;
const settleTwoActionsForTesting = tests.settleTwoActionsForTesting;
const testingStoreToolSet = store_testing.testingStoreToolSet;
const testingStore = store_testing.testingSqliteStore;
const TestingStatementFault = shared_fixtures.TestingStatementFault;
const TestingStatements = shared_fixtures.TestingStatements;
const testing_tool_set = shared_fixtures.testing_tool_set;

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
                try std.testing.expectEqual(std.meta.Tag(ConfigureReply).infrastructure_failure, std.meta.activeTag(try storage.configure(&relabel, .{})));
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
        "SELECT max(forward_id) FROM session_forward",
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
    const before = blk: {
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        // Attached ask Sessions commit forward identities too.
        const parent = try configureTestSession(&storage, "identity-parent");
        // Entry points commit rows in every column.
        const first_session = try configureTestSessionAsk(&storage, "identity-config");
        try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), first_session.slice() });
        try submitTestMessage(&storage, &tmp, "identity-message", "identity-message", first_session.slice(), "propose");
        try settleTwoActionsForTesting(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding, "identity-first");

        const rolled_back = try takeEveryIdentityForTesting(&storage);
        try std.testing.expectEqual(rolled_back, try takeEveryIdentityForTesting(&storage));
        break :blk .{ .parent = parent, .identities = rolled_back };
    };

    // Committing the given-back values in every column: none is handed out
    // again. A Host offering one more tool saves its record at open.
    try testingStoreToolSet(&storage, &tmp, std.testing.io, &testing_tool_set);
    defer storage.close() catch unreachable;
    const second_session = try configureTestSessionAsk(&storage, "identity-later");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ before.parent.slice(), second_session.slice() });
    // New text, so content commits a new row too.
    try submitTestMessage(&storage, &tmp, "identity-later-message", "identity-later-message", second_session.slice(), "propose again");
    try settleTwoActionsForTesting(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding, "identity-second");
    // A new tool set commits.
    var tools: wire_request.ConfigureCommand = .{};
    try tools.key.set("identity-later-tools");
    tools.session = second_session;
    tools.configuration.tools = try .of(&.{ "bash", "test_tool" });
    try std.testing.expect(try storage.configure(&tools, .{}) == .accepted);
    const after = try takeEveryIdentityForTesting(&storage);
    for (before.identities, after) |given_back, next| try std.testing.expect(next > given_back);
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
    // The thirteenth entry exceeds the write queue's twelve slots.
    const text = "abcdefghijkl";
    const digest = protocol.contentDigest(text);
    const id = try a.identity(.content_id);
    a.write(TestingRound.insert_content, .{ .content_id = id, .digest = digest, .length = text.len });
    for (0..text.len) |index| a.writeContent(id, text[index..][0..1]);
    const before = storage.testing_content_work.rounds;
    try a.run();
    try std.testing.expectEqual(1, storage.testing_content_work.rounds - before);
    try std.testing.expectEqual(2, a.passes);
    try a.abandon(.{});
}

test "a settlement's queue holds twenty statements a pass" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    var a: store_access.Access(.settlement, error{TestingGuard}) = undefined;
    a.init(&entry);
    defer a.deinit();
    // A row and nineteen chunks fill one pass; a write's queue takes two.
    const text = "abcdefghijklmnopqrst";
    const digest = protocol.contentDigest(text);
    const id = try a.identity(.content_id);
    a.write(TestingRound.insert_content, .{ .content_id = id, .digest = digest, .length = text.len });
    for (0..19) |index| a.writeContent(id, text[index..][0..1]);
    try a.run();
    try std.testing.expectEqual(1, a.passes);
    a.writeContent(id, text[19..]);
    for (0..20) |_| a.writeContent(id, "");
    try a.run();
    try std.testing.expectEqual(3, a.passes);
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
    @setEvalBranchQuota(10_000);
    inline for (store_schema.tables) |table| {
        const watched = comptime for (sqlite.touch_oracle_tables) |watched_table| {
            if (std.mem.eql(u8, watched_table, table.name)) break true;
        } else false;
        try std.testing.expectEqual(watched, comptime store_schema.carriesSessions(table.name));
    }
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

test "SQLite single commit keeps autocommit on success guard failure and abandon" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const Outcome = enum { success, guard, abandon, no_op };
    const Single = struct {
        const read = rsql.Read(.{
            .sql = "SELECT min(content_id) AS id FROM content",
            .Args = struct {},
            .Row = struct { id: u64 },
            .cardinality = .one,
        });
        const write = rsql.Write(.{
            .sql = "UPDATE content SET private=private WHERE content_id=?1",
            .Args = struct { id: u64 },
            .expect = .{ .exact = .{ .rows = 1, .otherwise = error.TestingGuard } },
        });
        pub const rounds = transition.rounds(.{ .read = .{.always} });
        pub const round_budget = 2;
        pub const commit: transition.Commit = .single;
        pub const begin: ?rounds.At = .read;
        pub const Result = void;
        pub const Guards = error{TestingGuard};
        pub const Declined = error{};

        storage: *Store,
        outcome: Outcome,
        row: read.Result = undefined,
        /// Whether a transaction was open once the read ran.
        read_open: bool = true,

        pub fn step(t: *@This(), r: *transition.Round(@This()), ran: ?rounds.At) !transition.Next(@This()) {
            if (ran == null) {
                r.read(read, .{}, &t.row);
                return .{ .round = .read };
            }
            t.read_open = t.storage.engine.inTransaction();
            if (t.outcome != .no_op) r.write(write, .{ .id = if (t.outcome == .guard) 0 else t.row.id });
            return if (t.outcome == .no_op or t.outcome == .abandon) .{ .done = {} } else .commit;
        }

        pub fn committed(_: *const @This()) Result {}
    };
    for (std.enums.values(Outcome)) |outcome| {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var statements: TestingStatements = .{};
        statements.begin(storage.sqliteDatabase());
        defer statements.end(storage.sqliteDatabase());
        var single: Single = .{ .storage = &storage, .outcome = outcome };
        // Even a rollback fault is irrelevant: no transaction opens, and a
        // queued, unstepped autocommit write is simply discarded.
        const faults: store_core.Faults = .{ .rollback_failure = outcome != .success };
        const result = entry.finishTransaction(error{TestingGuard}, .{}, transition.run(&entry, Single, &single, faults));
        if (outcome == .guard) try std.testing.expectError(error.TestingGuard, result) else try result;
        try std.testing.expect(!single.read_open);
        try std.testing.expectEqual(@as(u64, if (outcome == .success or outcome == .guard) 2 else 1), statements.count);
        try std.testing.expect(!storage.engine.inTransaction());
        try std.testing.expect(!storage.isFenced());
    }
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
        const configured = try storage.configure(&configuration, .{});
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
        try std.testing.expect(try storage.configure(&later, .{}) == .infrastructure_failure);
        try storage.close();
    }

    var binding: AttemptBinding = undefined;
    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        try std.testing.expect((try store_testing.observeCommandForTesting(&storage, "rollback-configure")).status == .accepted);
        try std.testing.expect(
            (try store_testing.observeCommandForTesting(&storage, "rollback-message")).kind.message.?.queue.?.state == .queued,
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
        const observation = (try store_testing.observeCommandForTesting(&storage, "rollback-message")).kind.message.?.queue.?;
        const observed_binding = switch (observation.state) {
            .processing => |value| value,
            else => return error.ExpectedProcessingObservation,
        };
        try std.testing.expectEqual(binding.operation_id, observed_binding.operation_id);
        try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
        try std.testing.expect(
            (try store_testing.observeCommandForTesting(&storage, "rollback-message")).kind.message.?.queue.?.state == .failed,
        );
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
