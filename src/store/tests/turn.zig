const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const store_testing = @import("../testing.zig");
const turn_domain = @import("../domain/turn.zig");
const old_format = @import("../history.zig");
const failure_report = @import("../../failure_report.zig");
const TurnOutcome = turn_domain.TurnOutcome;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const settleMessagesForTesting = shared_fixtures.settleMessagesForTesting;

test "each saved outcome names one feed ending" {
    const cases = .{
        .{ turn_domain.TurnOutcome{ .completed = 1 }, false, protocol.TurnEnding.done },
        .{ turn_domain.TurnOutcome{ .cancelled = {} }, true, protocol.TurnEnding.stopped },
        .{ turn_domain.TurnOutcome{ .cancelled = {} }, false, protocol.TurnEnding.interrupted },
        .{ turn_domain.TurnOutcome{ .retry_exhausted = {} }, false, protocol.TurnEnding.provider_unavailable },
        .{ turn_domain.TurnOutcome{ .resource_exceeded = {} }, false, protocol.TurnEnding.context_full },
        .{ turn_domain.TurnOutcome{ .failed = "provider_policy" }, false, protocol.TurnEnding.provider_refused },
        .{ turn_domain.TurnOutcome{ .failed = "provider_http_400" }, false, protocol.TurnEnding.provider_refused },
        .{ turn_domain.TurnOutcome{ .failed = "provider_quota" }, false, protocol.TurnEnding.out_of_quota },
        .{ turn_domain.TurnOutcome{ .failed = "provider_plan" }, false, protocol.TurnEnding.provider_refused },
        .{ turn_domain.TurnOutcome{ .failed = "provider_api_key_rejected" }, false, protocol.TurnEnding.provider_refused },
        .{ turn_domain.TurnOutcome{ .failed = "provider_tls_verification_failed" }, false, protocol.TurnEnding.provider_unavailable },
        .{ turn_domain.TurnOutcome{ .failed = "malformed_provider_output" }, true, protocol.TurnEnding.failed },
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
            try submitTestMessage(&storage, &tmp, "held-second", "held-second-key", open.slice(), "second");
            try settleMessagesForTesting(&storage, &tmp, first, 1, false, null);
            const idle = try configureTestSession(&storage, "held-idle-config");
            try submitTestMessage(&storage, &tmp, "held-new", "held-new-key", idle.slice(), "new");
            const joined = (try storage.admitModelAttempt(.open_turn_message, .{})).?.permit.binding;
            try std.testing.expectEqual(first.turn_id, joined.turn_id);
            try settleMessagesForTesting(&storage, &tmp, joined, 1, false, null);
            try std.testing.expect((try storage.admitModelAttempt(.open_turn_message, .{})) == null);
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
                request.end = page.items[2].position;
                const earlier = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(@as(usize, 3), earlier.count);
                for (earlier.items[0..3]) |item| try std.testing.expect(!item.value.assistant.final);
            }
        }
    }.run);
}

test "a backward Activity read of the assistant kind with a limit of one is the newest answer, whatever follows it" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |later_message| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "newest-config");
                try submitTestMessage(&storage, &tmp, "newest-input", "newest-key", session.slice(), "answer");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleMessagesForTesting(&storage, &tmp, binding, 3, false, null);
                if (later_message) try submitTestMessage(&storage, &tmp, "later-input", "later-key", session.slice(), "a later message");
                var request: protocol.ActivityPage = .{};
                try request.session.set(session.slice());
                request.kinds = .initOne(.assistant);
                const all = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(@as(usize, 3), all.count);
                request.direction = .backward;
                request.limit = 1;
                const newest = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(@as(usize, 1), newest.count);
                try std.testing.expectEqual(all.items[2].position, newest.items[0].position);
                try std.testing.expectEqual(all.items[2].ordinal, newest.items[0].ordinal);
                try std.testing.expectEqualDeep(all.items[2].value.assistant.content, newest.items[0].value.assistant.content);
            }
        }
    }.run);
}

