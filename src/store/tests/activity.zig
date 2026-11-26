const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const conversation_read = @import("../../conversation_read.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const content_domain = @import("../domain/content.zig");
const old_format = @import("../history.zig");
const historical_domain = @import("../domain/historical.zig");
const skills_domain = @import("../domain/skills.zig");
const reads_domain = @import("../domain/reads.zig");
const store_testing = @import("../testing.zig");
const HistoricalEntryKind = historical_domain.HistoricalEntryKind;
const TestingReader = store_testing.TestingReader;
const TestingPage = store_testing.TestingPage;
const TestingAnswerPart = store_testing.TestingAnswerPart;
const answerTestTurn = store_testing.answerTestTurn;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = shared_fixtures.TestingCall;
const TwinRounds = shared_fixtures.TwinRounds;
const completeSessionStop = shared_fixtures.completeSessionStop;
const testingBytesContent = shared_fixtures.testingBytesContent;
const configureTestSessionAsk = shared_fixtures.configureTestSessionAsk;
const configureTestSessionWithMode = shared_fixtures.configureTestSessionWithMode;
const expectActivityArguments = shared_fixtures.expectActivityArguments;
const expectActivityOutcome = shared_fixtures.expectActivityOutcome;
const expectOneWork = shared_fixtures.expectOneWork;
const membershipToolSet = shared_fixtures.membershipToolSet;
const membership_records = shared_fixtures.membership_records;
const nextTestingItem = shared_fixtures.nextTestingItem;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const settleTwoActionsForTesting = shared_fixtures.settleTwoActionsForTesting;
const testingSessionReport = shared_fixtures.testingSessionReport;
const testingSessionReportWithProfile = shared_fixtures.testingSessionReportWithProfile;

test "activity fixed admission prefix survives later application and stop" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "activity-config");
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const empty = try store_core.activityPageForTesting(&storage, request);
            try submitTestMessage(&storage, &tmp, "activity-a", "a", session.slice(), "same");
            try submitTestMessage(&storage, &tmp, "activity-b", "b", session.slice(), "same");
            const queued = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 2), queued.count);
            try std.testing.expect(queued.items[0].value.admission.admission != queued.items[1].value.admission.admission);
            try std.testing.expect(queued.items[0].value.admission.turn == null);
            var admitted = (try storage.admitNextModelAttempt(.{})).?;
            _ = try admitted.permit.consume();
            var stop = try completeSessionStop("activity-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try expectActivityOutcome(&storage, session.slice(), admitted.permit.binding, .stopped, "cancelled");
            request.end = queued.end;
            const frozen = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 2), frozen.count);
            try std.testing.expect(frozen.items[0].value.admission.state == .queued and frozen.items[0].value.admission.turn == null);
            request.end = empty.end;
            try std.testing.expectEqual(@as(usize, 0), (try store_core.activityPageForTesting(&storage, request)).count);
        }
    }.run);
}

test "a page's rows share their rounds, so a full page takes as many as one row" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "rounds-config");
            try submitTestMessage(&storage, &tmp, "rounds-input", "message", session.slice(), "run tools");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var calls: [17]TestingCall = undefined;
            var names: [17][16]u8 = undefined;
            for (&calls, &names, 0..) |*call, *name, index| {
                const id = try std.fmt.bufPrint(name, "rounds-{d}", .{index});
                call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "{}", .decoded_arguments = "{}" };
            }
            try settleCallsForTesting(&storage, &tmp, binding, "rounds-output", &calls);
            var conversation: conversation_read.ConversationPage = .{};
            try conversation.session.set(session.slice());
            var activity: protocol.ActivityPage = .{};
            try activity.session.set(session.slice());
            const full = try pageRounds(&storage, &conversation, &activity);
            try std.testing.expectEqual(@as(usize, 16), full.conversation);
            try std.testing.expectEqual(@as(usize, 16), full.activity);
            conversation = .{ .session = conversation.session, .end = full.end, .before_position = full.results, .before_ordinal = 2 };
            activity.end = try store_testing.queryU64(&storage, "SELECT min(session_position) FROM model_output_item WHERE item_kind=3", .{});
            const small = try pageRounds(&storage, &conversation, &activity);
            try std.testing.expectEqual(@as(usize, 2), small.conversation);
            try std.testing.expect(small.activity < 16);
            try std.testing.expectEqual(small.rounds, full.rounds);
        }
    }.run);
}

const PageRounds = struct { rounds: [2]u32, conversation: usize, activity: usize, results: u64, end: u64 };

fn pageRounds(storage: *Store, conversation: *const conversation_read.ConversationPage, activity: *const protocol.ActivityPage) !PageRounds {
    var result: PageRounds = undefined;
    var public_page: reads_domain.PublicConversationPage = undefined;
    var activity_page: protocol.ActivityFacts = undefined;
    {
        const entry = try store_core.enter(storage, .none);
        defer entry.release();
        var a: reads_domain.ReadAccess = .open(&entry);
        defer a.deinit();
        const before = storage.testing_content_work.rounds;
        const row_reads = try std.testing.allocator.create([reads_domain.PublicConversationPage.capacity]reads_domain.PublicRowRead);
        defer std.testing.allocator.destroy(row_reads);
        try reads_domain.publicConversationPage(&a, conversation, &public_page, row_reads);
        result.rounds[0] = storage.testing_content_work.rounds - before;
    }
    {
        const entry = try store_core.enter(storage, .none);
        defer entry.release();
        var a: reads_domain.ReadAccess = .open(&entry);
        defer a.deinit();
        const before = storage.testing_content_work.rounds;
        try reads_domain.activityPage(&a, activity, &activity_page);
        result.rounds[1] = storage.testing_content_work.rounds - before;
    }
    result.conversation = public_page.count;
    result.activity = activity_page.count;
    result.results = public_page.items[0].position;
    result.end = public_page.end;
    return result;
}

test "an activity page reports the queued Messages at its end, until applied or stopped" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "queued-config");
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            try std.testing.expectEqual(@as(protocol.Queued, .{}), (try store_core.activityPageForTesting(&storage, request)).aggregates.?.queued);
            try submitTestMessage(&storage, &tmp, "queued-a", "a", session.slice(), "first");
            try submitTestMessage(&storage, &tmp, "queued-b", "b", session.slice(), "second");
            const waiting = try store_core.activityPageForTesting(&storage, request);
            const first = waiting.items[0];
            const second = waiting.items[1];
            try std.testing.expectEqual(@as(protocol.Queued, .{ .count = 2, .oldest_position = first.position, .newest_admission = second.value.admission.admission, .newest_position = second.position, .newest_content = second.value.admission.content }), waiting.aggregates.?.queued);
            var admitted = (try storage.admitNextModelAttempt(.{})).?;
            _ = try admitted.permit.consume();
            try std.testing.expectEqual(@as(u64, 0), (try store_core.activityPageForTesting(&storage, request)).aggregates.?.queued.count);
            var frozen = request;
            frozen.end = waiting.end;
            try std.testing.expectEqual(waiting.aggregates.?.queued, (try store_core.activityPageForTesting(&storage, frozen)).aggregates.?.queued);
            try submitTestMessage(&storage, &tmp, "queued-c", "c", session.slice(), "third");
            const behind = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(u64, 1), behind.aggregates.?.queued.count);
            try std.testing.expectEqual(behind.end, behind.aggregates.?.queued.oldest_position);
            try std.testing.expectEqual(behind.end, behind.aggregates.?.queued.newest_position);
            var stop = try completeSessionStop("queued-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 0), (try store_core.activityPageForTesting(&storage, request)).aggregates.?.queued.count);
            frozen.end = behind.end;
            try std.testing.expectEqual(behind.aggregates.?.queued, (try store_core.activityPageForTesting(&storage, frozen)).aggregates.?.queued);
        }
    }.run);
}

test "activity queue follows compaction and taken messages" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "queue-compact-config");
            var patch: @import("../../wire_request.zig").ConfigureCommand = .{};
            try patch.key.set("queue-compact-settings");
            patch.session = session;
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("1");
            patch.configuration.output_reservation.state = .value;
            try patch.configuration.output_reservation.value.set("1");
            try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "queue-compact-first", "first", session.slice(), "first");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "provider_failure" }, .ordinary, .{});
            try submitTestMessage(&storage, &tmp, "queue-compact-second", "second", session.slice(), "second");
            const compact = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(historical_domain.ModelOperationKind.compaction, try storage.modelOperationKind(compact));
            var request: protocol.ActivityPage = .{};
            request.session = session;
            const compacting = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(u64, 1), compacting.aggregates.?.queued.count);
            try std.testing.expect(compacting.work.work.state == .working and compacting.work.work.state.working.compaction);
            try submitTestMessage(&storage, &tmp, "queue-compact-third", "third", session.slice(), "third");
            const behind = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(u64, 2), behind.aggregates.?.queued.count);
            try store_testing.settleCompactionForTesting(&storage, &tmp, compact, &.{.compaction});
            const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(historical_domain.ModelOperationKind.assistant_response, try storage.modelOperationKind(successor));
            const answering = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(u64, 0), answering.aggregates.?.queued.count);
            try std.testing.expect(answering.work.work.state == .working and !answering.work.work.state.working.compaction);
            try submitTestMessage(&storage, &tmp, "queue-compact-fourth", "fourth", session.slice(), "fourth");
            try std.testing.expectEqual(@as(u64, 1), (try store_core.activityPageForTesting(&storage, request)).aggregates.?.queued.count);
        }
    }.run);
}

test "every activity row is dated by the fact that owns it" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "dated-config");
            const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
            try answerTestTurn(&storage, &tmp, session.slice(), "dated-answer", &answer);
            try submitTestMessage(&storage, &tmp, "dated-input", "dated-input", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "dated-calls");
            var stop = try completeSessionStop("dated-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=101;" ++
                "UPDATE conversation_entry SET recorded_at=CASE entry_kind WHEN 1 THEN 102 WHEN 3 THEN 103 ELSE 109 END;" ++
                "UPDATE model_operation SET resolved_at=104;" ++
                "UPDATE action_operation SET resolved_at=CASE call_ordinal WHEN 0 THEN 105 ELSE 106 END;" ++
                "UPDATE turn SET outcome_at=107;" ++
                "UPDATE session_stop SET stopped_at=108", .{});
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const page = try store_core.activityPageForTesting(&storage, request);
            var seen: std.EnumSet(std.meta.Tag(protocol.ActivityItem.Value)) = .empty;
            for (page.items[0..page.count]) |item| {
                const expected: u64 = switch (item.value) {
                    .admission => 101,
                    .user => 102,
                    .assistant => 103,
                    .call, .model_call => 104,
                    .tool_result => 106,
                    .turn_ended => 107,
                    .stop => 108,
                    .approval_requested => 104,
                    .hosted_call, .received, .session_changed, .compacted, .instruction, .skill => unreachable,
                };
                try std.testing.expectEqual(expected, item.at);
                seen.insert(item.value);
            }
            try std.testing.expectEqual(@as(usize, 9), seen.count());
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "a call made while the Session asks follows with its approval request, and one under bypass has none" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_][]const u8{ "ask", "bypass" }) |mode| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionWithMode(&storage, "approval-config", mode);
                try submitTestMessage(&storage, &tmp, "approval-input", "approval-input", session.slice(), "propose");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleTwoActionsForTesting(&storage, &tmp, binding, "approval-calls");
                var request: protocol.ActivityPage = .{};
                try request.session.set(session.slice());
                const page = try store_core.activityPageForTesting(&storage, request);
                var calls: usize = 0;
                var approvals: usize = 0;
                for (page.items[0..page.count], 0..) |item, index| switch (item.value) {
                    .call => calls += 1,
                    .approval_requested => |approval| {
                        approvals += 1;
                        const call = page.items[index - 1];
                        try std.testing.expectEqual(call.position, item.position);
                        try std.testing.expectEqual(@as(u64, 1), item.ordinal);
                        try std.testing.expectEqual(call.value.call.action.?, approval.action);
                        try std.testing.expectEqual(call.value.call.operation, approval.operation);
                        try std.testing.expectEqual(call.value.call.call_ordinal, approval.call_ordinal);
                    },
                    else => {},
                };
                try std.testing.expectEqual(@as(usize, 2), calls);
                try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, mode, "ask")) 2 else 0), approvals);
                request.kinds = .initOne(.approval_requested);
                const only = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(approvals, only.count);
                request.kinds = .full;
                request.direction = .backward;
                const backward = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(page.count, backward.count);
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

