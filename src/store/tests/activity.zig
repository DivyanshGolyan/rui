//! Activity Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const historical_domain = @import("../domain/historical.zig");
const reads_domain = @import("../domain/reads.zig");
const store_testing = @import("../testing.zig");
const HistoricalEntryKind = historical_domain.HistoricalEntryKind;
const HistoricalReader = historical_domain.HistoricalReader;
const HistoricalView = historical_domain.HistoricalView;
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
            // Seventeen calls in one group: every page below is full.
            var calls: [17]TestingCall = undefined;
            var names: [17][16]u8 = undefined;
            for (&calls, &names, 0..) |*call, *name, index| {
                const id = try std.fmt.bufPrint(name, "rounds-{d}", .{index});
                call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "{}", .decoded_arguments = "{}" };
            }
            try settleCallsForTesting(&storage, &tmp, binding, "rounds-output", &calls);
            var conversation: protocol.ConversationPage = .{};
            try conversation.session.set(session.slice());
            var activity: protocol.ActivityPage = .{};
            try activity.session.set(session.slice());
            const full = try pageRounds(&storage, &conversation, &activity);
            try std.testing.expectEqual(@as(usize, 16), full.conversation);
            try std.testing.expectEqual(@as(usize, 16), full.activity);
            // Smaller pages of the same kinds: the first Tool Result and the User
            // entry before it; the rows through the first call.
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

