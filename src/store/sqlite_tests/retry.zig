//! Retry SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const retry_policy = @import("../../retry_policy.zig");
const store_core = @import("../Store.zig");
const transition = @import("../transition.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const model_admission_domain = @import("../domain/model_admission.zig");
const model_settlement_domain = @import("../domain/model_settlement.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const ActiveOperationFilter = action_domain.ActiveOperationFilter;
const AttemptBinding = store_core.AttemptBinding;
const ModelFailure = model_settlement_domain.ModelFailure;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const completeMessage = store_testing.completeMessage;
const configureTestSession = store_testing.configureTestSession;
const empty_active_context = action_domain.empty_active_context;
const retry_admission_page_rows = model_admission_domain.retry_admission_page_rows;
const retry_admission_select_sql = model_admission_domain.retry_admission_select_sql;
const retry_exhausted_sql = model_admission_domain.retry_exhausted_sql;
const submitTestMessage = store_testing.submitTestMessage;
const admitRetryForTesting = tests.admitRetryForTesting;
const expectActivityOutcome = tests.expectActivityOutcome;
const testingListRow = tests.testingListRow;
const testingStore = store_testing.testingSqliteStore;
const expectDenseSessionPositions = shared_fixtures.expectDenseSessionPositions;

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
        const created_session_0_reply = try storage.configure(&configuration, .{});
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
        const observation = (try store_testing.observeCommandForTesting(&storage, "failure-message")).kind.message.?.queue.?;
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
        const recovered = (try store_testing.observeCommandForTesting(&storage, "failure-message")).kind.message.?.queue.?;
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
        const exhausted = (try store_testing.observeCommandForTesting(&storage, "failure-message")).kind.message.?.queue.?;
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
        const Inner = model_settlement_domain.ClaimAuthRefresh;
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
            if (next == .commit) sqlite.exec(t.storage.sqliteDatabase(), "UPDATE model_operation SET auth_refresh_claimed=1") catch unreachable;
            return next;
        }

        pub fn committed(t: *const @This()) Result {
            return Inner.committed(&t.inner);
        }

        pub fn declined(t: *const @This(), err: Declined) Result {
            return Inner.declined(&t.inner, err);
        }
    };
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var interposed: Interposed = .{ .inner = .{ .input = .{ .binding = binding } }, .storage = &storage };
        try std.testing.expect(!try entry.finishTransaction(store_core.Ordinary.attempt_binding, .{}, transition.run(&entry, Interposed, &interposed, .{})));
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
    const created_session_0_reply = try storage.configure(&configuration, .{});
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

    const observation = (try store_testing.observeCommandForTesting(&storage, "retry-message")).kind.message.?.queue.?;
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
            "SELECT session_ref,'/w','codex','openai-responses/1','m',1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session LIMIT 1),0,1,1,1,base+row_number() OVER (ORDER BY session_ref),zeroblob(32),base+1 " ++
            "FROM (SELECT DISTINCT session_ref FROM model_operation),(SELECT coalesce(max(created_seq),0) AS base FROM session)",
    );
}

test "retry due index excludes future population and preserves age ordering" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    _ = try configureTestSession(&storage, "retry-population-offer");

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
                "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at,tool_set_id,context_window) " ++
                "SELECT value,value,printf('%06d',value),1,1,1,1,9223372036854775807,0,1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session LIMIT 1),0 FROM sequence; " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at,tool_set_id,context_window) VALUES" ++
                "({1},{1},'0der00',1,1,1,1,99,0,1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session LIMIT 1),0),({2},{2},'ear1er',1,1,1,1,1,0,1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session LIMIT 1),0)",
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
                "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at,tool_set_id,context_window) " ++
                "SELECT value,value,printf('%06d',value),1,1,1,1,1,0,1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session LIMIT 1),0 FROM sequence",
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
        "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at,tool_set_id,context_window) VALUES" ++
        "(1,1,'000001',1,1,1,1,99,0,1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session LIMIT 1),0)," ++
        "(2,2,'000002',1,1,1,1,50,0,1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session LIMIT 1),0)," ++
        "(3,3,'000003',1,1,1,1,1,0,1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session LIMIT 1),0)", .{});
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
    }, .{}, null)).?;
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
    _ = try configureTestSession(&storage, "retry-population-offer");

    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    const insert = try std.testing.allocator.printSentinel(
        "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{d}) " ++
            "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
            "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at,tool_set_id,context_window) " ++
            "SELECT value,value,printf('%06d',value),1,1,1,1,1,0,1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session LIMIT 1),0 FROM sequence",
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
    const admitted = (try storage.tryAdmitNextModelRetry(active_filter, .{}, null)).?;
    try std.testing.expectEqual(@as(u64, retry_admission_page_rows + 1), admitted.permit.binding.operation_id);
}

test "retry transitions preserve age and settle one exhausted outcome per call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    _ = try configureTestSession(&storage, "retry-population-offer");

    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    try store_testing.sqlite_only.exec(&storage, "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<201) " ++
        "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
        "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at,tool_set_id,context_window) " ++
        "SELECT value,value,printf('%06d',value),1,1,1,1," ++
        "CASE WHEN value<=100 THEN 9223372036854775807 ELSE 1 END,0,1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session LIMIT 1),0 FROM sequence", .{});
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
        storage.tryAdmitNextModelRetry(active_filter, .{ .attempt_before_commit = true }, null),
    );
    try std.testing.expect(storage.isFenced());
    try std.testing.expectEqual(@as(usize, 5150), comparisons);
    comparisons = 0;
    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    const admitted = (try storage.tryAdmitNextModelRetry(active_filter, .{}, null)).?;
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
            "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,attempt_at,tool_set_id,context_window) " ++
            "VALUES(?1,?1,?2,1,1,1,4,0,0,1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session WHERE session_ref=?2),0)");
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