test "a Tool Result is dated by its group's last acceptance, even when the clock stepped back" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "stepped-config");
            try submitTestMessage(&storage, &tmp, "stepped-input", "stepped-input", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "stepped-calls");
            var stop = try completeSessionStop("stepped-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(DISTINCT acceptance_position) FROM action_operation", .{}));
            const latest_acceptance = try store_testing.queryU64(&storage, "SELECT max(acceptance_position) FROM action_operation", .{});
            try store_testing.exec(&storage, "UPDATE action_operation SET resolved_at=" ++
                "CASE WHEN acceptance_position=?1 THEN 100 ELSE 200 END", .{latest_acceptance});
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const page = try store_core.activityPageForTesting(&storage, request);
            var results: usize = 0;
            for (page.items[0..page.count]) |item| if (item.value == .tool_result) {
                try std.testing.expectEqual(@as(u64, 100), item.at);
                results += 1;
            };
            try std.testing.expectEqual(@as(usize, 2), results);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "queued input is pending from the newer of its admission and the latest outcome, even when the clock stepped back" {
    try store_testing.forEachEngine(struct {
        fn run(store_case: *store_testing.Case) !void {
            for ([_]enum { behind_the_turn, after_the_outcome }{ .behind_the_turn, .after_the_outcome }) |case| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(store_case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "stepped-queue-config");
                switch (case) {
                    .behind_the_turn => {
                        try submitTestMessage(&storage, &tmp, "stepped-queue-first", "stepped-queue-first", session.slice(), "first");
                        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        try submitTestMessage(&storage, &tmp, "stepped-queue-input", "stepped-queue-input", session.slice(), "queued");
                        var diagnostic: [512]u8 = undefined;
                        const quota: @import("../../transport_policy.zig").Quota = .{ .refusal = .quota, .resets_at = 1792940000 };
                        try storage.settleModelAttemptFailure(binding, .{ .rejected = .{ .code = quota.failureCode(), .diagnostic = quota.format(&diagnostic), .request_id = .{}, .report = "" } }, .ordinary, .{});
                        try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=200 WHERE command_key='stepped-queue-input';UPDATE turn SET outcome_at=100", .{});
                    },
                    .after_the_outcome => {
                        const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
                        try answerTestTurn(&storage, &tmp, session.slice(), "stepped-queue-answer", &answer);
                        try submitTestMessage(&storage, &tmp, "stepped-queue-input", "stepped-queue-input", session.slice(), "queued");
                        try store_testing.exec(&storage, "UPDATE turn SET outcome_at=200;UPDATE message_admission SET admitted_at=100 WHERE command_key='stepped-queue-input'", .{});
                    },
                }
                try std.testing.expectEqual(@as(u64, 100), try expectOneWork(&storage, &tmp, session.slice(), "pending"));
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

test "tool label observation trusts admission over damaged call field bytes" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "label-config");
                try submitTestMessage(&storage, &tmp, "label-input", "label-input", session.slice(), "propose");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleTwoActionsForTesting(&storage, &tmp, binding, "label-calls");
                var request: protocol.ActivityPage = .{};
                try request.session.set(session.slice());
                const before = try store_core.activityPageForTesting(&storage, request);
                try store_testing.zeroContent(&storage, "SELECT arguments_content_id FROM model_tool_call");
                const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
                defer std.testing.allocator.free(report);
                try std.testing.expect(std.mem.indexOf(u8, report, "Run first command") != null);
                const after = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(before.aggregates.?.call_activity.total, after.aggregates.?.call_activity.total);
                for (before.aggregates.?.call_activity.entries[0..before.aggregates.?.call_activity.count], after.aggregates.?.call_activity.entries[0..after.aggregates.?.call_activity.count]) |original, observed| {
                    try std.testing.expectEqualStrings(original.presentation.line.?.words.slice(), observed.presentation.line.?.words.slice());
                    try std.testing.expectEqual(original.presentation.code, observed.presentation.code);
                }
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

test "completed tool labels trust admission while model replay authenticates payload" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "replay-config");
            try submitTestMessage(&storage, &tmp, "replay-input", "replay-input", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "replay-calls");
            var stop = try completeSessionStop("replay-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            var request: conversation_read.ConversationPage = .{};
            try request.session.set(session.slice());
            const before = try store_core.publicConversationPageForTesting(&storage, request);
            try store_testing.zeroContent(&storage, "SELECT name_content_id FROM model_tool_call");
            const after = try store_core.publicConversationPageForTesting(&storage, request);
            try std.testing.expectEqual(before.count, after.count);
            var results: usize = 0;
            for (before.items[0..before.count], after.items[0..after.count]) |original, observed| {
                if (original.presentation) |presentation| {
                    results += 1;
                    try std.testing.expectEqualStrings(presentation.line.?.words.slice(), observed.presentation.?.line.?.words.slice());
                    try std.testing.expectEqual(presentation.code, observed.presentation.?.code);
                }
            }
            try std.testing.expectEqual(@as(usize, 2), results);
            try submitTestMessage(&storage, &tmp, "replay-next", "replay-next", session.slice(), "continue");
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var view: TestingPage = undefined;
            view.open(&storage, next);
            defer view.close();
            const first = (try nextTestingItem(&view, 0)).?;
            try std.testing.expectEqual(HistoricalEntryKind.user, first.kind);
            const call = (try nextTestingItem(&view, first.position)).?;
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT min(session_position) FROM model_output_item WHERE item_kind=3", .{}), call.position);
            const name = (try view.openOutput(call.position)).call.?[0];
            var reader: TestingReader = undefined;
            try view.openContent(name, &reader);
            defer reader.close();
            var buffer: [4096]u8 = undefined;
            try std.testing.expectError(error.CorruptStore, reader.read(0, buffer[0..@intCast(name.length)]));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "live tool activity survives completed Turns and split result pages" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "live-config");
            try submitTestMessage(&storage, &tmp, "live-input", "input", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var identities: [20][24]u8 = undefined;
            var calls: [20]TestingCall = undefined;
            for (&calls, &identities, 0..) |*call, *identity, index| {
                const id = try std.fmt.bufPrint(identity, "live-{d}", .{index});
                call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "", .decoded_arguments = "" };
            }
            try settleCallsForTesting(&storage, &tmp, binding, "live-calls", &calls);
            var stop = try completeSessionStop("live-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const page = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expect(page.more);
            try std.testing.expectEqual(page.items[page.count - 1].position, page.aggregates.?.as_of);
            for (page.items[0..page.count]) |item| try std.testing.expect(item.value != .tool_result);
            try std.testing.expectEqual(@as(u64, 20), page.aggregates.?.call_activity.total);
            try std.testing.expectEqual(@as(usize, 3), page.aggregates.?.call_activity.count);
            for (page.aggregates.?.call_activity.entries, 0..) |entry, index| {
                try std.testing.expectEqual(binding.operation_id, entry.operation);
                try std.testing.expectEqual(index, entry.ordinal);
                try std.testing.expect(entry.presentation.code == .unknown_tool);
            }
            const last = page.items[page.count - 1];
            request.end = page.end;
            request.position = last.position;
            request.ordinal = last.ordinal;
            const split = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expect(split.more);
            try std.testing.expectEqual(split.items[split.count - 1].position, split.aggregates.?.as_of);
            try std.testing.expectEqual(@as(u64, 11), split.aggregates.?.call_activity.total);
            try std.testing.expectEqual(@as(u64, 9), split.aggregates.?.call_activity.entries[0].ordinal);
            const split_last = split.items[split.count - 1];
            request.position = split_last.position;
            request.ordinal = split_last.ordinal;
            const finished = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expect(!finished.more);
            try std.testing.expectEqual(finished.end, finished.aggregates.?.as_of);
            try std.testing.expectEqual(@as(u64, 0), finished.aggregates.?.call_activity.total);
            request.position = 0;
            request.ordinal = null;
            request.direction = .backward;
            const opening = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(opening.end, opening.aggregates.?.as_of);
            try std.testing.expectEqual(@as(u64, 0), opening.aggregates.?.call_activity.total);

            try submitTestMessage(&storage, &tmp, "live-new", "new", session.slice(), "propose again");
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, next, "live-new-calls");
            request.direction = .forward;
            request.position = finished.end;
            const frozen = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 0), frozen.count);
            try std.testing.expectEqual(@as(u64, 2), frozen.aggregates.?.call_activity.total);
            try std.testing.expectEqual(next.operation_id, frozen.aggregates.?.call_activity.entries[0].operation);
            // INS-7: a page of some kinds does not read the aggregates, so it reports them as not read, never as none waiting.
            for ([_]protocol.ActivityPage.Kinds{ .initOne(.admission), .initMany(&.{ .admission, .user }) }) |kinds| for ([_]@TypeOf(request.direction){ .forward, .backward }) |direction| {
                var narrowed: protocol.ActivityPage = .{ .kinds = kinds, .direction = direction, .limit = 1 };
                try narrowed.session.set(session.slice());
                try std.testing.expect((try store_core.activityPageForTesting(&storage, narrowed)).aggregates == null);
            };
        }
    }.run);
}

test "live tool activity counts calls past the sixteenth Operation" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "ops-config");
            try submitTestMessage(&storage, &tmp, "ops-input", "input", session.slice(), "propose");
            var first: u64 = 0;
            for (0..32) |index| {
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                if (index == 0) first = binding.operation_id;
                var identity: [24]u8 = undefined;
                const id = try std.fmt.bufPrint(&identity, "ops-{d}", .{index});
                var prefix: [24]u8 = undefined;
                const calls = [_]TestingCall{.{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "", .decoded_arguments = "" }};
                try settleCallsForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&prefix, "ops-calls-{d}", .{index}), &calls);
            }
            var stop = try completeSessionStop("ops-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const page = try store_core.activityPageForTesting(&storage, request);
            const after = try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE acceptance_position>?1", .{page.items[page.count - 1].position});
            try std.testing.expect(after > 16);
            try std.testing.expectEqual(after, page.aggregates.?.call_activity.total);
            try std.testing.expectEqual(@as(usize, 3), page.aggregates.?.call_activity.count);
            try std.testing.expect(page.aggregates.?.call_activity.entries[0].operation > first);
        }
    }.run);
}