/// The rounds each page read takes, with its row counts and the positions
/// its caller bounds smaller pages with.
fn pageRounds(storage: *Store, conversation: *const protocol.ConversationPage, activity: *const protocol.ActivityPage) !PageRounds {
    var result: PageRounds = undefined;
    var public_page: reads_domain.PublicConversationPage = undefined;
    var activity_page: protocol.ActivityFacts = undefined;
    {
        const entry = try store_core.enter(storage, .none);
        defer entry.release();
        var a: reads_domain.ReadAccess = .open(&entry);
        defer a.deinit();
        const before = storage.testing_content_work.rounds;
        try reads_domain.publicConversationPage(&a, conversation, &public_page);
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
            try std.testing.expectEqual(@as(protocol.Queued, .{}), (try store_core.activityPageForTesting(&storage, request)).queued);
            try submitTestMessage(&storage, &tmp, "queued-a", "a", session.slice(), "first");
            try submitTestMessage(&storage, &tmp, "queued-b", "b", session.slice(), "second");
            const waiting = try store_core.activityPageForTesting(&storage, request);
            const first = waiting.items[0];
            const second = waiting.items[1];
            try std.testing.expectEqual(@as(protocol.Queued, .{ .count = 2, .oldest_position = first.position, .newest_admission = second.value.admission.admission, .newest_position = second.position }), waiting.queued);
            // Taken at an input boundary: none waits at the latest end, both still
            // do at the earlier one.
            var admitted = (try storage.admitNextModelAttempt(.{})).?;
            _ = try admitted.permit.consume();
            try std.testing.expectEqual(@as(u64, 0), (try store_core.activityPageForTesting(&storage, request)).queued.count);
            var frozen = request;
            frozen.end = waiting.end;
            try std.testing.expectEqual(waiting.queued, (try store_core.activityPageForTesting(&storage, frozen)).queued);
            // One sent behind the work waits until a stop excludes it.
            try submitTestMessage(&storage, &tmp, "queued-c", "c", session.slice(), "third");
            const behind = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(u64, 1), behind.queued.count);
            try std.testing.expectEqual(behind.end, behind.queued.oldest_position);
            try std.testing.expectEqual(behind.end, behind.queued.newest_position);
            var stop = try completeSessionStop("queued-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 0), (try store_core.activityPageForTesting(&storage, request)).queued.count);
            frozen.end = behind.end;
            try std.testing.expectEqual(behind.queued, (try store_core.activityPageForTesting(&storage, frozen)).queued);
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
            // Distinct times name the owning fact of each row. Tool Result entries
            // are recorded too, but a result row is dated by its group's last
            // acceptance.
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
                    // Asked when its call was made.
                    .approval_requested => 104,
                    .hosted_call, .sent, .send_failed, .received, .session_changed, .compacted => unreachable,
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
                        // It sits right after its call, at the call's position.
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
                // A page of approval requests alone names each by its own row.
                request.kinds = .initOne(.approval_requested);
                const only = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(approvals, only.count);
                // Backward, from the end, the same rows come in reverse.
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
            // The clock stepped back between the two acceptances: the later one,
            // at the greater position, carries the earlier time.
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
                    // Queued behind the active Turn, which then fails: pending from
                    // the outcome, though the clock read earlier than at admission.
                    .behind_the_turn => {
                        try submitTestMessage(&storage, &tmp, "stepped-queue-first", "stepped-queue-first", session.slice(), "first");
                        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        try submitTestMessage(&storage, &tmp, "stepped-queue-input", "stepped-queue-input", session.slice(), "queued");
                        var diagnostic: [512]u8 = undefined;
                        const quota: @import("../../transport_policy.zig").Quota = .{ .refusal = .quota, .resets_at = 1792940000 };
                        try storage.settleModelAttemptFailure(binding, .{ .rejected = .{ .code = quota.failureCode(), .diagnostic = quota.format(&diagnostic), .request_id = .{}, .report = "" } }, .ordinary, .{});
                        try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=200 WHERE command_key='stepped-queue-input';UPDATE turn SET outcome_at=100", .{});
                    },
                    // Admitted after the outcome: pending from the admission, though
                    // the clock read earlier than at the outcome.
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
                // Damage only the call fields' bytes, not the accepted references or
                // their metadata. Lightweight observations do not read those bytes.
                try store_testing.zeroContent(&storage, "SELECT arguments_content_id FROM model_tool_call");
                const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
                defer std.testing.allocator.free(report);
                try std.testing.expect(std.mem.indexOf(u8, report, "Run first command") != null);
                const after = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(before.call_activity.total, after.call_activity.total);
                for (before.call_activity.entries[0..before.call_activity.count], after.call_activity.entries[0..after.call_activity.count]) |original, observed| {
                    try std.testing.expectEqualStrings(original.presentation.description.?.slice(), observed.presentation.description.?.slice());
                    try std.testing.expectEqual(original.presentation.code, observed.presentation.code);
                }
                // Model replay, not label observation, authenticates field bytes.
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
            var request: protocol.ConversationPage = .{};
            try request.session.set(session.slice());
            const before = try store_core.publicConversationPageForTesting(&storage, request);
            try store_testing.zeroContent(&storage, "SELECT name_content_id FROM model_tool_call");
            const after = try store_core.publicConversationPageForTesting(&storage, request);
            try std.testing.expectEqual(before.count, after.count);
            var results: usize = 0;
            for (before.items[0..before.count], after.items[0..after.count]) |original, observed| {
                if (original.presentation) |presentation| {
                    results += 1;
                    try std.testing.expectEqualStrings(presentation.description.?.slice(), observed.presentation.?.description.?.slice());
                    try std.testing.expectEqual(presentation.code, observed.presentation.?.code);
                }
            }
            try std.testing.expectEqual(@as(usize, 2), results);
            try submitTestMessage(&storage, &tmp, "replay-next", "replay-next", session.slice(), "continue");
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var view: HistoricalView = undefined;
            storage.openHistoricalView(next, &view);
            defer view.close();
            // Discovery trusts the labels; the first call's name fences when it is
            // read for replay.
            const first = (try nextTestingItem(&view, 0)).?;
            try std.testing.expectEqual(HistoricalEntryKind.user, first.kind);
            const call = (try nextTestingItem(&view, first.position)).?;
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT min(session_position) FROM model_output_item WHERE item_kind=3", .{}), call.position);
            const name = (try view.openOutput(call.position)).call.?[0];
            var reader: HistoricalReader = undefined;
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
            for (page.items[0..page.count]) |item| try std.testing.expect(item.value != .tool_result);
            try std.testing.expectEqual(@as(u64, 20), page.call_activity.total);
            try std.testing.expectEqual(@as(usize, 3), page.call_activity.count);
            for (page.call_activity.entries, 0..) |entry, index| {
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
            try std.testing.expectEqual(@as(u64, 11), split.call_activity.total);
            try std.testing.expectEqual(@as(u64, 9), split.call_activity.entries[0].ordinal);
            const split_last = split.items[split.count - 1];
            request.position = split_last.position;
            request.ordinal = split_last.ordinal;
            const finished = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expect(!finished.more);
            try std.testing.expectEqual(@as(u64, 0), finished.call_activity.total);
            request.position = 0;
            request.ordinal = null;
            request.direction = .backward;
            try std.testing.expectEqual(@as(u64, 0), (try store_core.activityPageForTesting(&storage, request)).call_activity.total);

            // Fixed history boundaries cannot suppress newer live calls.
            try submitTestMessage(&storage, &tmp, "live-new", "new", session.slice(), "propose again");
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, next, "live-new-calls");
            request.direction = .forward;
            request.position = finished.end;
            const frozen = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 0), frozen.count);
            try std.testing.expectEqual(@as(u64, 2), frozen.call_activity.total);
            try std.testing.expectEqual(next.operation_id, frozen.call_activity.entries[0].operation);
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
            // One call per Operation, so the count spans more Operations than a
            // read bounded by the page's 16 rows would reach.
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
            // The page shows the first Operations' items; activity counts the
            // calls whose groups are published after its last item.
            const after = try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE acceptance_position>?1", .{page.items[page.count - 1].position});
            try std.testing.expect(after > 16);
            try std.testing.expectEqual(after, page.call_activity.total);
            try std.testing.expectEqual(@as(usize, 3), page.call_activity.count);
            try std.testing.expect(page.call_activity.entries[0].operation > first);
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
            const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
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
                "{\"type\":\"web_search_call\",\"id\":\"ws1\",\"status\":\"completed\",\"action\":{\"type\":\"search\",\"query\":\"zig\\n0.17 \\\"notes\\\"\"}}",
                "{\"type\":\"web_search_call\",\"id\":\"ws2\",\"status\":\"failed\",\"action\":{\"type\":\"open_page\",\"url\":\"https://www.ziglang.org/x\"}}",
                "{\"type\":\"web_search_call\",\"id\":\"ws3\",\"action\":{\"type\":\"find_in_page\",\"url\":\"ziglang.org\",\"pattern\":\"Io\"}}",
                "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}",
            }, "done");
            const expected = [_]struct { []const u8, protocol.ToolPresentation.Code }{
                .{ "Find “Io” in ziglang.org", .succeeded },
                .{ "Open ziglang.org/x", .failed },
                .{ "Search “zig 0.17 \"notes\"”", .succeeded },
            };
            var request: protocol.ConversationPage = .{};
            try request.session.set(session.slice());
            const page = try store_core.publicConversationPageForTesting(&storage, request);
            // Newest first: the answer, the three calls in reverse, the Message.
            try std.testing.expectEqual(@as(usize, 5), page.count);
            try std.testing.expect(page.items[0].kind == .assistant);
            for (page.items[1..4], expected, 0..) |item, want, index| {
                try std.testing.expect(item.kind == .hosted_call);
                try std.testing.expectEqual(@as(u64, 0), item.ordinal);
                try std.testing.expectEqual(page.items[0].position - 1 - index, item.position);
                try std.testing.expectEqualStrings(want[0], item.presentation.?.description.?.slice());
                try std.testing.expectEqual(want[1], item.presentation.?.code);
                try std.testing.expectEqual(item.position, item.presentation.?.publication_position.?);
            }
            try std.testing.expect(page.items[4].kind == .user);
            // A cursor may stop at a call, and the page goes on from there.
            request.end = page.end;
            request.before_position = page.items[2].position;
            const older = try store_core.publicConversationPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 2), older.count);
            try std.testing.expectEqualStrings(expected[2][0], older.items[0].presentation.?.description.?.slice());
            // A call has no content to read.
            try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&.{ .session = request.session, .position = page.items[1].position, .ordinal = 0 }));

            const activity = try store_core.activityPageForTesting(&storage, .{ .session = request.session, .direction = .backward });
            var calls: usize = 0;
            for (activity.items[0..activity.count]) |item| if (item.value == .hosted_call) {
                const want = expected[calls];
                try std.testing.expectEqual(page.items[1 + calls].position, item.position);
                try std.testing.expectEqualStrings(want[0], item.value.hosted_call.description.?.slice());
                try std.testing.expectEqual(want[1], item.value.hosted_call.code);
                calls += 1;
            };
            try std.testing.expectEqual(@as(usize, 3), calls);
            try std.testing.expectError(error.ContentNotFound, storage.openActivityContent(&.{ .session = request.session, .position = page.items[1].position, .ordinal = 0 }));
        }
    }.run);
}

