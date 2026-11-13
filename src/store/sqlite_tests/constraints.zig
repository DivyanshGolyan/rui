//! Constraints SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const store_access = @import("../access.zig");
const Store = store_core.Store;
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = tests.TestingCall;
const TestingListing = tests.TestingListing;
const TestingRound = tests.TestingRound;
const configureTestSessionAsk = tests.configureTestSessionAsk;
const settleCallsForTesting = tests.settleCallsForTesting;
const testingStore = store_testing.testingSqliteStore;
const ConstraintProbe = shared_fixtures.ConstraintProbe;
const probeConstraint = shared_fixtures.probeConstraint;

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
    // This built-in-only Session never offered `other`; it is a rejection,
    // not an MCP Action. Keep that witness for the rejection CHECK below.
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=1 AND rejection_code='unknown_tool' AND action_kind IS NULL", .{}));

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
            .valid = "UPDATE action_operation SET attempt_ordinal=1,attempt_at=1,attempt_timeout_ms=1,resolution_code='failed'," ++
                "resolution_content_id=(SELECT min(content_id) FROM content),acceptance_position=1,resolved_at=1 WHERE call_ordinal=0",
            .invalid = "UPDATE action_operation SET attempt_ordinal=1,attempt_at=1,attempt_timeout_ms=1,resolution_code='denied'," ++
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
        .{ .update = "UPDATE core_command SET kind={s}", .accepted = &.{ "1", "2", "3", "4", "5", "6" }, .rejected = &.{ "0", "7" } },
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
            .valid = "UPDATE action_operation SET attempt_ordinal=1,attempt_at=1,attempt_timeout_ms=1",
            .invalid = "UPDATE action_operation SET attempt_ordinal=1,attempt_timeout_ms=1",
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
    const first = (try storage.configure(&first_command, .{})).accepted.session;
    var sibling_command = try completeConfiguration("digest-sibling", "", first_workspace, "model");
    const sibling = (try storage.configure(&sibling_command, .{})).accepted.session;
    // A digest collision: the first Workspace's Sessions carry the other's digest.
    {
        var sql: [160]u8 = undefined;
        const forged = std.fmt.bytesToHex(store_core.workspaceDigest(other_workspace), .lower);
        try sqlite.exec(storage.sqliteDatabase(), try std.fmt.bufPrintSentinel(&sql, "UPDATE session SET workspace_digest=x'{s}'", .{&forged}, 0));
    }
    var other_command = try completeConfiguration("digest-other", "", other_workspace, "model");
    const other = (try storage.configure(&other_command, .{})).accepted.session;

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