test "the Current report's resolved and rejected calls carry their group's publication" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "publication-config");
            try submitTestMessage(&storage, &tmp, "publication-input", "input", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{
                .{
                    .item_id = "publication-item-0",
                    .name = "bash",
                    .encoded_call_id = "publication-call-0",
                    .decoded_call_id = "publication-call-0",
                    .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                    .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
                },
                .{ .item_id = "publication-item-1", .name = "other", .encoded_call_id = "publication-call-1", .decoded_call_id = "publication-call-1", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            };
            try settleCallsForTesting(&storage, &tmp, binding, "publication-calls", &calls);
            var allow: protocol.PermissionDecisionCommand = .{ .action_id = try store_testing.queryU64(&storage, "SELECT action_id FROM action_operation", .{}), .decision = .allow_once };
            try allow.key.set("publication-allow");
            try allow.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            const action = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?.permit.binding;
            _ = try storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{});
            const group = try store_testing.queryU64(&storage, "SELECT max(acceptance_position) FROM action_operation", .{});
            try std.testing.expect(group > try store_testing.queryU64(&storage, "SELECT acceptance_position FROM model_tool_call WHERE rejection_code IS NOT NULL", .{}));

            const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
            defer std.testing.allocator.free(bytes);
            var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
            defer report.deinit();
            const resolved = report.value.object.get("actions").?.object.get("resolved").?.array.items;
            const rejected = report.value.object.get("rejected_calls").?.object.get("items").?.array.items;
            try std.testing.expectEqual(@as(usize, 1), resolved.len);
            try std.testing.expectEqual(@as(usize, 1), rejected.len);
            var expected: [20]u8 = undefined;
            const position = try std.fmt.bufPrint(&expected, "{d}", .{group});
            for ([_]std.json.Value{ resolved[0], rejected[0] }) |row| {
                const published = row.object.get("presentation").?.object.get("publication_position").?;
                try std.testing.expectEqualStrings(position, switch (published) {
                    .string => |text| text,
                    else => return error.TestUnexpectedResult,
                });
            }
        }
    }.run);
}

test "a web search call shows as its line, in the conversation and the activity, at its own position" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "search-config");
            try submitTestMessage(&storage, &tmp, "search-input", "search-key", session.slice(), "what changed?");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleItemsForTesting(&storage, &tmp, binding, &.{
                "{\"type\":\"web_search_call\",\"id\":\"ws1\",\"status\":\"completed\",\"action\":{\"type\":\"search\",\"query\":\"zig\\n0.17 \\\"notes\\\"\",\"queries\":[\"zig\\n0.17 \\\"notes\\\"\",\"second \\u00e9\"]}}",
                "{\"type\":\"web_search_call\",\"id\":\"ws2\",\"status\":\"failed\",\"action\":{\"type\":\"open_page\",\"url\":\"https://www.ziglang.org/x\"}}",
                "{\"type\":\"web_search_call\",\"id\":\"ws3\",\"action\":{\"type\":\"find_in_page\",\"url\":\"ziglang.org\",\"pattern\":\"Io\"}}",
                "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}",
            }, "done");
            const expected = [_]struct { []const u8, protocol.ToolPresentation.Code }{
                .{ "Find “Io” in ziglang.org", .succeeded },
                .{ "Open ziglang.org/x", .failed },
                .{ "Search “zig 0.17 \"notes\"”", .succeeded },
            };
            var request: conversation_read.ConversationPage = .{};
            try request.session.set(session.slice());
            const page = try store_core.publicConversationPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 5), page.count);
            try std.testing.expect(page.items[0].kind == .assistant);
            for (page.items[1..4], expected, 0..) |item, want, index| {
                try std.testing.expect(item.kind == .hosted_call);
                try std.testing.expectEqual(@as(u64, 0), item.ordinal);
                try std.testing.expectEqual(page.items[0].position - 1 - index, item.position);
                try std.testing.expectEqualStrings(want[0], item.presentation.?.line.?.words.slice());
                try std.testing.expectEqual(want[1], item.presentation.?.code);
                try std.testing.expectEqual(item.position, item.presentation.?.publication_position.?);
            }
            try std.testing.expect(page.items[4].kind == .user);
            request.end = page.end;
            request.before_position = page.items[2].position;
            const older = try store_core.publicConversationPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 2), older.count);
            try std.testing.expectEqualStrings(expected[2][0], older.items[0].presentation.?.line.?.words.slice());
            try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&.{ .session = request.session, .position = page.items[1].position, .ordinal = 0 }));

            // The facts each search saved, newest first: its action, every target in provider order, how many, and the pattern.
            const Facts = struct { kind: @import("../../hosted_action.zig").HostedAction, targets: []const []const u8, pattern: ?[]const u8 = null };
            const facts = [_]Facts{
                .{ .kind = .find_in_page, .targets = &.{"ziglang.org"}, .pattern = "Io" },
                .{ .kind = .open_page, .targets = &.{"https://www.ziglang.org/x"} },
                .{ .kind = .search, .targets = &.{ "zig\n0.17 \"notes\"", "second é" } },
            };
            const activity = try store_core.activityPageForTesting(&storage, .{ .session = request.session, .direction = .backward });
            var calls: usize = 0;
            for (activity.items[0..activity.count]) |item| if (item.value == .hosted_call) {
                const want = expected[calls];
                const hosted = item.value.hosted_call;
                try std.testing.expectEqual(page.items[1 + calls].position, item.position);
                try std.testing.expectEqualStrings(want[0], hosted.presentation.line.?.words.slice());
                try std.testing.expectEqual(want[1], hosted.presentation.code);
                try std.testing.expectEqual(facts[calls].kind, hosted.action.kind);
                try std.testing.expectEqual(@as(u64, facts[calls].targets.len), hosted.action.targets_total);
                try std.testing.expectEqual(facts[calls].targets.len, hosted.action.targets.served().len);
                try std.testing.expectEqual(facts[calls].pattern != null, hosted.action.pattern != null);
                // Each exact string opens by its field, targets first and then the pattern; the field after the last names nothing.
                var strings: [3][]const u8 = undefined;
                @memcpy(strings[0..facts[calls].targets.len], facts[calls].targets);
                var held = facts[calls].targets.len;
                if (facts[calls].pattern) |pattern| {
                    strings[held] = pattern;
                    held += 1;
                }
                for (strings[0..held], 0..) |text, field| {
                    var reader: content_domain.ContentReader = undefined;
                    reader.open(try storage.openActivityContent(&.{ .session = request.session, .position = item.position, .field = @intCast(field) }));
                    defer reader.close();
                    var bytes: [64]u8 = undefined;
                    const count = try reader.read(0, &bytes);
                    try std.testing.expectEqualStrings(text, bytes[0..count]);
                }
                try std.testing.expectError(error.ContentNotFound, storage.openActivityContent(&.{ .session = request.session, .position = item.position, .field = @intCast(held) }));
                calls += 1;
            };
            try std.testing.expectEqual(@as(usize, 3), calls);
            try std.testing.expectError(error.ContentNotFound, storage.openActivityContent(&.{ .session = request.session, .position = page.items[1].position, .ordinal = 1 }));
        }
    }.run);
}

/// Settles `items` as one Operation's output and returns the Session.
fn settleHostedItems(storage: *Store, tmp: *std.testing.TmpDir, items: []const []const u8) !protocol.Bounded(protocol.max_session_bytes) {
    const session = try configureTestSession(storage, "hosted-config");
    try submitTestMessage(storage, tmp, "hosted-input", "hosted-key", session.slice(), "search");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var all: [4][]const u8 = undefined;
    @memcpy(all[0..items.len], items);
    all[items.len] = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}";
    try settleItemsForTesting(storage, tmp, binding, all[0 .. items.len + 1], "done");
    return session;
}

fn manyQueries(arena: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("{\"type\":\"web_search_call\",\"id\":\"many");
    try out.writer.print("{d}", .{count});
    try out.writer.writeAll("\",\"action\":{\"type\":\"search\",\"queries\":[");
    for (0..count) |index| try out.writer.print("{s}\"q{d}\"", .{ if (index == 0) "" else ",", index });
    try out.writer.writeAll("]}}");
    return out.written();
}

test "a web search that names many targets serves the first eight, keeps up to sixty-four and opens only what it serves" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer memory.deinit();
            const arena = memory.allocator();
            // Nine and sixty-four queries are kept whole; seventy keep sixty-four, the most one item holds.
            const counts = [_]usize{ 9, 64, 70 };
            const kept = [_]u64{ 9, 64, 64 };
            var items: [counts.len][]const u8 = undefined;
            for (counts, &items) |count, *item| item.* = try manyQueries(arena, count);
            const session = try settleHostedItems(&storage, &tmp, &items);
            try std.testing.expectEqual(@as(u64, 9 + 64 + 64), try store_testing.queryU64(&storage, "SELECT count(*) FROM hosted_target", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM hosted_target WHERE target_ordinal>=64", .{}));
            const activity = try store_core.activityPageForTesting(&storage, .{ .session = session, .direction = .backward });
            var seen: usize = 0;
            for (activity.items[0..activity.count]) |item| switch (item.value) {
                .hosted_call => |hosted| {
                    // The page is newest first, so the last item settled comes first.
                    const which = counts.len - 1 - seen;
                    try std.testing.expectEqual(kept[which], hosted.action.targets_total);
                    try std.testing.expectEqual(@as(usize, 8), hosted.action.targets.served().len);
                    try std.testing.expectEqual(@as(usize, 8), item.body().hosted.refs().len);
                    for ([_]u8{ 0, 7 }) |field| {
                        var expected: [8]u8 = undefined;
                        const text = try std.fmt.bufPrint(&expected, "q{d}", .{field});
                        var reader: content_domain.ContentReader = undefined;
                        reader.open(try storage.openActivityContent(&.{ .session = session, .position = item.position, .field = field }));
                        defer reader.close();
                        var bytes: [8]u8 = undefined;
                        const count = try reader.read(0, &bytes);
                        try std.testing.expectEqualStrings(text, bytes[0..count]);
                    }
                    // The ninth target is held but not served, and a search has no pattern, so field 8 names nothing, as `body` says.
                    try std.testing.expectError(error.ContentNotFound, storage.openActivityContent(&.{ .session = session, .position = item.position, .field = 8 }));
                    seen += 1;
                },
                .assistant => {
                    // Only a hosted row holds more than one exact text: a field past the first names nothing on any other row.
                    try std.testing.expectError(error.ContentNotFound, storage.openActivityContent(&.{ .session = session, .position = item.position, .ordinal = item.ordinal, .field = 1 }));
                    var reader: content_domain.ContentReader = undefined;
                    reader.open(try storage.openActivityContent(&.{ .session = session, .position = item.position, .ordinal = item.ordinal }));
                    defer reader.close();
                    var bytes: [8]u8 = undefined;
                    try std.testing.expectEqualStrings("done", bytes[0..try reader.read(0, &bytes)]);
                },
                else => {},
            };
            try std.testing.expectEqual(counts.len, seen);
        }
    }.run);
}

