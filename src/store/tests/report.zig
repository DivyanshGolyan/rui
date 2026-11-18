const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const reads_domain = @import("../domain/reads.zig");
const report_domain = @import("../domain/report.zig");
const session_report_read_domain = @import("../domain/session_report_read.zig");
const store_testing = @import("../testing.zig");
const ActionSettlement = action_domain.ActionSettlement;
const ActionExecutionInput = action_domain.ActionExecutionInput;
const TestingAnswerPart = store_testing.TestingAnswerPart;
const answerTestTurn = store_testing.answerTestTurn;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = shared_fixtures.TestingCall;
const TestingReportReply = shared_fixtures.TestingReportReply;
const TestingWorkShape = shared_fixtures.TestingWorkShape;
const TwinRounds = shared_fixtures.TwinRounds;
const admitRetryForTesting = shared_fixtures.admitRetryForTesting;
const completeSessionStop = shared_fixtures.completeSessionStop;
const configureTestSessionAsk = shared_fixtures.configureTestSessionAsk;
const expectOneWork = shared_fixtures.expectOneWork;
const rejectedCallsForTesting = shared_fixtures.rejectedCallsForTesting;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const settleCallsForTestingWithFaults = shared_fixtures.settleCallsForTestingWithFaults;
const settleTwoActionsForTesting = shared_fixtures.settleTwoActionsForTesting;
const testingCaptureSessionReport = shared_fixtures.testingCaptureSessionReport;
const testingSessionReport = shared_fixtures.testingSessionReport;
const testingSessionReportWithProfile = shared_fixtures.testingSessionReportWithProfile;

test "Current excludes history while Full exposes exact closed Session inventory" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "profile-config");

            const current = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
            defer std.testing.allocator.free(current);
            try std.testing.expect(std.mem.indexOf(u8, current, "\"profile\":\"current\"") != null);
            var parsed_current = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, current, .{});
            defer parsed_current.deinit();
            try std.testing.expect(parsed_current.value.object.get("full") == null);
            try std.testing.expectEqualStrings("full", parsed_current.value.object.get("delta").?.string);
            try std.testing.expect(parsed_current.value.object.get("since").? == .null);

            const text = try std.testing.allocator.alloc(u8, 64 * 1024);
            defer std.testing.allocator.free(text);
            @memset(text, 1);
            try submitTestMessage(&storage, &tmp, "profile-message", "profile-message", session.slice(), text);
            _ = (try storage.admitNextModelAttempt(.{})).?;
            const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 512 * 1024, .full);
            defer std.testing.allocator.free(full);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings("full", parsed.value.object.get("profile").?.string);
            const inventory = parsed.value.object.get("full").?.object;
            inline for (.{ "session_revisions", "messages", "conversation", "turns", "model_operations", "tool_calls", "actions", "permission_decisions", "session_stops", "model_interruptions", "tool_results" }) |name| {
                try std.testing.expect(inventory.get(name) != null);
            }
            try std.testing.expectEqualStrings(text, inventory.get("messages").?.array.items[0].object.get("content").?.object.get("text").?.string);
            const conversation_content = inventory.get("conversation").?.array.items[0].object.get("content").?.object;
            try std.testing.expectEqualStrings("65536", conversation_content.get("bytes").?.string);
            const digest = protocol.contentDigest(text);
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), conversation_content.get("sha256").?.string);
            try std.testing.expect(conversation_content.get("text") == null);
        }
    }.run);
}

test "Current preserves empty Message identity across queue, active Turn and history" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "empty-key-config");
            try submitTestMessage(&storage, &tmp, "empty-key-file", "", session.slice(), "input");
            try std.testing.expectEqual(protocol.MessageProgressStatus.runnable, (try store_testing.observeCommandForTesting(&storage, "")).kind.message.?.work.?.state.progress().?);
            {
                const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
                defer std.testing.allocator.free(bytes);
                var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                defer report.deinit();
                try std.testing.expectEqualStrings("", report.value.object.get("selected_message").?.string);
            }
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(protocol.MessageProgressStatus.in_flight, (try store_testing.observeCommandForTesting(&storage, "")).kind.message.?.work.?.state.progress().?);
            {
                const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
                defer std.testing.allocator.free(bytes);
                var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                defer report.deinit();
                try std.testing.expectEqualStrings("", report.value.object.get("selected_message").?.string);
            }
            try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
            try std.testing.expect((try store_testing.observeCommandForTesting(&storage, "")).kind.message.?.work == null);
            try submitTestMessage(&storage, &tmp, "after-empty-file", "after-empty", session.slice(), "next");
            {
                const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
                defer std.testing.allocator.free(bytes);
                var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                defer report.deinit();
                try std.testing.expectEqualStrings("after-empty", report.value.object.get("selected_message").?.string);
                try std.testing.expectEqualStrings("", report.value.object.get("recent_messages").?.array.items[0].object.get("message").?.string);
            }
        }
    }.run);
}

