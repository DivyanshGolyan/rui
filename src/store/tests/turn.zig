//! Turn Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const store_testing = @import("../testing.zig");
const turn_domain = @import("../domain/turn.zig");
const TurnOutcome = turn_domain.TurnOutcome;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const settleMessagesForTesting = shared_fixtures.settleMessagesForTesting;

test "each saved outcome names one feed ending" {
    const cases = .{
        .{ turn_domain.TurnOutcome{ .completed = 1 }, false, protocol.TurnEnding.done },
        .{ turn_domain.TurnOutcome{ .cancelled = {} }, true, protocol.TurnEnding.stopped },
        .{ turn_domain.TurnOutcome{ .cancelled = {} }, false, protocol.TurnEnding.interrupted },
        .{ turn_domain.TurnOutcome{ .retry_exhausted = null }, false, protocol.TurnEnding.provider_unavailable },
        .{ turn_domain.TurnOutcome{ .resource_exceeded = 2 }, false, protocol.TurnEnding.context_full },
        .{ turn_domain.TurnOutcome{ .failed = .{ .code = "provider_policy", .report = 3 } }, false, protocol.TurnEnding.provider_refused },
        .{ turn_domain.TurnOutcome{ .failed = .{ .code = "provider_http_400", .report = null } }, false, protocol.TurnEnding.provider_refused },
        .{ turn_domain.TurnOutcome{ .failed = .{ .code = "provider_api_key_rejected", .report = null } }, false, protocol.TurnEnding.provider_refused },
        .{ turn_domain.TurnOutcome{ .failed = .{ .code = "provider_tls_verification_failed", .report = null } }, false, protocol.TurnEnding.provider_unavailable },
        // A stop that selected a Turn a failure ended first leaves its ending.
        .{ turn_domain.TurnOutcome{ .failed = .{ .code = "malformed_provider_output", .report = null } }, true, protocol.TurnEnding.failed },
    };
    inline for (cases) |case| try std.testing.expectEqual(case[2], case[0].ending(case[1]));
}

test "while new Turns are held, waiting input joins only an open Turn" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const open = try configureTestSession(&storage, "held-open-config");
            try submitTestMessage(&storage, &tmp, "held-first", "held-first-key", open.slice(), "first");
            const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            // A Message that arrives while the answer is being made keeps its Turn open.
            try submitTestMessage(&storage, &tmp, "held-second", "held-second-key", open.slice(), "second");
            try settleMessagesForTesting(&storage, &tmp, first, 1, false, null);
            const idle = try configureTestSession(&storage, "held-idle-config");
            try submitTestMessage(&storage, &tmp, "held-new", "held-new-key", idle.slice(), "new");
            // Held: the open Turn takes its input; the idle Session starts nothing.
            const joined = (try storage.admitModelAttempt(.open_turn_message, .{})).?.permit.binding;
            try std.testing.expectEqual(first.turn_id, joined.turn_id);
            try settleMessagesForTesting(&storage, &tmp, joined, 1, false, null);
            try std.testing.expect((try storage.admitModelAttempt(.open_turn_message, .{})) == null);
            // Resumed: the held Message starts its Turn.
            const started = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            try std.testing.expect(started.turn_id != first.turn_id);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "the final row is the answer phase selection picked, even when later text repeats it or it is blank" {
    try store_testing.forEachEngine(struct {
        fn run(store_case: *store_testing.Case) !void {
            const final_then_commentary = [_][]const u8{
                "{\"type\":\"message\",\"id\":\"m0\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"same\"}]}",
                "{\"type\":\"message\",\"id\":\"m1\",\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"same\"}]}",
            };
            const blank = [_][]const u8{
                "{\"type\":\"message\",\"id\":\"m0\",\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"working\"}]}",
                "{\"type\":\"message\",\"id\":\"m1\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"  \"}]}",
            };
            const Case = struct { items: []const []const u8, selected: u64, answer: []const u8 };
            for ([_]Case{
                .{ .items = &final_then_commentary, .selected = 0, .answer = "same" },
                // A blank answer saves as empty content; its row keeps the blank text.
                .{ .items = &blank, .selected = 1, .answer = "" },
            }) |case| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(store_case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "selected-config");
                try submitTestMessage(&storage, &tmp, "selected-input", "selected-key", session.slice(), "answer");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try store_testing.settleSelectedItemsForTesting(&storage, &tmp, binding, case.items, case.selected, case.answer);
                var request: protocol.ActivityPage = .{};
                try request.session.set(session.slice());
                request.kinds = .initMany(&.{ .assistant, .turn_ended });
                const page = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(@as(usize, 3), page.count);
                try std.testing.expectEqual(protocol.TurnEnding.done, page.items[2].value.turn_ended.ending);
                for (page.items[0..2], 0..) |item, index| try std.testing.expectEqual(index == case.selected, item.value.assistant.final);
            }
        }
    }.run);
}