test "a hosted search whose saved facts cannot have come from a settlement reads as a corrupt Store" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Corruption = struct { name: []const u8, sql: [:0]const u8, count: ?u64 = null };
            // Item 0 is a search with two targets; item 1 is a find in a page, with one target and a pattern.
            const mutations = [_]Corruption{
                .{ .name = "an action of none that holds targets", .sql = "UPDATE model_output_item SET hosted_action=0 WHERE item_ordinal=0 AND item_kind=5" },
                .{ .name = "an action of none that holds a pattern", .sql = "UPDATE model_output_item SET hosted_action=0 WHERE item_ordinal=1 AND item_kind=5" },
                .{ .name = "a gap before the first target", .sql = "UPDATE hosted_target SET target_ordinal=3 WHERE item_ordinal=0 AND target_ordinal=0" },
                .{ .name = "a gap between targets", .sql = "UPDATE hosted_target SET target_ordinal=5 WHERE item_ordinal=0 AND target_ordinal=1" },
                .{ .name = "a private first target", .sql = "UPDATE content SET private=1 WHERE content_id IN (SELECT content_id FROM hosted_target WHERE item_ordinal=0 AND target_ordinal=0)" },
                .{ .name = "a private later target", .sql = "UPDATE content SET private=1 WHERE content_id IN (SELECT content_id FROM hosted_target WHERE item_ordinal=0 AND target_ordinal=1)" },
                .{ .name = "a non-inline first target", .sql = "UPDATE content SET form=1 WHERE content_id IN (SELECT content_id FROM hosted_target WHERE item_ordinal=0 AND target_ordinal=0)" },
                .{ .name = "a non-inline later target", .sql = "UPDATE content SET form=1 WHERE content_id IN (SELECT content_id FROM hosted_target WHERE item_ordinal=0 AND target_ordinal=1)" },
                .{ .name = "a private pattern", .sql = "UPDATE content SET private=1 WHERE content_id IN (SELECT hosted_pattern_content_id FROM model_output_item WHERE item_ordinal=1 AND item_kind=5)" },
                .{ .name = "a non-inline pattern", .sql = "UPDATE content SET form=1 WHERE content_id IN (SELECT hosted_pattern_content_id FROM model_output_item WHERE item_ordinal=1 AND item_kind=5)" },
                .{ .name = "more targets than an item may hold", .sql = "INSERT INTO hosted_target(operation_id,item_ordinal,target_ordinal,content_id) " ++ sequence_to_first_argument ++
                    "SELECT t.operation_id,t.item_ordinal,value,t.content_id FROM hosted_target t CROSS JOIN sequence WHERE t.item_ordinal=0 AND t.target_ordinal=0 AND value>=2", .count = 65 },
            };
            inline for (mutations) |mutation| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try settleHostedItems(&storage, &tmp, &.{
                    "{\"type\":\"web_search_call\",\"id\":\"ws1\",\"action\":{\"type\":\"search\",\"queries\":[\"first-target\",\"second-target\"]}}",
                    "{\"type\":\"web_search_call\",\"id\":\"ws2\",\"action\":{\"type\":\"find_in_page\",\"url\":\"site.example\",\"pattern\":\"the-pattern\"}}",
                });
                // Whole before the damage: both searches read.
                const whole = try store_core.activityPageForTesting(&storage, .{ .session = session, .direction = .backward });
                try std.testing.expect(whole.count >= 3);
                if (mutation.count) |count| {
                    try store_testing.withoutForeignKeys(&storage, mutation.sql, .{count});
                } else try store_testing.withoutForeignKeys(&storage, mutation.sql, .{});
                std.testing.expectError(error.CorruptStore, store_core.activityPageForTesting(&storage, .{ .session = session, .direction = .backward })) catch |err| {
                    std.debug.print("corruption not refused: {s}\n", .{mutation.name});
                    return err;
                };
            }
        }
    }.run);
}

test "a hosted action outside the four kinds cannot be saved" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            _ = try settleHostedItems(&storage, &tmp, &.{"{\"type\":\"web_search_call\",\"id\":\"ws1\",\"action\":{\"type\":\"search\",\"query\":\"zig\"}}"});
            // The CHECK on the column refuses it on both engines, so the read's own refusal of such a value is a second line, not a reachable state.
            const refused = if (store_testing.exec(&storage, "UPDATE model_output_item SET hosted_action=4 WHERE item_kind=5", .{})) |_| false else |_| true;
            try std.testing.expect(refused);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT hosted_action FROM model_output_item WHERE item_kind=5", .{}));
        }
    }.run);
}

fn hostedBefore96() old_format.Start {
    @setEvalBranchQuota(100_000);
    return .{ .format = 95, .sql = old_format.FormatSql.neutral(
        "UPDATE session SET next_position=8 WHERE session_ref='d8mv7p';" ++
            "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count,description,call_failed) " ++
            "VALUES(1,1,'d8mv7p',6,5,1,X'0000000000000000000000000000000000000000000000000000000000000001',0,0,4,0,'Search the old sentence',0)," ++
            "(1,2,'d8mv7p',7,5,1,X'0000000000000000000000000000000000000000000000000000000000000002',0,0,4,0,'Search the old failed sentence',1);",
    ) };
}

test "the step to format 96 reads a search saved as a sentence as a search with no facts" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            const start = comptime hostedBefore96();
            try old_format.openAt(case, &storage, &tmp, std.testing.io, &start);
            defer storage.close() catch unreachable;
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT hosted_action FROM model_output_item WHERE item_kind=5", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_output_item WHERE (hosted_action IS NOT NULL)<>(item_kind=5)", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM hosted_target", .{}));
            var request: conversation_read.ConversationPage = .{};
            try request.session.set("d8mv7p");
            const page = try store_core.activityPageForTesting(&storage, .{ .session = request.session, .direction = .backward });
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_output_item WHERE item_kind=5 AND hosted_action=0", .{}));
            // The failed search stays failed through the step, and neither row has anything to open.
            var seen: usize = 0;
            for (page.items[0..page.count]) |item| if (item.value == .hosted_call) {
                const hosted = item.value.hosted_call;
                try std.testing.expectEqualStrings("Search the web", hosted.presentation.line.?.words.slice());
                try std.testing.expectEqual(if (item.position == 7) protocol.ToolPresentation.Code.failed else .succeeded, hosted.presentation.code);
                try std.testing.expect(hosted.action.kind == .none);
                try std.testing.expectEqual(@as(u64, 0), hosted.action.targets_total);
                try std.testing.expectEqual(@as(usize, 0), hosted.action.targets.served().len);
                try std.testing.expect(hosted.action.pattern == null);
                try std.testing.expect(item.body() == .none);
                try std.testing.expectError(error.ContentNotFound, storage.openActivityContent(&.{ .session = request.session, .position = item.position }));
                seen += 1;
            };
            try std.testing.expectEqual(@as(usize, 2), seen);
        }
    }.run);
}

/// Format 97 rows for the step to 98: calls on one operation whose saved line the step must sort into a label, a subject or neither.
/// Contents 100 to 103 are tool names and 104 to 110 call ids, each with its real digest.
fn callLines97() old_format.Start {
    return .{ .format = 97, .sql = .{ .per_engine = .{
        .sqlite = "INSERT INTO content(content_id,digest,byte_length,private,payload) VALUES(100,X'2d872b97bcf4ee4694ca276ffe13d096a379706db977b411cd9a8c0f1fa011c8',13,0,X'6d6573736167655f6167656e74'),(101,X'0d38ecfd3259949a32faa2b7729ae39148750e83cca4a0477d1499c5f439c5b5',15,0,X'726561645f7472616e736372697074'),(102,X'59bdea1dc6d57f7e3449c2e9e2d80fcc83236681969ac401ccec2e5adbb99c9e',10,0,X'66657463685f70616765'),(103,X'19def275b4f6517f179272b70ba3c7bc3fd56069c4f50b04c0b8811d1d9693dd',10,0,X'66696e645f746f6f6c73'),(104,X'504f3efb93f8334c0c667ca164d6be548cc14d583d8f04cd037eb5e8861310ab',6,0,X'63616c6c2d30'),(105,X'6eb3318760b251c70e4da6f829f65508c756e4932ac1fb77c884210f43d3274c',6,0,X'63616c6c2d31'),(106,X'9f183c02ba21bb6312bfb58c5372fc8784e96e4e3904abf11d80e7e05d0ab92b',6,0,X'63616c6c2d32'),(107,X'a65a971eb71791a3de3c80887dbbe37a100a8870d66ab594eab25acc90b2858a',6,0,X'63616c6c2d33'),(108,X'960fb5898e77f51790604f705eacbde5f1a1b90a7539515906d737b62085a751',6,0,X'63616c6c2d34'),(109,X'ae305eb6f9697fbb744602086e4ca27648b6e090cff0db9602922d9dfa20381e',6,0,X'63616c6c2d35');" ++
            "INSERT INTO content(content_id,digest,byte_length,private,payload) VALUES(110,X'261cbf342cfe9ed87658daa6c6414c02739fab9be8f85bc18a3cf0b30d8e1b92',6,0,X'63616c6c2d36');" ++
            "INSERT INTO model_tool_call(operation_id,session_ref,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id,description,field_metadata,action_kind) VALUES(2,'brhkcj',2,2,100,104,100,'Message d8mv7p',X'000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000',1),(2,'brhkcj',3,3,101,105,101,'Read d8mv7p''s transcript',X'000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000',1),(2,'brhkcj',4,4,101,106,101,'Read own transcript',X'000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000',1),(2,'brhkcj',5,5,102,107,102,'Fetch the docs page',X'000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000',1),(2,'brhkcj',6,6,102,108,102,'fetch_page',X'000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000',1),(2,'brhkcj',7,7,103,109,103,'Find tools',X'000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000',1),(2,'brhkcj',8,8,9,110,9,'bash',X'000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000',1);",
        .mysql = "INSERT INTO content(content_id,digest,byte_length,private) VALUES(100,X'2d872b97bcf4ee4694ca276ffe13d096a379706db977b411cd9a8c0f1fa011c8',13,0),(101,X'0d38ecfd3259949a32faa2b7729ae39148750e83cca4a0477d1499c5f439c5b5',15,0),(102,X'59bdea1dc6d57f7e3449c2e9e2d80fcc83236681969ac401ccec2e5adbb99c9e',10,0),(103,X'19def275b4f6517f179272b70ba3c7bc3fd56069c4f50b04c0b8811d1d9693dd',10,0),(104,X'504f3efb93f8334c0c667ca164d6be548cc14d583d8f04cd037eb5e8861310ab',6,0),(105,X'6eb3318760b251c70e4da6f829f65508c756e4932ac1fb77c884210f43d3274c',6,0),(106,X'9f183c02ba21bb6312bfb58c5372fc8784e96e4e3904abf11d80e7e05d0ab92b',6,0),(107,X'a65a971eb71791a3de3c80887dbbe37a100a8870d66ab594eab25acc90b2858a',6,0),(108,X'960fb5898e77f51790604f705eacbde5f1a1b90a7539515906d737b62085a751',6,0),(109,X'ae305eb6f9697fbb744602086e4ca27648b6e090cff0db9602922d9dfa20381e',6,0);" ++
            "INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES(100,0,X'6d6573736167655f6167656e74'),(101,0,X'726561645f7472616e736372697074'),(102,0,X'66657463685f70616765'),(103,0,X'66696e645f746f6f6c73'),(104,0,X'63616c6c2d30'),(105,0,X'63616c6c2d31'),(106,0,X'63616c6c2d32'),(107,0,X'63616c6c2d33'),(108,0,X'63616c6c2d34'),(109,0,X'63616c6c2d35');" ++
            "INSERT INTO content(content_id,digest,byte_length,private) VALUES(110,X'261cbf342cfe9ed87658daa6c6414c02739fab9be8f85bc18a3cf0b30d8e1b92',6,0);" ++
            "INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES(110,0,X'63616c6c2d36');" ++
            "INSERT INTO model_tool_call(operation_id,session_ref,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id,description,field_metadata,action_kind) VALUES(2,'brhkcj',2,2,100,104,100,'Message d8mv7p',X'000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000',1),(2,'brhkcj',3,3,101,105,101,'Read d8mv7p''s transcript',X'000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000',1),(2,'brhkcj',4,4,101,106,101,'Read own transcript',X'000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000',1),(2,'brhkcj',5,5,102,107,102,'Fetch the docs page',X'000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000',1),(2,'brhkcj',6,6,102,108,102,'fetch_page',X'000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000',1),(2,'brhkcj',7,7,103,109,103,'Find tools',X'000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000',1),(2,'brhkcj',8,8,9,110,9,'bash',X'000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000',1);",
    } } };
}