test "Full preserves rejected model interruption targets as canonical u64 text" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "interrupt-report-config");

            const targets = [_]struct { key: []const u8, turn: u64, operation: u64 }{
                .{ .key = "zero-turn", .turn = 0, .operation = 1 },
                .{ .key = "zero-operation", .turn = 1, .operation = 0 },
                .{ .key = "wide-targets", .turn = @as(u64, std.math.maxInt(i64)) + 1, .operation = std.math.maxInt(u64) },
            };
            for (targets) |target| {
                var command: protocol.ModelInterruptionCommand = .{ .turn_id = target.turn, .operation_id = target.operation };
                try command.key.set(target.key);
                try command.session.set(session.slice());
                const rejected = storage.interruptModel(&command, .{});
                try std.testing.expect(rejected == .rejected);
                try std.testing.expectEqual(protocol.ModelInterruptionRejection.invalid_target, rejected.rejected.code);
                const replay = storage.interruptModel(&command, .{});
                try std.testing.expect(replay == .rejected);
                try std.testing.expect(replay.rejected.replayed);
            }

            const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(full);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
            defer parsed.deinit();
            const interruptions = parsed.value.object.get("full").?.object.get("model_interruptions").?.array.items;
            try std.testing.expectEqual(targets.len, interruptions.len);
            for (targets, interruptions) |target, interruption| {
                const object = interruption.object;
                try std.testing.expectEqualStrings(target.key, object.get("command_key").?.string);
                try std.testing.expectEqualStrings("rejected", object.get("status").?.string);
                try std.testing.expectEqualStrings("invalid_target", object.get("code").?.string);
                var expected_turn: [20]u8 = undefined;
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected_turn, "{d}", .{target.turn}), object.get("turn").?.string);
                var expected_operation: [20]u8 = undefined;
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected_operation, "{d}", .{target.operation}), object.get("operation").?.string);
            }
            try std.testing.expect(!storage.isFenced());
            try std.testing.expect((try storage.inspectSessionForTesting(session.slice())).found);
        }
    }.run);
}

test "work uses the latest Resolution position across foreground and background Actions when clocks step backward" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]?usize{ null, 0, 1 }) |promoted| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionAsk(&storage, "resolution-config");
                try submitTestMessage(&storage, &tmp, "resolution-file", "resolution-message", session.slice(), "propose");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleTwoActionsForTesting(&storage, &tmp, binding, "resolution-calls");
                const first = try store_testing.queryU64(&storage, "SELECT min(action_id) FROM action_operation WHERE parent_operation_id=?1", .{binding.operation_id});
                const last = try store_testing.queryU64(&storage, "SELECT max(action_id) FROM action_operation WHERE parent_operation_id=?1", .{binding.operation_id});
                const actions = [_]u64{ first, last };
                var fulfillments = [_]?u64{ null, null };
                var finals = [_]?u64{ null, null };
                if (promoted) |index| {
                    var command: @import("../../command_input.zig").ActionBackgroundCommand = .{ .session = session, .action_id = actions[index] };
                    try command.key.set("resolution-promote");

                    const accepted = storage.backgroundAction(.{ .command = &command }, .{});
                    try std.testing.expect(accepted == .accepted);
                    fulfillments[index] = accepted.accepted.selection.position;
                }
                for (actions, [_]u64{ 900, 400 }, [_][]const u8{ "resolution-first", "resolution-last" }, 0..) |action, at, key, index| {
                    var deny: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = action, .decision = .deny };
                    try deny.key.set(key);
                    try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
                    finals[index] = try store_testing.queryU64(&storage, "SELECT acceptance_position FROM action_operation WHERE action_id=?1", .{action});
                    if (fulfillments[index] == null) fulfillments[index] = finals[index];
                    try store_testing.exec(&storage, "UPDATE action_operation SET resolved_at=?1 WHERE action_id=?2", .{ at, action });
                    const work = (try store_testing.observeCommandForTesting(&storage, "resolution-message")).kind.message.?.work.?;
                    try std.testing.expectEqual(at, work.state.since());
                    try std.testing.expectEqual(if (index == 0) protocol.MessageProgressStatus.waiting_for_permission else .runnable, work.state.progress().?);
                    var request: protocol.ActivityPage = .{};
                    try request.session.set(session.slice());
                    const page = try store_core.activityPageForTesting(&storage, request);
                    try std.testing.expectEqual(at, page.work.work.state.since());
                    const bytes = try shared_fixtures.testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
                    defer std.testing.allocator.free(bytes);
                    var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                    defer report.deinit();
                    const resolved = report.value.object.get("actions").?.object.get("resolved").?.array.items;
                    try std.testing.expectEqual(index + 1, resolved.len);
                    const publication: ?u64 = if (fulfillments[0] != null and fulfillments[1] != null) @max(fulfillments[0].?, fulfillments[1].?) else null;
                    for (resolved, 0..) |row, ordinal| {
                        try std.testing.expectEqual(actions[ordinal], try std.fmt.parseInt(u64, row.object.get("action").?.string, 10));
                        try std.testing.expectEqualStrings("denied", row.object.get("code").?.string);
                        try std.testing.expectEqual(finals[ordinal].?, try std.fmt.parseInt(u64, row.object.get("acceptance_position").?.string, 10));
                        const saved = row.object.get("presentation").?.object.get("publication_position").?;
                        const expected = if (promoted != null and promoted.? == ordinal) null else publication;
                        if (expected) |position| {
                            try std.testing.expectEqual(position, try std.fmt.parseInt(u64, saved.string, 10));
                        } else try std.testing.expect(saved == .null);
                    }
                }
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