test "saved Turn outcomes read back as the outcome that closed the Turn" {
    const Saved = struct { code: []const u8, content_id: ?i64, tag: TurnOutcome.Tag };
    const saved = [_]Saved{
        .{ .code = "completed", .content_id = 7, .tag = .completed },
        .{ .code = "cancelled", .content_id = null, .tag = .cancelled },
        .{ .code = "retry_exhausted", .content_id = null, .tag = .retry_exhausted },
        .{ .code = "ResourceExceeded", .content_id = null, .tag = .resource_exceeded },
        .{ .code = "provider_http_401", .content_id = null, .tag = .failed },
    };
    for (saved) |row| {
        const outcome = try TurnOutcome.decode(row.code, row.content_id);
        try std.testing.expectEqual(row.tag, std.meta.activeTag(outcome));
        try std.testing.expectEqualStrings(row.code, outcome.code());
        try std.testing.expectEqual(row.content_id, outcome.content());
    }
    try std.testing.expectEqual(@as(i64, 7), (try TurnOutcome.decode("completed", 7)).completed);
    try std.testing.expectError(error.CorruptStore, TurnOutcome.decode("completed", null));
    try std.testing.expectError(error.CorruptStore, TurnOutcome.decode("", null));
    // Only a completed Turn saves content: a Turn that ended any other way keeps its words as a Report, so a content row on it is corrupt.
    for ([_][]const u8{ "cancelled", "retry_exhausted", "ResourceExceeded", "provider_policy" }) |code| {
        try std.testing.expectError(error.CorruptStore, TurnOutcome.decode(code, 7));
    }
}

/// Format 98 rows for the step to 99: failed Turns whose saved line the step must move into a message, cut or whole, beside a completed one and some with no report.
/// Contents 200 to 202 are lines of 30 bytes, one that ends in a cut mark, and a bare mark.
fn failureLines98() old_format.Start {
    return .{ .format = 98, .sql = .{ .per_engine = .{
        .sqlite = "INSERT INTO content(content_id,digest,byte_length,private,payload) VALUES(200,X'0000000000000000000000000000000000000000000000000000000000000000',30,0,X'70726f76696465725f687474705f3430303a206261642072657175657374'),(201,X'0000000000000000000000000000000000000000000000000000000000000000',31,0,X'70726f76696465725f687474705f3430303a207472756e6361746564e280a6'),(202,X'0000000000000000000000000000000000000000000000000000000000000000',3,0,X'e280a6');" ++
            "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id,outcome_position,outcome_at,continuation_operation_id) VALUES(3,'d8mv7p',1,1,1,'provider_http_400',200,20,1793781720,NULL),(4,'d8mv7p',1,1,1,'retry_exhausted',201,21,1793781720,NULL),(5,'d8mv7p',1,1,1,'ResourceExceeded',202,22,1793781720,NULL),(6,'d8mv7p',1,1,1,'retry_exhausted',NULL,23,1793781720,NULL),(7,'d8mv7p',1,1,1,'cancelled',NULL,24,1793781720,NULL);",
        .mysql = "INSERT INTO content(content_id,digest,byte_length,private) VALUES(200,X'0000000000000000000000000000000000000000000000000000000000000000',30,0),(201,X'0000000000000000000000000000000000000000000000000000000000000000',31,0),(202,X'0000000000000000000000000000000000000000000000000000000000000000',3,0);" ++
            "INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES(200,0,X'70726f76696465725f687474705f3430303a206261642072657175657374'),(201,0,X'70726f76696465725f687474705f3430303a207472756e6361746564e280a6'),(202,0,X'e280a6');" ++
            "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id,outcome_position,outcome_at,continuation_operation_id) VALUES(3,'d8mv7p',1,1,1,'provider_http_400',200,20,1793781720,NULL),(4,'d8mv7p',1,1,1,'retry_exhausted',201,21,1793781720,NULL),(5,'d8mv7p',1,1,1,'ResourceExceeded',202,22,1793781720,NULL),(6,'d8mv7p',1,1,1,'retry_exhausted',NULL,23,1793781720,NULL),(7,'d8mv7p',1,1,1,'cancelled',NULL,24,1793781720,NULL);",
    } } };
}