test "the step to format 98 keeps a Bash or MCP call's saved line as its label and the Session a core call named as its subject" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            const start = comptime callLines97();
            try old_format.openAt(case, &storage, &tmp, std.testing.io, &start);
            defer storage.close() catch unreachable;
            const Row = struct { ordinal: u64, label: ?[]const u8, subject: ?[]const u8 };
            const rows = [_]Row{
                // The baseline's Bash calls keep what they said.
                .{ .ordinal = 0, .label = "Run first command", .subject = null },
                .{ .ordinal = 1, .label = "Run second command", .subject = null },
                // A core call keeps no label, and the Session its saved words named becomes its subject.
                .{ .ordinal = 2, .label = null, .subject = "d8mv7p" },
                .{ .ordinal = 3, .label = null, .subject = "d8mv7p" },
                .{ .ordinal = 4, .label = null, .subject = null },
                // An MCP call keeps its description, or the tool's name it read as when it gave none; a built-in with fixed words keeps neither.
                .{ .ordinal = 5, .label = "Fetch the docs page", .subject = null },
                .{ .ordinal = 6, .label = "fetch_page", .subject = null },
                .{ .ordinal = 7, .label = null, .subject = null },
                // A Bash call whose label is the tool's name keeps it.
                .{ .ordinal = 8, .label = "bash", .subject = null },
            };
            for (rows) |row| {
                const where = "operation_id=2 AND call_ordinal=?1";
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE " ++ where, .{row.ordinal}));
                if (row.label) |label| {
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE " ++ where ++ " AND label=?2", .{ row.ordinal, label }));
                } else {
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE " ++ where ++ " AND label IS NULL", .{row.ordinal}));
                }
                if (row.subject) |subject| {
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE " ++ where ++ " AND subject=?2", .{ row.ordinal, subject }));
                } else {
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE " ++ where ++ " AND subject IS NULL", .{row.ordinal}));
                }
            }
        }
    }.run);
}

/// Format 97 rows that turn the baseline's second call into a `message_agent` call saved as "Message d8mv7p".
fn messageLine97() old_format.Start {
    return .{ .format = 97, .sql = .{ .per_engine = .{
        .sqlite = "INSERT INTO content(content_id,digest,byte_length,private,payload) VALUES(100,X'2d872b97bcf4ee4694ca276ffe13d096a379706db977b411cd9a8c0f1fa011c8',13,0,X'6d6573736167655f6167656e74'),(101,X'0d38ecfd3259949a32faa2b7729ae39148750e83cca4a0477d1499c5f439c5b5',15,0,X'726561645f7472616e736372697074'),(102,X'59bdea1dc6d57f7e3449c2e9e2d80fcc83236681969ac401ccec2e5adbb99c9e',10,0,X'66657463685f70616765'),(103,X'19def275b4f6517f179272b70ba3c7bc3fd56069c4f50b04c0b8811d1d9693dd',10,0,X'66696e645f746f6f6c73'),(104,X'504f3efb93f8334c0c667ca164d6be548cc14d583d8f04cd037eb5e8861310ab',6,0,X'63616c6c2d30'),(105,X'6eb3318760b251c70e4da6f829f65508c756e4932ac1fb77c884210f43d3274c',6,0,X'63616c6c2d31'),(106,X'9f183c02ba21bb6312bfb58c5372fc8784e96e4e3904abf11d80e7e05d0ab92b',6,0,X'63616c6c2d32'),(107,X'a65a971eb71791a3de3c80887dbbe37a100a8870d66ab594eab25acc90b2858a',6,0,X'63616c6c2d33'),(108,X'960fb5898e77f51790604f705eacbde5f1a1b90a7539515906d737b62085a751',6,0,X'63616c6c2d34'),(109,X'ae305eb6f9697fbb744602086e4ca27648b6e090cff0db9602922d9dfa20381e',6,0,X'63616c6c2d35');" ++
            "UPDATE model_tool_call SET name_content_id=100,description='Message d8mv7p',field_metadata=X'0d000000000000002d872b97bcf4ee4694ca276ffe13d096a379706db977b411cd9a8c0f1fa011c806000000000000002424a1124da95105ad0cae02f8974290bcdfa6b8f722ab0a9010a03d85dc70aa4200000000000000218db1eed2b15d82d37c2be4440ff39e46365886bd914326b0bf6fceee17f4d1' WHERE operation_id=2 AND call_ordinal=1;",
        .mysql = "INSERT INTO content(content_id,digest,byte_length,private) VALUES(100,X'2d872b97bcf4ee4694ca276ffe13d096a379706db977b411cd9a8c0f1fa011c8',13,0),(101,X'0d38ecfd3259949a32faa2b7729ae39148750e83cca4a0477d1499c5f439c5b5',15,0),(102,X'59bdea1dc6d57f7e3449c2e9e2d80fcc83236681969ac401ccec2e5adbb99c9e',10,0),(103,X'19def275b4f6517f179272b70ba3c7bc3fd56069c4f50b04c0b8811d1d9693dd',10,0),(104,X'504f3efb93f8334c0c667ca164d6be548cc14d583d8f04cd037eb5e8861310ab',6,0),(105,X'6eb3318760b251c70e4da6f829f65508c756e4932ac1fb77c884210f43d3274c',6,0),(106,X'9f183c02ba21bb6312bfb58c5372fc8784e96e4e3904abf11d80e7e05d0ab92b',6,0),(107,X'a65a971eb71791a3de3c80887dbbe37a100a8870d66ab594eab25acc90b2858a',6,0),(108,X'960fb5898e77f51790604f705eacbde5f1a1b90a7539515906d737b62085a751',6,0),(109,X'ae305eb6f9697fbb744602086e4ca27648b6e090cff0db9602922d9dfa20381e',6,0);" ++
            "INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES(100,0,X'6d6573736167655f6167656e74'),(101,0,X'726561645f7472616e736372697074'),(102,0,X'66657463685f70616765'),(103,0,X'66696e645f746f6f6c73'),(104,0,X'63616c6c2d30'),(105,0,X'63616c6c2d31'),(106,0,X'63616c6c2d32'),(107,0,X'63616c6c2d33'),(108,0,X'63616c6c2d34'),(109,0,X'63616c6c2d35');" ++
            "UPDATE model_tool_call SET name_content_id=100,description='Message d8mv7p',field_metadata=X'0d000000000000002d872b97bcf4ee4694ca276ffe13d096a379706db977b411cd9a8c0f1fa011c806000000000000002424a1124da95105ad0cae02f8974290bcdfa6b8f722ab0a9010a03d85dc70aa4200000000000000218db1eed2b15d82d37c2be4440ff39e46365886bd914326b0bf6fceee17f4d1' WHERE operation_id=2 AND call_ordinal=1;",
    } } };
}

test "TPR-4 a call saved before format 98 reads its line from what the step kept, so renaming its peer changes it" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            const start = comptime messageLine97();
            try old_format.openAt(case, &storage, &tmp, std.testing.io, &start);
            defer storage.close() catch unreachable;
            var request: protocol.ActivityPage = .{};
            try request.session.set("brhkcj");
            try expectCallWords(&storage, request, "Message d8mv7p");
            // The Store holds no copy of the words: renaming the peer changes the row saved before.
            try store_testing.exec(&storage, "UPDATE session SET label='Review the WAL' WHERE session_ref='d8mv7p'", .{});
            try expectCallWords(&storage, request, "Message Review the WAL");
        }
    }.run);
}

/// The Activity words of the baseline's two calls: the first is Bash, the second says `second`.
fn expectCallWords(storage: *Store, request: protocol.ActivityPage, second: []const u8) !void {
    const page = try store_core.activityPageForTesting(storage, request);
    var seen: [2]bool = .{ false, false };
    for (page.items[0..page.count]) |item| switch (item.value) {
        .call => |call| {
            seen[call.call_ordinal] = true;
            try std.testing.expectEqualStrings(if (call.call_ordinal == 0) "Run first command" else second, call.description.?.slice());
        },
        else => {},
    };
    try std.testing.expect(seen[0] and seen[1]);
}

const sequence_to_first_argument = "WITH RECURSIVE sequence(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM sequence WHERE value<?1) ";

test "an Activity page costs the same steps after 10 or 10,000 earlier rows, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var rounds: [2][2]u16 = undefined;
            for ([_]usize{ 10, 10_000 }, &rounds) |history, *cost| cost.* = try measure(case, history);
            try std.testing.expectEqual(rounds[0], rounds[1]);
        }

        fn measure(engine: *store_testing.Case, history: usize) ![2]u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "cost-config");
            const start = try store_testing.queryU64(&storage, "SELECT next_position FROM session", .{});
            const content = try store_testing.queryU64(&storage, "SELECT instructions_content_id FROM session", .{});
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,turn_id,admitted_at,source_kind) " ++
                sequence_to_first_argument ++
                "SELECT value,?2,value+1000000,?4,?3+4*(value-1),value,1,1 FROM sequence", .{ history, session.slice(), start, content });
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,attempt_ordinal,resolution_code,resolved_at,tool_set_id,context_window) " ++
                sequence_to_first_argument ++
                "SELECT value,value,?2,1,value,?3+4*(value-1),0,1,'tool_proposals',1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session WHERE session_ref=?2),?4 FROM sequence", .{ history, session.slice(), start, @import("../../product_defaults.zig").unlisted_context_window });
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,extras_content_id,part_count) " ++
                sequence_to_first_argument ++
                "SELECT value,0,?2,?3+4*(value-1)+1,3,1,zeroblob(32),0,?4,0 FROM sequence", .{ history, session.slice(), start, content });
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO model_tool_call(operation_id,session_ref,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id,field_metadata,rejection_code,rejection_content_id,acceptance_position) " ++
                sequence_to_first_argument ++
                "SELECT value,?2,0,0,?4,?4,?4,zeroblob(120),'unknown_tool',?4,?3+4*(value-1)+2 FROM sequence", .{ history, session.slice(), start, content });
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_position,outcome_at) " ++
                sequence_to_first_argument ++
                "SELECT value,?2,value,value,value,'completed',?3+4*(value-1)+3,1 FROM sequence", .{ history, session.slice(), start });
            try store_testing.exec(&storage, "UPDATE session SET next_position=next_position+4*?1", .{history});
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

            var cost: [2]u16 = undefined;
            var opening: protocol.ActivityPage = .{ .direction = .backward };
            try opening.session.set(session.slice());
            const opened = TwinRounds.start(&storage);
            const page = try store_core.activityPageForTesting(&storage, opening);
            cost[0] = opened.taken();
            try std.testing.expect(page.more);
            var forward: protocol.ActivityPage = .{ .end = page.end, .position = tail - 1 };
            try forward.session.set(session.slice());
            const forwarded = TwinRounds.start(&storage);
            const later = try store_core.activityPageForTesting(&storage, forward);
            cost[1] = forwarded.taken();
            try std.testing.expect(later.more);
            try std.testing.expectEqual(tail, later.items[0].position);
            return cost;
        }
    }.run);
}