test "Current, activity pages and Message progress report one work through an approval" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "mixed-config");
            try submitTestMessage(&storage, &tmp, "mixed-file", "mixed-message", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try submitTestMessage(&storage, &tmp, "mixed-queued-file", "mixed-queued", session.slice(), "wait behind approval");
            try settleTwoActionsForTesting(&storage, &tmp, binding, "mixed-metadata");
            const before = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
            defer std.testing.allocator.free(before);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, before, .{});
            defer parsed.deinit();
            const first = parsed.value.object.get("actions").?.object.get("unresolved").?.array.items[0];
            const action_id = try std.fmt.parseInt(u64, first.object.get("action").?.string, 10);
            try std.testing.expectEqualStrings("approval", parsed.value.object.get("work").?.object.get("state").?.object.get("kind").?.string);
            try pageWorkAgrees(&storage, parsed.value, action_id);
            var rounds = storage.testing_content_work.rounds;
            try std.testing.expectEqual(protocol.MessageProgressStatus.waiting_for_permission, (try store_testing.observeCommandForTesting(&storage, "mixed-message")).kind.message.?.work.?.state.progress().?);
            try std.testing.expectEqual(rounds + 1, storage.testing_content_work.rounds);
            rounds = storage.testing_content_work.rounds;
            const queued = try store_testing.observeCommandForTesting(&storage, "mixed-queued");
            try std.testing.expectEqual(rounds + 1, storage.testing_content_work.rounds);
            try std.testing.expect(queued.kind.message.?.queue.?.state == .queued);
            try std.testing.expectEqual(protocol.MessageRequestState.waiting_for_permission, queued.requestState().?);
            try std.testing.expectEqual(action_id, queued.kind.message.?.work.?.first_action.?);
            var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
            try allow.key.set("mixed-allow");
            try allow.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);

            const after = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
            defer std.testing.allocator.free(after);
            var mixed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, after, .{});
            defer mixed.deinit();
            try std.testing.expectEqualStrings("pending", mixed.value.object.get("work").?.object.get("state").?.object.get("kind").?.string);
            try std.testing.expectEqual(@as(usize, 1), mixed.value.object.get("actionable_permissions").?.array.items.len);
            var message = (try store_testing.observeCommandForTesting(&storage, "mixed-message")).kind.message.?;
            try std.testing.expectEqualStrings("processing", @tagName(message.queue.?.state));
            try std.testing.expectEqual(protocol.MessageProgressStatus.runnable, message.work.?.state.progress().?);
            try std.testing.expectEqual(action_id + 1, message.work.?.first_action.?);
            try pageWorkAgrees(&storage, mixed.value, action_id + 1);

            _ = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?;
            const running = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
            defer std.testing.allocator.free(running);
            var bash = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, running, .{});
            defer bash.deinit();
            const state = bash.value.object.get("work").?.object.get("state").?.object;
            try std.testing.expectEqualStrings("bash", state.get("kind").?.string);
            try std.testing.expectEqualStrings("1", state.get("running").?.string);
            try std.testing.expectEqualStrings("1", state.get("approvals").?.string);
            rounds = storage.testing_content_work.rounds;
            message = (try store_testing.observeCommandForTesting(&storage, "mixed-message")).kind.message.?;
            try std.testing.expectEqual(rounds + 1, storage.testing_content_work.rounds);
            try std.testing.expectEqual(protocol.MessageProgressStatus.in_flight, message.work.?.state.progress().?);
            try pageWorkAgrees(&storage, bash.value, action_id + 1);
        }
    }.run);
}