test "INS-22 the step to format 99 moves a saved failure line into the message, takes its cut mark into the flag and drops the content link" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            const start = comptime failureLines98();
            try old_format.openAt(case, &storage, &tmp, std.testing.io, &start);
            defer storage.close() catch unreachable;
            const Row = struct { turn: u64, message: ?[]const u8, cut: u64 };
            const rows = [_]Row{
                // A whole line is the message.
                .{ .turn = 3, .message = "provider_http_400: bad request", .cut = 0 },
                // A line that ended in the mark loses it to the flag.
                .{ .turn = 4, .message = "provider_http_400: truncated", .cut = 1 },
                // A line that is only the mark has no text to cut: it stays as it was said.
                .{ .turn = 5, .message = "…", .cut = 0 },
                // A Turn that saved no line has no report, and a completed or cancelled one keeps none.
                .{ .turn = 6, .message = null, .cut = 0 },
                .{ .turn = 7, .message = null, .cut = 0 },
                .{ .turn = 1, .message = null, .cut = 0 },
            };
            for (rows) |row| {
                const where = "turn_id=?1 AND outcome_report_code IS NULL AND outcome_report_code_cut=0 AND outcome_report_message_cut=?2";
                if (row.message) |message| {
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM turn WHERE " ++ where ++ " AND outcome_report_message=?3", .{ row.turn, row.cut, message }));
                } else {
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM turn WHERE " ++ where ++ " AND outcome_report_message IS NULL", .{ row.turn, row.cut }));
                }
            }
            // Only the completed Turn still names content: its answer.
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM turn WHERE outcome_content_id IS NOT NULL", .{}));
            try std.testing.expectEqual(@as(u64, 5), try store_testing.queryU64(&storage, "SELECT outcome_content_id FROM turn WHERE turn_id=1", .{}));
        }
    }.run);
}

fn repeat(comptime unit: []const u8, comptime count: usize) *const [unit.len * count]u8 {
    const filled = comptime blk: {
        var out: [unit.len * count]u8 = undefined;
        for (0..count) |index| @memcpy(out[index * unit.len ..][0..unit.len], unit);
        break :blk out;
    };
    return &filled;
}

/// What reading a provider's code and message leaves, the way the decoder builds the parts.
fn readReport(code: []const u8, message: []const u8) failure_report.Report {
    var report: failure_report.Report = .{};
    for ([_]*failure_report.Part{ &report.code, &report.message }, [_][]const u8{ code, message }) |part, bytes| {
        _ = part.append(bytes);
        part.finish();
    }
    return report;
}

test "INS-22 a Turn keeps a provider failure as its code and message with their cut flags, over every pair of parts" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            // Absent, short, exactly at the bound, over it, and cut inside a scalar (an odd count of bytes before two-byte scalars).
            const parts = [_][]const u8{ "", "c", repeat("x", 256), repeat("x", 300), "x" ++ repeat("é", 200), "a\nb\x7f" };
            var index: usize = 0;
            for (parts) |code| for (parts) |message| {
                var key: [32]u8 = undefined;
                const session = try configureTestSession(&storage, try std.fmt.bufPrint(&key, "report-config-{d}", .{index}));
                const input = try std.fmt.bufPrint(&key, "report-input-{d}", .{index});
                try submitTestMessage(&storage, &tmp, input, input, session.slice(), "work");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const report = readReport(code, message);
                try storage.settleModelAttemptFailure(binding, .{ .correlated = .{ .code = "provider_http_400", .request_id = .{}, .report = report } }, .ordinary, .{});
                const request: protocol.ActivityPage = .{ .session = session, .kinds = .initOne(.turn_ended) };
                const page = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(@as(usize, 1), page.count);
                const ended = page.items[0].value.turn_ended;
                try std.testing.expect(ended.content == null);
                try std.testing.expectEqualStrings("provider_http_400", ended.code.slice());
                try std.testing.expectEqualStrings(report.code.text.slice(), ended.report.code.text.slice());
                try std.testing.expectEqualStrings(report.message.text.slice(), ended.report.message.text.slice());
                try std.testing.expectEqual(report.code.cut, ended.report.code.cut);
                try std.testing.expectEqual(report.message.cut, ended.report.message.cut);
                try std.testing.expectEqual(report.isEmpty(), ended.report.isEmpty());
                // The Turn keeps no content for it.
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM turn WHERE session_ref=?1 AND outcome_content_id IS NOT NULL", .{session.slice()}));
                index += 1;
            };
        }
    }.run);
}