test "a one-row page of a person's Messages costs the same steps after 10 or 10,000 received ones, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try std.testing.expectEqual(try measure(case, 10), try measure(case, 10_000));
        }

        fn measure(engine: *store_testing.Case, history: usize) !u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "recall-config");
            const peer = try configureTestSession(&storage, "recall-peer");
            try submitTestMessage(&storage, &tmp, "recall-first", "first", session.slice(), "first");
            const start = try store_testing.queryU64(&storage, "SELECT next_position FROM session WHERE session_ref=?1", .{session.slice()});
            const content = try store_testing.queryU64(&storage, "SELECT instructions_content_id FROM session WHERE session_ref=?1", .{session.slice()});
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,sender_session_ref,source_kind) " ++
                sequence_to_first_argument ++
                "SELECT 1000+value,?2,value+1000000,?4,?3+value-1,1,?5,2 FROM sequence", .{ history, session.slice(), start, content, peer.slice() });
            try store_testing.exec(&storage, "UPDATE session SET next_position=next_position+?1 WHERE session_ref=?2", .{ history, session.slice() });
            try store_core.reloadIdentitiesForTesting(&storage);
            var request: protocol.ActivityPage = .{ .direction = .backward, .kinds = .initOne(.admission), .limit = 1 };
            try request.session.set(session.slice());
            const counter = TwinRounds.start(&storage);
            const page = try store_core.activityPageForTesting(&storage, request);
            const taken = counter.taken();
            try std.testing.expect(page.count == 1 and page.items[0].value == .admission and !page.more);
            return taken;
        }
    }.run);
}

test "a forward one-row page of a person's Messages costs the same steps past 10 or 10,000 tool groups, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try std.testing.expectEqual(try measure(case, 10), try measure(case, 10_000));
        }

        fn measure(engine: *store_testing.Case, history: usize) !u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "forward-config");
            try submitTestMessage(&storage, &tmp, "forward-first", "first", session.slice(), "first");
            try submitTestMessage(&storage, &tmp, "forward-second", "second", session.slice(), "second");
            const first = try store_testing.queryU64(&storage, "SELECT min(admission_position) FROM message_admission", .{});
            const start = try store_testing.queryU64(&storage, "SELECT next_position FROM session WHERE session_ref=?1", .{session.slice()});
            const content = try store_testing.queryU64(&storage, "SELECT instructions_content_id FROM session WHERE session_ref=?1", .{session.slice()});
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,attempt_ordinal,resolution_code,resolved_at,tool_set_id,context_window) " ++
                sequence_to_first_argument ++
                "SELECT 1000+value,1000+value,?2,1,1000+value,?3+3*(value-1),0,1,'tool_proposals',1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session WHERE session_ref=?2),?4 FROM sequence", .{ history, session.slice(), start, @import("../../product_defaults.zig").unlisted_context_window });
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,extras_content_id,part_count) " ++
                sequence_to_first_argument ++
                "SELECT 1000+value,0,?2,?3+3*(value-1),3,1,zeroblob(32),0,?4,0 FROM sequence", .{ history, session.slice(), start, content });
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO model_tool_call(operation_id,session_ref,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id,field_metadata,rejection_code,rejection_content_id,acceptance_position) " ++
                sequence_to_first_argument ++
                "SELECT 1000+value,?2,0,0,?4,?4,?4,zeroblob(120),'unknown_tool',?4,?3+3*(value-1)+1 FROM sequence", .{ history, session.slice(), start, content });
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_position,outcome_at) " ++
                sequence_to_first_argument ++
                "SELECT 1000+value,?2,1000+value,1000+value,1000+value,'cancelled',?3+3*(value-1)+2,1 FROM sequence", .{ history, session.slice(), start });
            try store_testing.exec(&storage, "UPDATE session SET next_position=next_position+3*?1 WHERE session_ref=?2", .{ history, session.slice() });
            try store_core.reloadIdentitiesForTesting(&storage);
            try submitTestMessage(&storage, &tmp, "forward-third", "third", session.slice(), "third");
            var request: protocol.ActivityPage = .{ .position = first, .kinds = .initOne(.admission), .limit = 1 };
            try request.session.set(session.slice());
            const counter = TwinRounds.start(&storage);
            const page = try store_core.activityPageForTesting(&storage, request);
            const taken = counter.taken();
            try std.testing.expect(page.count == 1 and page.items[0].position > first and page.more);
            try std.testing.expect(page.aggregates == null);
            return taken;
        }
    }.run);
}

test "a one-row page of a person's Messages costs the same steps past 100 or 10,000 waiting ones, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try std.testing.expectEqual(try measure(case, 100), try measure(case, 10_000));
        }

        fn measure(engine: *store_testing.Case, history: usize) !u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "waiting-config");
            const start = try store_testing.queryU64(&storage, "SELECT next_position FROM session WHERE session_ref=?1", .{session.slice()});
            const content = try store_testing.queryU64(&storage, "SELECT instructions_content_id FROM session WHERE session_ref=?1", .{session.slice()});
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,source_kind) " ++
                sequence_to_first_argument ++
                "SELECT 1000+value,?2,value+1000000,?4,?3+value-1,1,1 FROM sequence", .{ history, session.slice(), start, content });
            try store_testing.exec(&storage, "UPDATE session SET next_position=next_position+?1 WHERE session_ref=?2", .{ history, session.slice() });
            try store_core.reloadIdentitiesForTesting(&storage);
            try submitTestMessage(&storage, &tmp, "waiting-newest", "newest", session.slice(), "newest");
            var request: protocol.ActivityPage = .{ .direction = .backward, .kinds = .initOne(.admission), .limit = 1 };
            try request.session.set(session.slice());
            const counter = TwinRounds.start(&storage);
            const page = try store_core.activityPageForTesting(&storage, request);
            const taken = counter.taken();
            try std.testing.expect(page.count == 1 and page.items[0].value.admission.state == .queued and page.more);
            try std.testing.expect(page.aggregates == null);
            return taken;
        }
    }.run);
}