fn pageWorkAgrees(store: *Store, report: std.json.Value, first_action: u64) !void {
    var request: protocol.ActivityPage = .{};
    try request.session.set(report.object.get("session").?.object.get("reference").?.string);
    const page = try store_core.activityPageForTesting(store, request);
    const work = report.object.get("work").?.object;
    var state: [protocol.WorkStateJson.max_json_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&state);
    try std.json.Stringify.value(work.get("state").?, .{}, &writer);
    var page_state: [protocol.WorkStateJson.max_json_bytes]u8 = undefined;
    var page_writer: std.Io.Writer = .fixed(&page_state);
    try (protocol.WorkStateJson{ .state = page.work.work.state }).writeJson(&page_writer);
    try std.testing.expectEqualStrings(writer.buffered(), page_writer.buffered());
    try std.testing.expectEqual(try std.fmt.parseInt(u64, work.get("turn").?.string, 10), page.work.work.turn.?);
    try std.testing.expectEqual(try std.fmt.parseInt(u64, work.get("operation").?.string, 10), page.work.work.operation.?);
    try std.testing.expectEqual(first_action, page.work.work.first_action.?);
    const session = report.object.get("session").?.object;
    try std.testing.expectEqual(try std.fmt.parseInt(u64, session.get("revision").?.string, 10), page.work.revision);
    try std.testing.expectEqualStrings(session.get("workspace").?.string, page.work.workspace.slice());
}

fn expectProgress(storage: *Store, key: []const u8, status: protocol.MessageProgressStatus) !void {
    const message = (try store_testing.observeCommandForTesting(storage, key)).kind.message.?;
    try std.testing.expectEqual(status, message.work.?.state.progress().?);
}

test "Current, activity pages and Message progress report one work in each state" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const session = try configureTestSession(&storage, "one-work-config");
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT created_at FROM session", .{}), try expectOneWork(&storage, &tmp, session.slice(), "idle"));

            try submitTestMessage(&storage, &tmp, "one-work-file", "one-work-message", session.slice(), "first");
            _ = try expectOneWork(&storage, &tmp, session.slice(), "pending");
            try expectProgress(&storage, "one-work-message", .runnable);
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT attempt_at FROM model_operation", .{}), try expectOneWork(&storage, &tmp, session.slice(), "working"));
            try expectProgress(&storage, "one-work-message", .in_flight);

            try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "provider_temporary_http_429" }, .{ .retryable = .{ .waits_ms = .{ 60_000, 60_000, 60_000 } } }, .{});
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT retry_scheduled_at FROM model_operation", .{}), try expectOneWork(&storage, &tmp, session.slice(), "retrying"));
            try expectProgress(&storage, "one-work-message", .in_flight);
            try store_testing.exec(&storage, "UPDATE model_operation SET retry_due_at_ms=1 WHERE resolution_code IS NULL", .{});
            _ = try expectOneWork(&storage, &tmp, session.slice(), "pending");
            try expectProgress(&storage, "one-work-message", .runnable);

            const retry = (try admitRetryForTesting(&storage)).?.permit.binding;
            var diagnostic: [512]u8 = undefined;
            const quota: @import("../../transport_policy.zig").Quota = .{ .refusal = .quota, .resets_at = 1792940000 };
            try storage.settleModelAttemptFailure(retry, .{ .rejected = .{ .code = quota.failureCode(), .diagnostic = quota.format(&diagnostic), .request_id = .{}, .report = "" } }, .ordinary, .{});
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT outcome_at FROM turn", .{}), try expectOneWork(&storage, &tmp, session.slice(), "failed"));
            {
                var request: protocol.ActivityPage = .{};
                try request.session.set(session.slice());
                const failed = (try store_core.activityPageForTesting(&storage, request)).work.work.state.failed;
                try std.testing.expectEqualStrings("provider_quota", failed.code.slice());
                try std.testing.expectEqual(@as(?u64, 1792940000), failed.resets_at);
            }

            const done = try configureTestSession(&storage, "one-work-done");
            const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
            try answerTestTurn(&storage, &tmp, done.slice(), "one-work-answer", &answer);
            _ = try expectOneWork(&storage, &tmp, done.slice(), "finished");

            const bash = try configureTestSessionAsk(&storage, "one-work-bash");
            try submitTestMessage(&storage, &tmp, "one-work-bash-file", "one-work-bash-message", bash.slice(), "propose");
            const proposing = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, proposing, "one-work-bash-metadata");
            _ = try expectOneWork(&storage, &tmp, bash.slice(), "approval");
            try expectProgress(&storage, "one-work-bash-message", .waiting_for_permission);
            var allow: protocol.PermissionDecisionCommand = .{ .action_id = try store_testing.queryU64(&storage, "SELECT min(action_id) FROM action_operation", .{}), .decision = .allow_once };
            try allow.key.set("one-work-allow");
            try allow.session.set(bash.slice());
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            const action = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?.permit.binding;
            _ = try expectOneWork(&storage, &tmp, bash.slice(), "bash");
            try expectProgress(&storage, "one-work-bash-message", .in_flight);
            var stop = try completeSessionStop("one-work-stop", bash.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT stopped_at FROM session_stop", .{}), try expectOneWork(&storage, &tmp, bash.slice(), "stopping"));
            try expectProgress(&storage, "one-work-bash-message", .in_flight);
            _ = try storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{});
            _ = try expectOneWork(&storage, &tmp, bash.slice(), "stopped");
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "Full reports every closed Action resolution without fencing" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const session = try configureTestSessionAsk(&storage, "shutdown-report-config");
            try submitTestMessage(&storage, &tmp, "shutdown-report-message", "shutdown-report-message", session.slice(), "execute");
            const model_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{.{
                .item_id = "shutdown-report-item",
                .name = "bash",
                .encoded_call_id = "shutdown-report-call",
                .decoded_call_id = "shutdown-report-call",
                .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":1234}",
                .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":1234}",
            }};
            try settleCallsForTesting(&storage, &tmp, model_binding, "shutdown-report-metadata", &calls);
            const action_id = try store_testing.queryU64(&storage, "SELECT action_id FROM action_operation", .{});
            var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
            try allow.key.set("shutdown-report-allow");
            try allow.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            const action_binding = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?.permit.binding;
            var input: ActionExecutionInput = undefined;
            try storage.readActionExecutionInput(.bash, action_binding, &input);
            try std.testing.expectEqual(@as(u64, 1234), input.timeout_ms);
            try std.testing.expectEqual(
                ActionSettlement.effect,
                try storage.settleActionAttempt(action_binding, .infrastructure_shutdown, "Host shutdown.", .{}),
            );

            const report_bytes = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(report_bytes);
            var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report_bytes, .{});
            defer report.deinit();
            const actions = report.value.object.get("full").?.object.get("actions").?.array.items;
            try std.testing.expectEqual(@as(usize, 1), actions.len);
            try std.testing.expectEqualStrings("infrastructure_shutdown", actions[0].object.get("resolution").?.string);
            try std.testing.expectEqualStrings("Host shutdown.", actions[0].object.get("result").?.object.get("text").?.string);
            try std.testing.expect(!storage.isFenced());
            _ = try storage.inspectSessionForTesting(session.slice());
        }
    }.run);
}

