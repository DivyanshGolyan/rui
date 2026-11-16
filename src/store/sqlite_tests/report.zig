//! Report SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const command_domain = @import("../domain/command.zig");
const reads_domain = @import("../domain/reads.zig");
const report_domain = @import("../domain/report.zig");
const session_report_read_domain = @import("../domain/session_report_read.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const ActionExecutionInput = action_domain.ActionExecutionInput;
const PermissionDecisionReply = command_domain.PermissionDecisionReply;
const TestingAnswerPart = store_testing.TestingAnswerPart;
const answerTestTurn = store_testing.answerTestTurn;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const pending_message_count_sql = command_domain.pending_message_count_sql;
const session_stop_cutoff_sql = command_domain.session_stop_cutoff_sql;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = tests.TestingCall;
const TestingWorkShape = tests.TestingWorkShape;
const completeSessionStop = tests.completeSessionStop;
const configureTestSessionAsk = tests.configureTestSessionAsk;
const costCycleForTesting = tests.costCycleForTesting;
const namedStatementForTesting = tests.namedStatementForTesting;
const settleCallsForTesting = tests.settleCallsForTesting;
const settleCallsForTestingWithFaults = tests.settleCallsForTestingWithFaults;
const settleTwoActionsForTesting = tests.settleTwoActionsForTesting;
const rejectedCallsForTesting = tests.rejectedCallsForTesting;
const testingBytesContent = tests.testingBytesContent;
const testingSessionReport = tests.testingSessionReport;
const testingSessionReportWithProfile = tests.testingSessionReportWithProfile;
const testingStore = store_testing.testingSqliteStore;
const TestingStatementFault = shared_fixtures.TestingStatementFault;
const expectDenseSessionPositions = shared_fixtures.expectDenseSessionPositions;

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
    try std.testing.expectEqual(protocol.MessageProgressStatus.runnable, (try store_testing.observeCommandForTesting(&storage, "selection-next")).kind.message.?.work.?.state.progress().?);
    try std.testing.expect((try store_testing.observeCommandForTesting(&storage, "selection-message-11")).kind.message.?.work == null);
    {
        const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer report.deinit();
        try std.testing.expectEqualStrings("selection-next", report.value.object.get("selected_message").?.string);
    }
    _ = (try storage.admitNextModelAttempt(.{})).?;
    try submitTestMessage(&storage, &tmp, "selection-queued-file", "selection-queued", session.slice(), "queued");
    const queued = (try store_testing.observeCommandForTesting(&storage, "selection-queued")).kind.message.?;
    try std.testing.expect(queued.queue.?.state == .queued);
    try std.testing.expectEqual(protocol.MessageProgressStatus.in_flight, queued.work.?.state.progress().?);
    try std.testing.expect(queued.work.?.first_action == null);
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
    try std.testing.expectError(error.CorruptStore, tests.testingCaptureSessionReport(&report_store, allocated_session_0.slice(), .{
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
                    var input: ActionExecutionInput = undefined;
                    break :blk storage.readActionExecutionInput(.bash, action.permit.binding, &input);
                },
            };
            try std.testing.expectError(error.CorruptStore, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, storage.admitNextActionAttempt(300_000, .{}));
        }
    }
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
            var report = try tests.testingCaptureSessionReport(&storage, session.slice(), .{
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

test "canonical observation failure fences later admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("create", "", workspace, "model-a");
    const created_session_0_reply = try storage.configure(&command, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;

    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET instructions_content_id=9223372036854775807 WHERE session_ref=?1", .{created_session_0.slice()});
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
    try std.testing.expectError(error.CorruptStore, storage.inspectSessionForTesting(created_session_0.slice()));

    var later = try completeConfiguration("later", "", workspace, "model-a");
    try std.testing.expect(try storage.configure(&later, .{}) == .infrastructure_failure);
    try std.testing.expectError(error.StoreFenced, store_testing.observeCommandForTesting(&storage, "later"));
}

test "a Current report's step faults answer the name of the earliest round that steps the table" {
    // Each read keeps main's name; when reads in two rounds fail, the
    // earlier round's name wins. The Action count steps after the tool
    // outcome rule in their round, so a faulted action_operation answers
    // the rule's CallReadFailed. Model-bound compaction facts read the
    // producing session_revision before Action lists and answer CorruptStore
    // for that fault. With no Turn or list to read, an idle Session does not
    // step session_revision.
    inline for (.{
        .{ TestingWorkShape.awaiting, "model_tool_call", error.CallReadFailed },
        .{ TestingWorkShape.awaiting, "action_operation", error.CallReadFailed },
        .{ TestingWorkShape.awaiting, "session_revision", error.CorruptStore },
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
        .{ namedStatementForTesting(session_report_read_domain.current_failures, null, "a.resolution_code IS NULL ORDER BY a.action_id"), error.ActionReadFailed },
        .{ namedStatementForTesting(session_report_read_domain.current_failures, null, "CROSS JOIN content rejection"), error.CallReadFailed },
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
    var reconfigure: wire_request.ConfigureCommand = .{};
    try reconfigure.key.set("probe-reconfigure");
    try reconfigure.session.set(session.slice());
    reconfigure.configuration.instructions = try testingBytesContent(tmp, "probe-instructions", "Be brief and careful.");
    reconfigure.configuration.label.state = .value;
    try reconfigure.configuration.label.value.set("probe label");
    try std.testing.expect(try storage.configure(&reconfigure, .{}) == .accepted);
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
