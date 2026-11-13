//! Action SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const transition = @import("../transition.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const ActionAttemptBinding = action_domain.ActionAttemptBinding;
const ActionSettlement = action_domain.ActionSettlement;
const ActionExecutionInput = action_domain.ActionExecutionInput;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const next_action_attempt_sql = action_domain.next_action_attempt_sql;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = tests.TestingCall;
const completeSessionStop = tests.completeSessionStop;
const configureTestSessionAsk = tests.configureTestSessionAsk;
const expectContent = tests.expectContent;
const settleCallsForTesting = tests.settleCallsForTesting;
const settleTwoActionsForTesting = tests.settleTwoActionsForTesting;
const testingContentReference = tests.testingContentReference;
const testingStoreToolSet = store_testing.testingStoreToolSet;
const testingStore = store_testing.testingSqliteStore;
const TestingStatements = shared_fixtures.TestingStatements;
const attemptBashForTesting = shared_fixtures.attemptBashForTesting;
const expectDenseSessionPositions = shared_fixtures.expectDenseSessionPositions;
const mcp_tool_set = shared_fixtures.mcp_tool_set;

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
        (try store_testing.observeCommandForTesting(&storage, "settlement-stop")).kind.session_stop.?.completion,
    );
    try std.testing.expectEqual(
        ActionSettlement.session_stop,
        try storage.settleActionAttempt(action_binding, .succeeded, "Bash succeeded.", .{}),
    );
    try std.testing.expectEqual(
        protocol.SessionStopCompletion.completed,
        (try store_testing.observeCommandForTesting(&storage, "settlement-stop")).kind.session_stop.?.completion,
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
        ids: @TypeOf(storage.identities().next),
        generation: u64,

        fn take(store: *Store, dir: std.Io.Dir) !@This() {
            return .{
                .database = try dir.readFileAlloc(std.testing.io, "store.sqlite3", std.testing.allocator, .unlimited),
                .log = try dir.readFileAlloc(std.testing.io, "store.sqlite3-wal", std.testing.allocator, .unlimited),
                .ids = store.identities().next,
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

    // Round 1 finds `open` current; before the commit round runs, the
    // Action stops being attempted, so the resolve guard fails after the
    // result's content row and position were queued.
    const Interposed = struct {
        const Inner = action_domain.SettleAttempt;
        pub const rounds = Inner.rounds;
        pub const round_budget = Inner.round_budget;
        pub const commit = Inner.commit;
        pub const begin = Inner.begin;
        pub const Result = Inner.Result;
        pub const Guards = Inner.Guards;
        pub const Declined = Inner.Declined;

        inner: Inner,
        storage: *Store,

        pub fn step(t: *@This(), r: *transition.Round(@This()), ran: ?rounds.At) !transition.Next(@This()) {
            const next = try Inner.step(&t.inner, r, ran);
            if (next == .commit) {
                var sql: [160]u8 = undefined;
                const unattempt = std.fmt.bufPrintSentinel(&sql, "UPDATE action_operation SET attempt_ordinal=0,attempt_timeout_ms=NULL,attempt_at=NULL,sender_handle=NULL WHERE action_id={d}", .{t.inner.input.binding.action_id}, 0) catch unreachable;
                sqlite.exec(t.storage.sqliteDatabase(), unattempt) catch unreachable;
            }
            return next;
        }

        pub fn committed(t: *const @This()) Result {
            return Inner.committed(&t.inner);
        }
    };
    const guarded = try Snapshot.take(&storage, tmp.dir);
    defer guarded.deinit();
    const unclaimed = try store_testing.sqlite_only.queryU64(&storage, "SELECT next_position FROM session", .{});
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var interposed: Interposed = .{ .inner = .{ .input = .{ .binding = open, .code = .failed, .result = "A result the guard refuses." } }, .storage = &storage };
        try std.testing.expectError(error.StaleActionAttemptBinding, entry.finishTransaction(error{StaleActionAttemptBinding}, .{}, transition.run(&entry, Interposed, &interposed, .{})));
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
    const content_id = storage.identities().next.get(.content_id);
    try std.testing.expectEqual(ActionSettlement.effect, try storage.settleActionAttempt(open, .failed, "A later result is stored.", .{}));
    try std.testing.expectEqual(position, try store_testing.sqlite_only.queryU64(&storage, "SELECT acceptance_position FROM action_operation WHERE resolution_code='failed'", .{}));
    try std.testing.expectEqual(content_id, try store_testing.sqlite_only.queryU64(&storage, "SELECT resolution_content_id FROM action_operation WHERE resolution_code='failed'", .{}));
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

test "a Bash binding that is unknown, unattempted or without its revision is stale, and fences nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "stale-bash-config");
    const action = try attemptBashForTesting(&storage, &tmp, session.slice());
    var input: ActionExecutionInput = undefined;
    try storage.readActionExecutionInput(.bash, action, &input);
    try std.testing.expectEqualStrings(session.slice(), input.session.slice());
    try std.testing.expectEqual(@as(u64, 300_000), input.timeout_ms);

    var unknown = action;
    unknown.action_id += 1000;
    try std.testing.expectError(error.StaleActionAttemptBinding, storage.readActionExecutionInput(.bash, unknown, &input));
    // The other Action of the call pair, never attempted: its timeout is NULL.
    var unattempted = action;
    unattempted.action_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT action_id FROM action_operation WHERE session_ref=?1 AND attempt_ordinal=0", .{session.slice()});
    try std.testing.expectError(error.StaleActionAttemptBinding, storage.readActionExecutionInput(.bash, unattempted, &input));
    var rebound = action;
    rebound.turn_id += 1000;
    try std.testing.expectError(error.StaleActionAttemptBinding, storage.readActionExecutionInput(.bash, rebound, &input));
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    try store_testing.sqlite_only.exec(&storage, "UPDATE action_operation SET permission_revision=999 WHERE session_ref=?1 AND attempt_ordinal=1", .{session.slice()});
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
    try std.testing.expectError(error.StaleActionAttemptBinding, storage.readActionExecutionInput(.bash, action, &input));
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

test "Bash admission entry points agree on readiness" {
    const Case = enum { ready, unauthorized, resolved, attempted, closed, stopped };
    for (std.enums.values(Case)) |case| {
        var results: [2]bool = undefined;
        for (&results, 0..) |*result, entry| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStoreToolSet(&storage, &tmp, std.testing.io, &mcp_tool_set);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            var configuration = try completeConfiguration("bash-matrix", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
            configuration.configuration.tools = try .of(&.{"bash"});
            configuration.configuration.permission_mode.state = .value;
            try configuration.configuration.permission_mode.value.set("bypass");
            const configured = try storage.configure(&configuration, .{});
            try std.testing.expect(configured == .accepted);
            const session = configured.accepted.session;
            try submitTestMessage(&storage, &tmp, "bash-matrix-input", "bash-matrix-input", session.slice(), "propose");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCallsForTesting(&storage, &tmp, model, "bash-matrix-calls", &.{.{ .item_id = "one", .name = "bash", .encoded_call_id = "one", .decoded_call_id = "one", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"true\\\"}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"true\"}" }});
            const id = try store_testing.sqlite_only.queryU64(&storage, "SELECT action_id FROM action_operation", .{});
            switch (case) {
                .ready => {},
                .unauthorized => try store_testing.sqlite_only.exec(&storage, "UPDATE action_operation SET authorized=0,decided_at=NULL", .{}),
                .resolved => try store_testing.sqlite_only.exec(&storage, "UPDATE action_operation SET resolution_code='failed',resolution_content_id=(SELECT min(content_id) FROM content),acceptance_position=1,resolved_at=1", .{}),
                .attempted => try store_testing.sqlite_only.exec(&storage, "UPDATE action_operation SET attempt_ordinal=1,attempt_at=1,attempt_timeout_ms=1", .{}),
                .closed => try store_testing.sqlite_only.exec(&storage, "UPDATE turn SET outcome_code='cancelled',outcome_at=1", .{}),
                .stopped => try store_testing.sqlite_only.exec(&storage, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) SELECT 'bash-matrix',session_ref,turn_id,0,1 FROM turn", .{}),
            }
            result.* = if (entry == 0)
                (try storage.admitNextActionAttempt(300_000, .{})) != null
            else
                (try storage.admitActionAttempt(.{ .action_id = id, .runner = .bash }, 300_000, .{})) != null;
        }
        try std.testing.expectEqual(case == .ready, results[0]);
        try std.testing.expectEqual(results[0], results[1]);
    }
}