test "report scratch exhaustion is an observation failure without Store fencing" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "report-config");
            var root: [protocol.max_store_bytes]u8 = undefined;
            const root_length = try tmp.dir.realPath(std.testing.io, &root);
            var used = std.atomic.Value(u64).init(0);
            try std.testing.expectError(error.ReportScratchExhausted, testingCaptureSessionReport(&storage, session.slice(), .{
                .scratch_path = root[0..root_length],
                .scratch_budget = .{ .used = &used, .limit = 1 },
                .request_number = 1,
                .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 },
            }));
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            try std.testing.expect(!storage.isFenced());
            try std.testing.expect((try storage.inspectSessionForTesting(session.slice())).found);
        }
    }.run);
}

test "report unlink failure retains a startup-owned zero-request file" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "report-unlink-config");
            var root: [protocol.max_store_bytes]u8 = undefined;
            const root_length = try tmp.dir.realPath(std.testing.io, &root);
            var used = std.atomic.Value(u64).init(0);
            try std.testing.expectError(error.ReportScratchCleanupFailed, testingCaptureSessionReport(&storage, session.slice(), .{
                .scratch_path = root[0..root_length],
                .scratch_budget = .{ .used = &used, .limit = 1024 * 1024 },
                .request_number = 0,
                .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 },
                .fail_unlink = true,
            }));
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            try std.testing.expectEqual(std.Io.File.Kind.file, (try tmp.dir.statFile(std.testing.io, "report-0-1.tmp", .{})).kind);
            try tmp.dir.deleteFile(std.testing.io, "report-0-1.tmp");
        }
    }.run);
}

fn reportRoundsForTesting(case: *store_testing.Case, shape: TestingWorkShape) !u32 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try shape.make(&storage, &tmp, "report-rounds");
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
    var reply: TestingReportReply = .{ .capture = &capture, .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 } };
    var watched: session_report_read_domain.Watched(*TestingReportReply) = .{ .visitor = &reply };
    const before = storage.testing_content_work.rounds;
    try std.testing.expect(try session_report_read_domain.readHead(&a, session.slice(), .current, &watched));
    return storage.testing_content_work.rounds - before;
}

test "a Current report takes its reads' dependency depth in rounds, not its rows" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try std.testing.expectEqual(@as(u32, 6), try reportRoundsForTesting(case, .idle));
            try std.testing.expectEqual(@as(u32, 6), try reportRoundsForTesting(case, .finished));
            try std.testing.expectEqual(@as(u32, 8), try reportRoundsForTesting(case, .stopped));
            try std.testing.expectEqual(@as(u32, 7), try reportRoundsForTesting(case, .awaiting));
        }
    }.run);
}