/// The WITH of a fixture INSERT over `value` 1 through `?1`. It goes after
/// the INSERT's column list, the one place MySQL and SQLite both take it.
const sequence_to_first_argument = "WITH RECURSIVE sequence(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM sequence WHERE value<?1) ";

test "an Activity page costs the same steps after 10 or 10,000 earlier rows, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var rounds: [2][2]u16 = undefined;
            for ([_]usize{ 10, 10_000 }, &rounds) |history, *cost| cost.* = try measure(case, history);
            try std.testing.expectEqual(rounds[0], rounds[1]);
        }

        /// `history` earlier units, a Message, its call item, the call's
        /// rejection and its Turn's outcome, then the same tail: a Message,
        /// twenty rejected calls and a stop. The rounds of the opening's
        /// page and of a forward page from the tail's first row.
        fn measure(engine: *store_testing.Case, history: usize) ![2]u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "cost-config");
            const start = try store_testing.queryU64(&storage, "SELECT next_position FROM session", .{});
            const content = try store_testing.queryU64(&storage, "SELECT instructions_content_id FROM session", .{});
            // Foreign keys are off: each history Message names its Turn
            // before the Turn row exists.
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,turn_id,admitted_at) " ++
                sequence_to_first_argument ++
                "SELECT value,?2,value+1000000,?4,?3+4*(value-1),value,1 FROM sequence", .{ history, session.slice(), start, content });
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,attempt_ordinal,resolution_code,resolved_at,tool_set_id,context_window,request_codec,request_codec_options) " ++
                sequence_to_first_argument ++
                "SELECT value,value,?2,1,value,?3+4*(value-1),0,1,'tool_proposals',1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session WHERE session_ref=?2),?4,(SELECT codec FROM session WHERE session_ref=?2),(SELECT codec_options FROM session WHERE session_ref=?2) FROM sequence", .{ history, session.slice(), start, @import("../../product_defaults.zig").unlisted_context_window });
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
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,sender_session_ref,sender_position) " ++
                sequence_to_first_argument ++
                "SELECT 1000+value,?2,value+1000000,?4,?3+value-1,1,?5,value FROM sequence", .{ history, session.slice(), start, content, peer.slice() });
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
            // Each tool group names its Turn before the Turn row exists. A
            // cancelled Turn needs no answer content.
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,attempt_ordinal,resolution_code,resolved_at,tool_set_id,context_window,request_codec,request_codec_options) " ++
                sequence_to_first_argument ++
                "SELECT 1000+value,1000+value,?2,1,1000+value,?3+3*(value-1),0,1,'tool_proposals',1,(SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session WHERE session_ref=?2),?4,(SELECT codec FROM session WHERE session_ref=?2),(SELECT codec_options FROM session WHERE session_ref=?2) FROM sequence", .{ history, session.slice(), start, @import("../../product_defaults.zig").unlisted_context_window });
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
            try std.testing.expectEqual(@as(u64, 0), page.call_activity.total);
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
            // The waiting Messages have no commands.
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at) " ++
                sequence_to_first_argument ++
                "SELECT 1000+value,?2,value+1000000,?4,?3+value-1,1 FROM sequence", .{ history, session.slice(), start, content });
            try store_testing.exec(&storage, "UPDATE session SET next_position=next_position+?1 WHERE session_ref=?2", .{ history, session.slice() });
            try store_core.reloadIdentitiesForTesting(&storage);
            try submitTestMessage(&storage, &tmp, "waiting-newest", "newest", session.slice(), "newest");
            var request: protocol.ActivityPage = .{ .direction = .backward, .kinds = .initOne(.admission), .limit = 1 };
            try request.session.set(session.slice());
            const counter = TwinRounds.start(&storage);
            const page = try store_core.activityPageForTesting(&storage, request);
            const taken = counter.taken();
            try std.testing.expect(page.count == 1 and page.items[0].value.admission.state == .queued and page.more);
            try std.testing.expectEqual(@as(u64, 0), page.queued.count);
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
            // A creation is no change.
            try std.testing.expectEqual(@as(usize, 0), (try store_core.activityPageForTesting(&storage, request)).count);
            try submitTestMessage(&storage, &tmp, "change-before", "change-before", session.slice(), "before");
            var change = try completeConfiguration("change-mode-label", session.slice(), workspace, "model-a");
            change.configuration.permission_mode.state = .value;
            // The default is bypass.
            try change.configuration.permission_mode.value.set("ask");
            change.configuration.label.state = .value;
            try change.configuration.label.value.set("renamed");
            try std.testing.expect(try storage.configure(&change, .{}) == .accepted);
            // A revision that changes nothing writes no row.
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
            // The rows sit between the Messages admitted before and after.
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
            // Backward from the end, the same rows come in reverse.
            request.direction = .backward;
            const backward = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 2), backward.count);
            try std.testing.expectEqual(protocol.SessionField.label, backward.items[0].value.session_changed.field);
            try std.testing.expect(!storage.isFenced());
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
                // Core built-ins need no Permission Decision; Bash and MCP do.
                try std.testing.expectEqual(@as(usize, if (mcp or bash) 2 else 1), own.count);
                if (mcp or bash) {
                    const approval = own.items[1].value.approval_requested;
                    try std.testing.expectEqualDeep(call.description, approval.description);
                    try std.testing.expectEqualDeep(call.tool, approval.tool);
                    try std.testing.expectEqualDeep(call.server, approval.server);
                    try expectActivityArguments(&storage, child, own.items[1], arguments);
                    try std.testing.expect(try storage.deliverSessionForward((try storage.nextCoreWork()).?.forward, .{}));
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
            // Two distinct model rows decode beside retained call/approval state.
            // Repeat in reverse to exercise reused slots and optional text fields.
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
