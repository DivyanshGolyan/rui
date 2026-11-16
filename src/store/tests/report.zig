//! Report Store conformance tests.

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
            // The delta value is also named "full"; history is the object key.
            try std.testing.expect(parsed_current.value.object.get("full") == null);
            try std.testing.expectEqualStrings("full", parsed_current.value.object.get("delta").?.string);
            try std.testing.expect(parsed_current.value.object.get("since").? == .null);

            const text = try std.testing.allocator.alloc(u8, 64 * 1024);
            defer std.testing.allocator.free(text);
            @memset(text, 1);
            try submitTestMessage(&storage, &tmp, "profile-message", "profile-message", session.slice(), text);
            _ = (try storage.admitNextModelAttempt(.{})).?;
            // One worst-case escaped copy fits; duplicating it in Conversation would not.
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
            try settleTwoActionsForTesting(&storage, &tmp, binding, "mixed-metadata");
            const before = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
            defer std.testing.allocator.free(before);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, before, .{});
            defer parsed.deinit();
            const first = parsed.value.object.get("actions").?.object.get("unresolved").?.array.items[0];
            const action_id = try std.fmt.parseInt(u64, first.object.get("action").?.string, 10);
            try std.testing.expectEqualStrings("approval", parsed.value.object.get("work").?.object.get("state").?.object.get("kind").?.string);
            try pageWorkAgrees(&storage, parsed.value, action_id);
            // While a Turn is active, the round that reads the command reads
            // the work too: the Message's own, or the one it waits behind.
            var rounds = storage.testing_content_work.rounds;
            try std.testing.expectEqual(protocol.MessageProgressStatus.waiting_for_permission, (try store_testing.observeCommandForTesting(&storage, "mixed-message")).kind.message.?.work.?.state.progress().?);
            try std.testing.expectEqual(rounds + 1, storage.testing_content_work.rounds);
            try submitTestMessage(&storage, &tmp, "mixed-queued-file", "mixed-queued", session.slice(), "wait behind approval");
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

            // Approved Bash awaiting a slot can progress: the work is pending and
            // the Message runnable, though a sibling still awaits permission.
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

            // Once it runs, the Session is in Bash with one approval outstanding.
            _ = (try storage.admitNextActionAttempt(300_000, .{})).?;
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

/// The activity page carries the work Current reports and the first
/// actionable Action, from its own read.
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

            // A configure-only Session is idle since its creation.
            const session = try configureTestSession(&storage, "one-work-config");
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT created_at FROM session", .{}), try expectOneWork(&storage, &tmp, session.slice(), "idle"));

            // Queued, then admitted.
            try submitTestMessage(&storage, &tmp, "one-work-file", "one-work-message", session.slice(), "first");
            _ = try expectOneWork(&storage, &tmp, session.slice(), "pending");
            try expectProgress(&storage, "one-work-message", .runnable);
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT attempt_at FROM model_operation", .{}), try expectOneWork(&storage, &tmp, session.slice(), "working"));
            try expectProgress(&storage, "one-work-message", .in_flight);

            // A retry due later is in flight; once due it is runnable, though
            // nothing committed in between.
            try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "provider_temporary_http_429" }, .{ .retryable = .{ .waits_ms = .{ 60_000, 60_000, 60_000 } } }, .{});
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT retry_scheduled_at FROM model_operation", .{}), try expectOneWork(&storage, &tmp, session.slice(), "retrying"));
            try expectProgress(&storage, "one-work-message", .in_flight);
            try store_testing.exec(&storage, "UPDATE model_operation SET retry_due_at_ms=1 WHERE resolution_code IS NULL", .{});
            _ = try expectOneWork(&storage, &tmp, session.slice(), "pending");
            try expectProgress(&storage, "one-work-message", .runnable);

            // A quota failure carries its saved reset time.
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

            // A completed Turn is finished.
            const done = try configureTestSession(&storage, "one-work-done");
            const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
            try answerTestTurn(&storage, &tmp, done.slice(), "one-work-answer", &answer);
            _ = try expectOneWork(&storage, &tmp, done.slice(), "finished");

            // A stop selecting a Turn whose Bash runs is stopping until the Attempt
            // settles; the Turn then ends stopped by the stop.
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
            const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
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
            const action_binding = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
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

/// The rounds a Current report takes for a Session of `shape`.
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
            // Every shape: the saved Session; the facts' first round, with the
            // work's and compaction facts' latest Turn; the pending count with
            // their second stages; then the recent Messages. Idle and finished
            // work reads the queue after the cutoff in a fourth round; stopped
            // work then the excluded Message and its stop.
            try std.testing.expectEqual(@as(u32, 6), try reportRoundsForTesting(case, .idle));
            try std.testing.expectEqual(@as(u32, 6), try reportRoundsForTesting(case, .finished));
            try std.testing.expectEqual(@as(u32, 8), try reportRoundsForTesting(case, .stopped));
            // Awaiting work ends with its Actions in the third round; its Action
            // adds the unresolved, resolved and actionable lists, and with no
            // rejected call there is no rejected list.
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