test "Current report work is independent of terminal tool history, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try std.testing.expectEqual(try measure(case, 16), try measure(case, 64));
        }

        fn measure(engine: *store_testing.Case, group_count: usize) !u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "current-cost-config");
            const calls = [_]TestingCall{.{ .item_id = "current-cost-item", .name = "unknown", .encoded_call_id = "current-cost-call", .decoded_call_id = "current-cost-call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            for (0..group_count) |index| {
                var file_buffer: [64]u8 = undefined;
                var key_buffer: [64]u8 = undefined;
                var metadata_buffer: [64]u8 = undefined;
                try submitTestMessage(&storage, &tmp, try std.fmt.bufPrint(&file_buffer, "current-cost-file-{d}", .{index}), try std.fmt.bufPrint(&key_buffer, "current-cost-message-{d}", .{index}), session.slice(), "call");
                const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCallsForTesting(&storage, &tmp, source, try std.fmt.bufPrint(&metadata_buffer, "current-cost-metadata-{d}", .{index}), &calls);
                const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(continuation, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
            }
            try submitTestMessage(&storage, &tmp, "current-cost-active-file", "current-cost-active-message", session.slice(), "active");
            const active = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCallsForTestingWithFaults(&storage, &tmp, active, "current-cost-active-metadata", &calls, .{}, "{\"input_tokens\":10,\"output_tokens\":0}");
            var root: [protocol.max_store_bytes]u8 = undefined;
            const root_length = try tmp.dir.realPath(std.testing.io, &root);
            var used = std.atomic.Value(u64).init(0);
            const counter = TwinRounds.start(&storage);
            var report = try testingCaptureSessionReport(&storage, session.slice(), .{
                .scratch_path = root[0..root_length],
                .scratch_budget = .{ .used = &used, .limit = 1024 * 1024 },
                .request_number = 1,
                .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 },
            });
            const taken = counter.taken();
            report.deinit();
            return taken;
        }
    }.run);
}

test "a Current report's work grows linearly in one Operation's calls, as main's did, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var rounds: [3]u16 = undefined;
            inline for (.{ 16, 64, 256 }, &rounds) |calls, *cost| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try rejectedCallsForTesting(&storage, &tmp, calls);
                const counter = TwinRounds.start(&storage);
                std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024 * 1024, .current));
                cost.* = counter.taken();
            }
            std.testing.expect(rounds[0] == rounds[1] and rounds[1] == rounds[2]) catch |err| {
                std.debug.print("rounds: {any}\n", .{rounds});
                return err;
            };
        }
    }.run);
}