test "each setting a revision changes is one session_changed row at the position it was accepted" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("change-create", "", workspace, "model-a");
            const session = (try storage.configure(&create, .{})).accepted.session;
            var request: protocol.ActivityPage = .{ .kinds = .initOne(.session_changed) };
            try request.session.set(session.slice());
            try std.testing.expectEqual(@as(usize, 0), (try store_core.activityPageForTesting(&storage, request)).count);
            try submitTestMessage(&storage, &tmp, "change-before", "change-before", session.slice(), "before");
            var change = try completeConfiguration("change-mode-label", session.slice(), workspace, "model-a");
            change.configuration.permission_mode.state = .value;
            try change.configuration.permission_mode.value.set("ask");
            change.configuration.label.state = .value;
            try change.configuration.label.value.set("renamed");
            try std.testing.expect(try storage.configure(&change, .{}) == .accepted);
            var same = try completeConfiguration("change-same", session.slice(), workspace, "model-a");
            try std.testing.expect(try storage.configure(&same, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "change-after", "change-after", session.slice(), "after");
            const page = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 2), page.count);
            const expected = [_]protocol.SessionField{ .permission_mode, .label };
            for (page.items[0..2], expected, 0..) |item, field, ordinal| {
                try std.testing.expectEqual(page.items[0].position, item.position);
                try std.testing.expectEqual(@as(u64, ordinal), item.ordinal);
                try std.testing.expectEqual(@as(u64, 2), item.value.session_changed.revision);
                try std.testing.expectEqual(field, item.value.session_changed.field);
            }
            var all: protocol.ActivityPage = .{};
            try all.session.set(session.slice());
            const every = try store_core.activityPageForTesting(&storage, all);
            var admissions: [2]u64 = undefined;
            var seen: usize = 0;
            for (every.items[0..every.count]) |item| if (item.value == .admission) {
                admissions[seen] = item.position;
                seen += 1;
            };
            try std.testing.expectEqual(@as(usize, 2), seen);
            try std.testing.expect(admissions[0] < page.items[0].position and page.items[0].position < admissions[1]);
            request.direction = .backward;
            const backward = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 2), backward.count);
            try std.testing.expectEqual(protocol.SessionField.label, backward.items[0].value.session_changed.field);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "instruction rows serve each entry that gave the model its instructions, at its own position" {
    try store_testing.forEachEngine(struct {
        const first = "Instruction text A: be brief.";
        const second = "Instruction text B: be thorough.";
        const catalog = skills_domain.Initial{ .ready = .{
            .encoded = "{\"entries\":[{\"name\":\"audit\",\"description\":\"Audit a change\",\"path\":\"/skills/audit/SKILL.md\"}]}",
            .instruction = "Available skills: audit at /skills/audit/SKILL.md",
        } };
        /// The entries in position order: the catalog's, then each update after the revision-one baseline, which a Turn was given. `revision` is null exactly for the catalog.
        const Expected = struct { text: []const u8, revision: ?u64 };
        const rows = blk: {
            var table: [17]Expected = undefined;
            table[0] = .{ .text = catalog.ready.instruction.?, .revision = null };
            for (table[1..], 2..) |*row, revision| row.* = .{ .text = if (revision % 2 == 0) second else first, .revision = revision };
            break :blk table;
        };

        fn readText(storage: *Store, session: anytype, position: u64, out: []u8) ![]const u8 {
            var reader: content_domain.ContentReader = undefined;
            reader.open(try storage.openActivityContent(&.{ .session = session, .position = position }));
            defer reader.close();
            const count = try reader.read(0, out);
            try std.testing.expectEqual(@as(usize, 0), try reader.read(count, out[count..]));
            return out[0..count];
        }

        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("instruction-create", "", workspace, "model-a");
            create.configuration.instructions = .{ .state = .value, .borrowed = first.ptr, .length = first.len, .digest = protocol.contentDigest(first) };
            const session = (try storage.configureWithInitialSkills(&create, null, &catalog, .{})).accepted.session;
            const answer = [_]TestingAnswerPart{.{ .encoded = "ok", .decoded = "ok" }};
            try answerTestTurn(&storage, &tmp, session.slice(), "instruction-turn-0", &answer);
            inline for (1..17) |index| {
                const name = std.fmt.comptimePrint("instruction-turn-{d}", .{index});
                var update = try completeConfiguration(name ++ "-config", session.slice(), workspace, "model-a");
                update.configuration.instructions = try testingBytesContent(&tmp, name ++ "-text", rows[index].text);
                try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
                try answerTestTurn(&storage, &tmp, session.slice(), name, &answer);
            }

            // Only instruction rows, across the 16-row page boundary.
            var request: protocol.ActivityPage = .{ .kinds = .initOne(.instruction) };
            try request.session.set(session.slice());
            var seen: usize = 0;
            var pages: usize = 0;
            while (true) {
                const page = try store_core.activityPageForTesting(&storage, request);
                pages += 1;
                for (page.items[0..page.count]) |item| {
                    const expected = rows[seen];
                    const position = try store_testing.queryU64(&storage, "SELECT session_position FROM conversation_entry WHERE session_ref=?1 AND entry_kind=2 ORDER BY session_position LIMIT 1 OFFSET ?2", .{ session.slice(), @as(u64, seen) });
                    try std.testing.expectEqual(position, item.position);
                    try std.testing.expectEqual(@as(u64, 0), item.ordinal);
                    try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT recorded_at FROM conversation_entry WHERE session_ref=?1 AND session_position=?2", .{ session.slice(), position }), item.at);
                    const turn = try store_testing.queryU64(&storage, "SELECT coalesce(turn_id,0) FROM conversation_entry WHERE session_ref=?1 AND session_position=?2", .{ session.slice(), position });
                    try std.testing.expectEqual(if (expected.revision == null) null else @as(?u64, turn), item.value.instruction.turn);
                    try std.testing.expectEqual(expected.revision, item.value.instruction.revision);
                    try std.testing.expectEqual(@as(u64, expected.text.len), item.value.instruction.content.length);
                    var buffer: [128]u8 = undefined;
                    try std.testing.expectEqualStrings(expected.text, try readText(&storage, session, position, &buffer));
                    seen += 1;
                }
                if (!page.more) break;
                request.position = page.items[page.count - 1].position;
                request.ordinal = page.items[page.count - 1].ordinal;
            }
            try std.testing.expectEqual(rows.len, seen);
            try std.testing.expectEqual(@as(usize, 2), pages);

            // Every kind, in position order: instruction rows sit among the user and assistant rows.
            var all: protocol.ActivityPage = .{};
            try all.session.set(session.slice());
            var previous: ?struct { position: u64, ordinal: u64 } = null;
            var counts: [3]usize = @splat(0);
            while (true) {
                const page = try store_core.activityPageForTesting(&storage, all);
                for (page.items[0..page.count]) |item| {
                    if (previous) |before| try std.testing.expect(item.position > before.position or (item.position == before.position and item.ordinal > before.ordinal));
                    previous = .{ .position = item.position, .ordinal = item.ordinal };
                    switch (item.value) {
                        .instruction => counts[0] += 1,
                        .user => counts[1] += 1,
                        .assistant => counts[2] += 1,
                        else => {},
                    }
                }
                if (!page.more) break;
                all.position = page.items[page.count - 1].position;
                all.ordinal = page.items[page.count - 1].ordinal;
            }
            try std.testing.expectEqualSlices(usize, &.{ rows.len, 17, 17 }, &counts);

            // Backward paging serves the newest instruction first, and a filter that omits the kind serves none.
            var backward: protocol.ActivityPage = .{ .direction = .backward, .kinds = .initOne(.instruction), .limit = 1 };
            try backward.session.set(session.slice());
            const newest = try store_core.activityPageForTesting(&storage, backward);
            try std.testing.expectEqual(@as(usize, 1), newest.count);
            try std.testing.expectEqual(rows[rows.len - 1].revision, newest.items[0].value.instruction.revision);
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT max(session_position) FROM conversation_entry WHERE session_ref=?1 AND entry_kind=2", .{session.slice()}), newest.items[0].position);
            var others: protocol.ActivityPage = .{ .kinds = .full };
            others.kinds.remove(.instruction);
            try others.session.set(session.slice());
            while (true) {
                const page = try store_core.activityPageForTesting(&storage, others);
                for (page.items[0..page.count]) |item| try std.testing.expect(item.value != .instruction);
                if (!page.more) break;
                others.position = page.items[page.count - 1].position;
                others.ordinal = page.items[page.count - 1].ordinal;
            }

            // A private instruction is refused, not served.
            const refused = try store_testing.queryU64(&storage, "SELECT session_position FROM conversation_entry WHERE session_ref=?1 AND entry_kind=2 ORDER BY session_position LIMIT 1 OFFSET 3", .{session.slice()});
            try store_testing.exec(&storage, "UPDATE content SET private=1 WHERE content_id=(SELECT content_id FROM conversation_entry WHERE session_ref=?1 AND session_position=?2)", .{ session.slice(), refused });
            try std.testing.expectError(error.CorruptStore, storage.openActivityContent(&.{ .session = session, .position = refused }));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "skill rows serve each skill a Message bound, at its own position" {
    try store_testing.forEachEngine(struct {
        /// The text of each skill a Turn was given. The first skill of the first Message is the one over 16 KiB, so its content opens in windows.
        const big = blk: {
            @setEvalBranchQuota(100_000);
            var bytes: [40_000]u8 = undefined;
            for (&bytes, 0..) |*byte, index| byte.* = "abcdefghijklmnopqrstuvwxyz\n"[index % 27];
            break :blk bytes;
        };
        const turns = 9;

        fn name(comptime turn: usize, comptime ordinal: usize) []const u8 {
            return std.fmt.comptimePrint("skill-{d}-{d}", .{ turn, ordinal });
        }

        fn text(comptime turn: usize, comptime ordinal: usize) []const u8 {
            if (turn == 0 and ordinal == 2) return &big;
            return std.fmt.comptimePrint("Skill file: \"/skills/{d}/SKILL.md\"\n\nbody {d}.{d}", .{ turn, turn, ordinal });
        }

        fn readWindows(storage: *Store, session: anytype, position: u64, out: *std.ArrayList(u8)) !void {
            var reader: content_domain.ContentReader = undefined;
            reader.open(try storage.openActivityContent(&.{ .session = session, .position = position }));
            defer reader.close();
            var window: [16 * 1024]u8 = undefined;
            var at: u64 = 0;
            while (true) {
                const count = try reader.read(at, &window);
                if (count == 0) break;
                try out.appendSlice(std.testing.allocator, window[0..count]);
                at += count;
            }
        }

        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "skill-rows-config");
            inline for (0..turns) |turn| {
                const key = std.fmt.comptimePrint("skill-rows-{d}", .{turn});
                try store_testing.submitTestMessageWithSkills(&storage, &tmp, key, key, session.slice(), "use the skills", &.{
                    .{ .name = name(turn, 1), .bytes = text(turn, 1) }, .{ .name = name(turn, 2), .bytes = text(turn, 2) },
                });
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try store_testing.settleAnswerTestTurn(&storage, &tmp, binding, key, &.{.{ .encoded = "ok", .decoded = "ok" }});
            }
            const rows = 2 * turns;

            // Only skill rows, across the 16-row page boundary, forward and backward.
            for ([_]bool{ true, false }) |forward| {
                var request: protocol.ActivityPage = .{ .direction = if (forward) .forward else .backward, .kinds = .initOne(.skill) };
                try request.session.set(session.slice());
                var seen: usize = 0;
                var pages: usize = 0;
                while (true) {
                    const page = try store_core.activityPageForTesting(&storage, request);
                    pages += 1;
                    for (page.items[0..page.count]) |item| {
                        const index = if (forward) seen else rows - 1 - seen;
                        const turn = index / 2;
                        const ordinal = index % 2 + 1;
                        var keys: [16]u8 = undefined;
                        const command_key = try std.fmt.bufPrint(&keys, "skill-rows-{d}", .{turn});
                        const admission = try store_testing.queryU64(&storage, "SELECT admission_id FROM message_admission WHERE session_ref=?1 AND command_key=?2", .{ session.slice(), command_key });
                        const message_position = try store_testing.queryU64(&storage, "SELECT session_position FROM conversation_entry WHERE session_ref=?1 AND entry_kind=1 AND source_admission_id=?2", .{ session.slice(), admission });
                        const position = message_position + ordinal;
                        try std.testing.expectEqual(position, item.position);
                        try std.testing.expectEqual(@as(u64, 0), item.ordinal);
                        try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT recorded_at FROM conversation_entry WHERE session_ref=?1 AND session_position=?2 AND entry_kind=4", .{ session.slice(), position }), item.at);
                        const skill = item.value.skill;
                        try std.testing.expectEqual(admission, skill.admission);
                        try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT turn_id FROM message_admission WHERE admission_id=?1", .{admission}), skill.turn);
                        try std.testing.expectEqual(@as(u64, ordinal), skill.ordinal);
                        var expected_name: [16]u8 = undefined;
                        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected_name, "skill-{d}-{d}", .{ turn, ordinal }), skill.name.slice());
                        var expected_text: [64]u8 = undefined;
                        const expected = if (turn == 0 and ordinal == 2) &big else try std.fmt.bufPrint(&expected_text, "Skill file: \"/skills/{d}/SKILL.md\"\n\nbody {d}.{d}", .{ turn, turn, ordinal });
                        try std.testing.expectEqual(@as(u64, expected.len), skill.content.length);
                        var actual: std.ArrayList(u8) = .empty;
                        defer actual.deinit(std.testing.allocator);
                        try readWindows(&storage, session, position, &actual);
                        try std.testing.expectEqualSlices(u8, expected, actual.items);
                        seen += 1;
                    }
                    if (!page.more) break;
                    request.end = page.end;
                    request.position = page.items[page.count - 1].position;
                    request.ordinal = page.items[page.count - 1].ordinal;
                }
                try std.testing.expectEqual(rows, seen);
                try std.testing.expectEqual(@as(usize, 2), pages);
            }

            // A filter that omits the kind serves none, and every kind keeps position order with each skill after its Message's user row.
            var all: protocol.ActivityPage = .{};
            try all.session.set(session.slice());
            var others: protocol.ActivityPage = .{ .kinds = .full };
            others.kinds.remove(.skill);
            try others.session.set(session.slice());
            var counted: usize = 0;
            while (true) {
                const page = try store_core.activityPageForTesting(&storage, others);
                for (page.items[0..page.count]) |item| try std.testing.expect(item.value != .skill);
                if (!page.more) break;
                others.position = page.items[page.count - 1].position;
                others.ordinal = page.items[page.count - 1].ordinal;
            }
            while (true) {
                const page = try store_core.activityPageForTesting(&storage, all);
                for (page.items[0..page.count]) |item| counted += @intFromBool(item.value == .skill);
                if (!page.more) break;
                all.position = page.items[page.count - 1].position;
                all.ordinal = page.items[page.count - 1].ordinal;
            }
            try std.testing.expectEqual(rows, counted);

            // A private skill text is refused, not served.
            const refused = try store_testing.queryU64(&storage, "SELECT session_position FROM conversation_entry WHERE session_ref=?1 AND entry_kind=4 ORDER BY session_position LIMIT 1 OFFSET 4", .{session.slice()});
            try store_testing.exec(&storage, "UPDATE content SET private=1 WHERE content_id=(SELECT content_id FROM conversation_entry WHERE session_ref=?1 AND session_position=?2)", .{ session.slice(), refused });
            try std.testing.expectError(error.CorruptStore, storage.openActivityContent(&.{ .session = session, .position = refused }));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "every kind of Conversation entry a model is given has an Activity row at its position" {
    try store_testing.forEachEngine(struct {
        /// The Activity row kinds that may serve a Historical entry. A kind added to `HistoricalEntryKind` fails to compile until it is mapped here.
        fn serving(kind: HistoricalEntryKind) []const protocol.ActivityItem.Kind {
            return switch (kind) {
                .user => &.{.user},
                .instruction => &.{.instruction},
                .skill => &.{.skill},
                .provider_output => &.{ .assistant, .call, .hosted_call, .compacted },
                .tool_results => &.{.tool_result},
                .operation => &.{.model_call},
            };
        }

        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const first = "Instruction text A.";
            const second = "Instruction text B.";
            var create = try completeConfiguration("complete-create", "", workspace, "model-a");
            create.configuration.instructions = .{ .state = .value, .borrowed = first.ptr, .length = first.len, .digest = protocol.contentDigest(first) };
            const session = (try storage.configure(&create, .{})).accepted.session;
            try answerTestTurn(&storage, &tmp, session.slice(), "complete-first", &.{.{ .encoded = "ok", .decoded = "ok" }});
            var update = try completeConfiguration("complete-update", session.slice(), workspace, "model-a");
            update.configuration.instructions = try testingBytesContent(&tmp, "complete-update-text", second);
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try store_testing.submitTestMessageWithSkills(&storage, &tmp, "complete-input", "complete-input", session.slice(), "propose", &.{
                .{ .name = "complete-a", .bytes = "skill text a" }, .{ .name = "complete-b", .bytes = "skill text b" },
            });
            const calling = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, calling, "complete-calls");
            var stop = try completeSessionStop("complete-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "complete-next", "complete-next", session.slice(), "continue");
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

            // Every Activity row, with its position.
            const Row = struct { position: u64, kind: protocol.ActivityItem.Kind };
            var rows: std.ArrayList(Row) = .empty;
            defer rows.deinit(std.testing.allocator);
            var request: protocol.ActivityPage = .{ .kinds = .full };
            try request.session.set(session.slice());
            while (true) {
                const page = try store_core.activityPageForTesting(&storage, request);
                for (page.items[0..page.count]) |item| try rows.append(std.testing.allocator, .{ .position = item.position, .kind = std.meta.activeTag(item.value) });
                if (!page.more) break;
                request.position = page.items[page.count - 1].position;
                request.ordinal = page.items[page.count - 1].ordinal;
            }

            // Every entry the model is given, and that this Session gave it one of each kind.
            var view: TestingPage = undefined;
            view.open(&storage, next);
            defer view.close();
            var given: std.EnumSet(HistoricalEntryKind) = .empty;
            var after: u64 = 0;
            while (try view.nextEntry(after)) |entry| {
                after = entry.position;
                given.insert(entry.kind);
                // A request reads a group's results before the next entry.
                if (entry.kind == .tool_results) while (try view.nextToolResult()) |_| {};
                const kinds = serving(entry.kind);
                const served = for (rows.items) |row| {
                    if (row.position == entry.position and std.mem.indexOfScalar(protocol.ActivityItem.Kind, kinds, row.kind) != null) break true;
                } else false;
                if (!served) std.debug.print("no Activity row serves the {s} entry at position {d}\n", .{ @tagName(entry.kind), entry.position });
                try std.testing.expect(served);
            }
            try std.testing.expectEqual(std.EnumSet(HistoricalEntryKind).full, given);
        }
    }.run);
}

test "call and forwarded approval rows expose saved identity description and original arguments" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var digests: [membership_records.len][32]u8 = undefined;
            const host_tool_set = membershipToolSet(&digests);
            for ([_][]const u8{ "fetch_page", "bash", "start_agent" }) |tool| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
                defer storage.close() catch unreachable;
                const parent = try configureTestSession(&storage, "inline-parent");
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                var configure = try completeConfiguration("inline-child", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
                configure.configuration.tools = try .of(&.{tool});
                configure.configuration.permission_mode.state = .value;
                try configure.configuration.permission_mode.value.set("ask");
                const child = (try storage.configure(&configure, .{})).accepted.session;
                try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
                try submitTestMessage(&storage, &tmp, "inline-input", "inline-message", child.slice(), "call");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const mcp = std.mem.eql(u8, tool, "fetch_page");
                const bash = std.mem.eql(u8, tool, "bash");
                const arguments = if (mcp) "{ \"rui_call_description\": \"Fetch inline\", \"url\": \"https://example.test\" }" else if (bash) "{ \"description\": \"Print inline\", \"cmd\": \"printf inline\", \"timeout_ms\": null }" else "{ \"task\": \"child task\" }";
                const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, arguments, .{});
                defer std.testing.allocator.free(encoded);
                try settleCallsForTesting(&storage, &tmp, model, "inline-call", &.{.{ .item_id = "inline-item", .name = tool, .encoded_call_id = "inline-id", .decoded_call_id = "inline-id", .encoded_arguments = encoded[1 .. encoded.len - 1], .decoded_arguments = arguments }});
                const own = try store_core.activityPageForTesting(&storage, .{ .session = child, .kinds = .initMany(&.{ .call, .approval_requested }) });
                const call = own.items[0].value.call;
                try std.testing.expectEqualStrings(tool, call.tool.?.slice());
                if (mcp or bash) {
                    try std.testing.expect(call.description != null);
                    try std.testing.expectEqualStrings(if (mcp) "Fetch inline" else "Print inline", call.description.?.slice());
                }
                if (mcp) try std.testing.expectEqualStrings("docs", call.server.?.slice()) else try std.testing.expect(call.server == null);
                try expectActivityArguments(&storage, child, own.items[0], arguments);
                try std.testing.expectEqual(@as(usize, if (mcp or bash) 2 else 1), own.count);
                if (mcp or bash) {
                    const approval = own.items[1].value.approval_requested;
                    try std.testing.expectEqualDeep(call.description, approval.description);
                    try std.testing.expectEqualDeep(call.tool, approval.tool);
                    try std.testing.expectEqualDeep(call.server, approval.server);
                    try expectActivityArguments(&storage, child, own.items[1], arguments);
                    try std.testing.expect(try storage.deliverSessionForward((try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.forward, .{}));
                    const forwarded = try store_core.activityPageForTesting(&storage, .{ .session = parent, .kinds = .initOne(.approval_requested) });
                    try std.testing.expectEqual(@as(usize, 1), forwarded.count);
                    try std.testing.expectEqualDeep(approval, forwarded.items[0].value.approval_requested);
                    try expectActivityArguments(&storage, parent, forwarded.items[0], arguments);
                }
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

test "Activity full page keeps call approval and model decoder scratch disjoint" {
    try store_testing.forEachEngine(struct {
        fn run(engine: *store_testing.Case) !void {
            var digests: [membership_records.len][32]u8 = undefined;
            const host_tool_set = membershipToolSet(&digests);
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStoreWith(engine, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
            defer storage.close() catch unreachable;
            var workspace: [protocol.max_workspace_bytes]u8 = undefined;
            var configure = try completeConfiguration("scratch-config", "", try canonicalCwd(std.testing.io, &workspace), "model-a");
            configure.configuration.tools = try .of(&.{ "bash", "fetch_page" });
            configure.configuration.permission_mode.state = .value;
            try configure.configuration.permission_mode.value.set("ask");
            const session = (try storage.configure(&configure, .{})).accepted.session;
            try submitTestMessage(&storage, &tmp, "scratch-first", "scratch-first-message", session.slice(), "first");
            try answerTestTurn(&storage, &tmp, session.slice(), "scratch-answer", &.{.{ .encoded = "done", .decoded = "done" }});
            try submitTestMessage(&storage, &tmp, "scratch-next", "scratch-next-message", session.slice(), "next");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            var calls: [protocol.ActivityPage.items / 2]TestingCall = undefined;
            var descriptions: [calls.len][]const u8 = undefined;
            for (&calls, &descriptions, 0..) |*call, *description, i| {
                const bytes = try allocator.alloc(u8, 1 + i * @as(usize, if (i % 2 == 0) 28 else 12));
                @memset(bytes, @as(u8, @intCast('a' + i)));
                description.* = bytes;
                const mcp = i % 2 == 0;
                const arguments = try std.fmt.allocPrint(allocator, "{{\"{s}\":\"{s}\",\"cmd\":\"true\"}}", .{ if (mcp) "rui_call_description" else "description", bytes });
                const encoded = try std.json.Stringify.valueAlloc(allocator, arguments, .{});
                const id = try std.fmt.allocPrint(allocator, "scratch-{d}", .{i});
                call.* = .{ .item_id = id, .name = if (mcp) "fetch_page" else "bash", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = encoded[1 .. encoded.len - 1], .decoded_arguments = arguments };
            }
            try settleCallsForTesting(&storage, &tmp, model, "scratch-calls", &calls);
            var request: protocol.ActivityPage = .{ .session = session, .kinds = .initMany(&.{ .call, .approval_requested }) };
            const full = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, protocol.ActivityPage.items), full.count);
            try std.testing.expect(!full.more);
            for (full.items[0..full.count]) |item| try check(&storage, session, item, &calls, &descriptions);
            request.kinds.insert(.model_call);
            inline for (.{ .forward, .backward }) |direction| {
                request.direction = direction;
                request.position = 0;
                request.ordinal = null;
                var count: usize = 0;
                var models: usize = 0;
                var answered = false;
                var proposed = false;
                while (true) {
                    const page = try store_core.activityPageForTesting(&storage, request);
                    for (page.items[0..page.count]) |item| {
                        count += 1;
                        if (item.value == .model_call) {
                            const decoded = item.value.model_call;
                            try std.testing.expectEqualStrings("model-a", decoded.model.slice());
                            try std.testing.expectEqual(@as(u64, 1), decoded.attempts);
                            if (std.mem.eql(u8, decoded.status.slice(), "answer")) {
                                try std.testing.expect(!answered);
                                answered = true;
                            } else {
                                try std.testing.expectEqualStrings("tool_proposals", decoded.status.slice());
                                try std.testing.expect(!proposed);
                                proposed = true;
                            }
                            models += 1;
                        } else try check(&storage, session, item, &calls, &descriptions);
                    }
                    if (!page.more) break;
                    const edge = page.items[page.count - 1];
                    request.position = edge.position;
                    request.ordinal = edge.ordinal;
                }
                try std.testing.expectEqual(@as(usize, calls.len * 2 + 2), count);
                try std.testing.expectEqual(@as(usize, 2), models);
            }
            try std.testing.expect(!storage.isFenced());
        }

        fn check(storage: *Store, session: protocol.Bounded(protocol.max_session_bytes), item: protocol.ActivityItem, calls: []const TestingCall, descriptions: []const []const u8) !void {
            const ordinal = switch (item.value) {
                .call => |call| call.call_ordinal,
                .approval_requested => |approval| approval.call_ordinal,
                else => return error.UnexpectedActivityKind,
            };
            const description, const tool, const server = switch (item.value) {
                .call => |call| .{ call.description, call.tool, call.server },
                .approval_requested => |approval| .{ approval.description, approval.tool, approval.server },
                else => unreachable,
            };
            try std.testing.expectEqualStrings(descriptions[ordinal], description.?.slice());
            try std.testing.expectEqualStrings(calls[ordinal].name, tool.?.slice());
            if (ordinal % 2 == 0) try std.testing.expectEqualStrings("docs", server.?.slice()) else try std.testing.expect(server == null);
            try expectActivityArguments(storage, session, item, calls[ordinal].decoded_arguments);
        }
    }.run);
}