test "a done Turn marks its answer final once its ending is within the page" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // Three messages, the last the answer; with one text repeated, only
            // the answer itself, the last, is final.
            for ([_]bool{ false, true }) |same_text| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "final-config");
                try submitTestMessage(&storage, &tmp, "final-input", "final-key", session.slice(), "answer");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleMessagesForTesting(&storage, &tmp, binding, 3, same_text, null);
                var request: protocol.ActivityPage = .{};
                try request.session.set(session.slice());
                request.kinds = .initMany(&.{ .assistant, .turn_ended });
                const page = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(@as(usize, 4), page.count);
                for (page.items[0..3], 0..) |item, index| try std.testing.expectEqual(index == 2, item.value.assistant.final);
                try std.testing.expectEqual(protocol.TurnEnding.done, page.items[3].value.turn_ended.ending);
                // A page that ends before the ending marks nothing final yet.
                request.end = page.items[2].position;
                const earlier = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(@as(usize, 3), earlier.count);
                for (earlier.items[0..3]) |item| try std.testing.expect(!item.value.assistant.final);
            }
        }
    }.run);
}

test "saved Turn outcomes read back as the outcome that closed the Turn" {
    const Saved = struct { code: []const u8, content_id: ?i64, tag: TurnOutcome.Tag };
    // The on-disk codes are the Store format; readers branch on the tag.
    const saved = [_]Saved{
        .{ .code = "completed", .content_id = 7, .tag = .completed },
        .{ .code = "cancelled", .content_id = null, .tag = .cancelled },
        .{ .code = "retry_exhausted", .content_id = null, .tag = .retry_exhausted },
        .{ .code = "ResourceExceeded", .content_id = null, .tag = .resource_exceeded },
        .{ .code = "ResourceExceeded", .content_id = 10, .tag = .resource_exceeded },
        .{ .code = "retry_exhausted", .content_id = 8, .tag = .retry_exhausted },
        .{ .code = "provider_http_401", .content_id = null, .tag = .failed },
        .{ .code = "provider_policy", .content_id = 9, .tag = .failed },
    };
    for (saved) |row| {
        const outcome = try TurnOutcome.decode(row.code, row.content_id);
        try std.testing.expectEqual(row.tag, std.meta.activeTag(outcome));
        try std.testing.expectEqualStrings(row.code, outcome.code());
        try std.testing.expectEqual(row.content_id, outcome.content());
    }
    try std.testing.expectEqual(@as(i64, 7), (try TurnOutcome.decode("completed", 7)).completed);
    // A completed Turn saves its answer and a failure may save its report;
    // a cancelled one saves no content, and every outcome saves a code.
    try std.testing.expectError(error.CorruptStore, TurnOutcome.decode("completed", null));
    try std.testing.expectError(error.CorruptStore, TurnOutcome.decode("cancelled", 7));
    try std.testing.expectError(error.CorruptStore, TurnOutcome.decode("", null));
}