test "served work intents imply admission across permission and control states" {
    try store_testing.forEachEngine(struct {
        const Scenario = enum { idle, queued, in_flight, retrying, finished, owed, stopped, stopping, stopping_queued, stopping_owed, approval, message_decline, mixed };
        const Intent = enum { stop, interrupt, decide };

        fn run(case: *store_testing.Case) !void {
            for (std.enums.values(Scenario)) |scenario| for (std.enums.values(Intent)) |intent| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionAsk(&storage, "intent-domain-config");
                var old_action: u64 = 0;
                if (scenario != .idle) {
                    try submitTestMessage(&storage, &tmp, "intent-input", "intent-first", session.slice(), "run");
                    if (scenario != .queued) {
                        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        if (scenario == .retrying) {
                            try storage.settleModelAttemptFailure(model, .{ .uncorrelated = "provider_temporary_http_429" }, .{ .retryable = .{ .waits_ms = .{ 60_000, 60_000, 60_000 } } }, .{});
                        } else if (scenario == .finished or scenario == .owed) {
                            try store_testing.settleItemsForTesting(&storage, &tmp, model, &.{"{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"Done.\"}]}"}, "Done.");
                            if (scenario == .owed) {
                                const child = try configureTestSession(&storage, "intent-owed-child");
                                try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ session.slice(), child.slice() });
                                try submitTestMessage(&storage, &tmp, "intent-owed-file", "intent-owed-message", child.slice(), "child work");
                                try shared_fixtures.refreshFrontiersForTesting(&storage, &.{ child.slice(), session.slice() });
                            }
                        } else if (scenario == .stopped) {
                            var stop = try completeSessionStop("intent-prior-stop", session.slice());
                            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                        } else if (scenario != .in_flight) {
                            try settleTwoActionsForTesting(&storage, &tmp, model, "intent-calls");
                            old_action = try store_testing.queryU64(&storage, "SELECT min(action_id) FROM action_operation WHERE session_ref=?1", .{session.slice()});
                            if (scenario == .stopping or scenario == .stopping_queued or scenario == .stopping_owed) {
                                var allow: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = old_action, .decision = .allow_once };
                                try allow.key.set("intent-allow-running");
                                try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
                                _ = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?;
                                var stop = try completeSessionStop("intent-running-stop", session.slice());
                                try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                                if (scenario == .stopping_queued) try submitTestMessage(&storage, &tmp, "intent-after-stop-file", "intent-after-stop", session.slice(), "new work");
                                if (scenario == .stopping_owed) {
                                    const child = try configureTestSession(&storage, "intent-stopping-child");
                                    try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ session.slice(), child.slice() });
                                    try submitTestMessage(&storage, &tmp, "intent-stopping-child-file", "intent-stopping-child-message", child.slice(), "child work");
                                    try shared_fixtures.refreshFrontiersForTesting(&storage, &.{ child.slice(), session.slice() });
                                }
                            }
                            if (scenario == .mixed) {
                                var promote: @import("../../command_input.zig").ActionBackgroundCommand = .{ .session = session, .action_id = old_action };
                                try promote.key.set("intent-promote");
                                try std.testing.expect(storage.backgroundAction(.{ .command = &promote }, .{}) == .accepted);
                                const other = try store_testing.queryU64(&storage, "SELECT max(action_id) FROM action_operation WHERE session_ref=?1", .{session.slice()});
                                var deny: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = other, .decision = .deny };
                                try deny.key.set("intent-deny-sibling");
                                try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
                            }
                            if (scenario == .message_decline or scenario == .mixed) {
                                try submitTestMessage(&storage, &tmp, "intent-next-file", "intent-next", session.slice(), "new instructions");
                            }
                            if (scenario == .mixed) {
                                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                                try settleTwoActionsForTesting(&storage, &tmp, next, "intent-next-calls");
                            }
                        }
                    }
                }
                if (scenario == .message_decline or scenario == .mixed) {
                    var late: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = old_action, .decision = .allow_once };
                    try late.key.set("intent-late-allow");
                    const rejected = storage.decidePermission(&late, .{});
                    try std.testing.expect(rejected == .rejected and rejected.rejected.code == .action_not_pending);
                }
                var request: protocol.ActivityPage = .{};
                request.session = session;
                const work = (try store_core.activityPageForTesting(&storage, request)).work.work;
                try std.testing.expectEqual(scenario != .idle and scenario != .finished and scenario != .stopped and scenario != .stopping, work.actions.stop);
                try std.testing.expectEqual(scenario == .in_flight, work.actions.interrupt != null);
                try std.testing.expectEqual(scenario == .approval or scenario == .mixed, work.actions.decide != null);
                try std.testing.expectEqual(work.actions.decide, work.first_action);
                if (scenario == .mixed) try std.testing.expect(work.actions.decide.? > old_action);
                if (scenario == .message_decline) {
                    // The approval is still settling, but no external decision is actionable.
                    const observed = try store_testing.observeCommandForTesting(&storage, "intent-first");
                    try std.testing.expectEqual(protocol.MessageRequestState.waiting_for_permission, observed.requestState().?);
                    try std.testing.expectEqual(@as(?u64, null), observed.kind.message.?.work.?.first_action);
                }
                if (scenario == .message_decline or scenario == .mixed) {
                    const bytes = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
                    defer std.testing.allocator.free(bytes);
                    var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                    defer report.deinit();
                    const permissions = report.value.object.get("actionable_permissions").?.array.items;
                    try std.testing.expectEqual(@as(usize, if (scenario == .mixed) 2 else 0), permissions.len);
                    for (permissions) |permission| try std.testing.expect((try std.fmt.parseInt(u64, permission.object.get("action").?.string, 10)) != old_action);
                    const observed = try store_testing.observeCommandForTesting(&storage, "intent-next");
                    try std.testing.expectEqual(protocol.MessageRequestState.waiting_for_permission, observed.requestState().?);
                    try std.testing.expectEqualDeep(work, observed.kind.message.?.work.?);
                    if (scenario == .message_decline) {
                        const original = try store_testing.observeCommandForTesting(&storage, "intent-first");
                        try std.testing.expectEqual(protocol.MessageRequestState.waiting_for_permission, original.requestState().?);
                        try std.testing.expectEqualDeep(work, original.kind.message.?.work.?);
                    }
                }
                switch (intent) {
                    .stop => if (work.actions.stop) {
                        var stop = try completeSessionStop("intent-stop", session.slice());
                        try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                    },
                    .interrupt => if (work.actions.interrupt) |target| {
                        var interrupt: protocol.ModelInterruptionCommand = .{ .session = session, .turn_id = target.turn, .operation_id = target.operation };
                        try interrupt.key.set("intent-interrupt");
                        try std.testing.expect(storage.interruptModel(&interrupt, .{}) == .accepted);
                    },
                    .decide => if (work.actions.decide) |action| {
                        var decision: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = action, .decision = .allow_once };
                        try decision.key.set("intent-decide");
                        try std.testing.expect(storage.decidePermission(&decision, .{}) == .accepted);
                    },
                }
            };
        }
    }.run);
}

test "compound report preparation can cancel and restarts stale pressure before visitor output" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "report-pressure-config");
            try submitTestMessage(&storage, &tmp, "report-pressure-first", "report-pressure-first", session.slice(), "first");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const parts: [65]store_testing.MessagePart = @splat(.{ .bytes = "report pressure text" });
            try store_testing.submitTestMessageParts(&storage, &tmp, "report-pressure-parts", session.slice(), &parts);
            try settleCallsForTestingWithFaults(&storage, &tmp, first, "report-pressure-answer", &.{}, .{}, "{\"input_tokens\":990,\"output_tokens\":0}");

            var root: [protocol.max_store_bytes]u8 = undefined;
            const root_length = try tmp.dir.realPath(std.testing.io, &root);
            var used = std.atomic.Value(u64).init(0);
            var capture: report_domain.SessionReportCapture = .{ .io = std.testing.io, .writer = null, .budget = .{ .used = &used, .limit = 1024 * 1024 } };
            try capture.create(root[0..root_length], 73, false);
            defer capture.deinit();
            var reply: TestingReportReply = .{ .capture = &capture, .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 } };
            var pressure: session_report_read_domain.Pressure = .{};
            var token: ?@import("../../change_ring.zig").SessionToken = null;
            try std.testing.expect(!try storage.readSessionReportStep(session.slice(), .current, &reply, &pressure, &token));
            try std.testing.expectEqual(@as(u64, 0), capture.length);
            try std.testing.expectEqual(@as(usize, 0), capture.buffered);
            const Read = @import("../domain/model_admission.zig").PartsPressure.Read;
            const mapped = try @import("../../os/pages.zig").Mapped(Read).map();
            defer mapped.unmap();
            const read = mapped.value;
            const coverage = pressure.needed.?;
            read.init(coverage.session, coverage.covered, coverage.frontier, coverage.results, std.math.maxInt(i64));
            read.boundary = pressure.needed_boundary;
            defer read.deinit();
            var steps: usize = 0;
            while (read.cursor == null) : (steps += 1) {
                try std.testing.expect(steps < 16);
                try std.testing.expect(!try storage.advancePartsPressure(read));
            }
            read.deinit();
            try std.testing.expect(read.cursor == null);
            try std.testing.expect(!storage.isFenced());
            read.init(coverage.session, coverage.covered, coverage.frontier, coverage.results, std.math.maxInt(i64));
            read.boundary = pressure.needed_boundary;
            while (!try storage.advancePartsPressure(read)) {}
            pressure.read = read;
            try submitTestMessage(&storage, &tmp, "report-pressure-later", "report-pressure-later", session.slice(), "later");
            try std.testing.expect(!try storage.readSessionReportStep(session.slice(), .current, &reply, &pressure, &token));
            try std.testing.expect(pressure.read == null);
            try std.testing.expectEqual(@as(u64, 0), capture.length);
            try std.testing.expectEqual(@as(usize, 0), capture.buffered);
            const fresh = pressure.needed.?;
            read.deinit();
            read.init(fresh.session, fresh.covered, fresh.frontier, fresh.results, std.math.maxInt(i64));
            read.boundary = pressure.needed_boundary;
            while (!try storage.advancePartsPressure(read)) {}
            pressure.read = read;
            try std.testing.expect(try storage.readSessionReportStep(session.slice(), .current, &reply, &pressure, &token));
            var report = try capture.seal();
            defer report.deinit();
            const body = try std.testing.allocator.alloc(u8, @intCast(report.length));
            defer std.testing.allocator.free(body);
            try std.testing.expectEqual(body.len, try report.read(0, body));
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
            defer parsed.deinit();
            const fresh_body = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
            defer std.testing.allocator.free(fresh_body);
            try std.testing.expectEqualStrings(fresh_body, body);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "Current reports preserve equal distinct and empty loaded tool names" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Variant = struct { tools: []const []const u8, loaded: ?[]const []const u8 };
            const variants = [_]Variant{
                .{ .tools = &.{ "bash", "find_tools" }, .loaded = null },
                .{ .tools = &.{ "bash", "find_tools" }, .loaded = &.{ "bash", "find_tools" } },
                .{ .tools = &.{ "bash", "find_tools" }, .loaded = &.{"find_tools"} },
                .{ .tools = &.{}, .loaded = &.{} },
            };
            for (variants) |variant| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace: [protocol.max_workspace_bytes]u8 = undefined;
                var command = try store_testing.completeConfiguration("report-names-config", "", try store_testing.canonicalCwd(std.testing.io, &workspace), "model-a");
                command.configuration.tools = try .of(variant.tools);
                if (variant.loaded) |loaded| command.configuration.loaded_tools = try .of(loaded);
                const configured = try storage.configure(&command, .{});
                try std.testing.expect(configured == .accepted);
                const body = try testingSessionReport(&storage, &tmp, configured.accepted.session.slice(), 1024 * 1024);
                defer std.testing.allocator.free(body);
                var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
                defer parsed.deinit();
                const session = parsed.value.object.get("session").?.object;
                const tools = session.get("tools").?.array.items;
                const loaded = session.get("loaded_tools").?.array.items;
                const expected = variant.loaded orelse variant.tools;
                try std.testing.expectEqual(variant.tools.len, tools.len);
                try std.testing.expectEqual(expected.len, loaded.len);
                for (tools, variant.tools) |actual, name| try std.testing.expectEqualStrings(name, actual.string);
                for (loaded, expected) |actual, name| try std.testing.expectEqualStrings(name, actual.string);
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}
