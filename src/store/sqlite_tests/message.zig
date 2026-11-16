//! Message SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const content_domain = @import("../domain/content.zig");
const historical_domain = @import("../domain/historical.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const ContentReader = content_domain.ContentReader;
const HistoricalReader = historical_domain.HistoricalReader;
const HistoricalView = historical_domain.HistoricalView;
const TestingAnswerPart = store_testing.TestingAnswerPart;
const answerTestTurn = store_testing.answerTestTurn;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const completeMessage = store_testing.completeMessage;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCommits = tests.TestingCommits;
const TestingHistoryCursor = tests.TestingHistoryCursor;
const renderTestingEntry = tests.renderTestingEntry;
const testingStore = store_testing.testingSqliteStore;
const ConstraintProbe = shared_fixtures.ConstraintProbe;
const probeConstraint = shared_fixtures.probeConstraint;

test "message admissions remain queued in order and retain bounded canonical content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "", workspace, "model-a");
    const created_session_0_reply = try storage.configure(&configuration, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;

    const first_text = "first message\n" ++ @as([700 * 6]u8, @bitCast(@as([700][6]u8, @splat("abcdef".*)))) ++ "🙂";
    const first_file = try tmp.dir.createFile(std.testing.io, "first-message", .{ .read = true });
    try first_file.writeStreamingAll(std.testing.io, first_text);
    try first_file.sync(std.testing.io);
    var first = try completeMessage("message-1", created_session_0.slice(), first_file, first_text);
    defer first.removeTemporaryContent(std.testing.io) catch unreachable;
    const before = try sqlite.pragmaInt(storage.sqliteDatabase(), "SELECT unixepoch()");
    var commits: TestingCommits = .{};
    const first_reply = storage.submitMessageWithModel(&first, commits.callback(), .{});
    try std.testing.expectEqual(@as(usize, 1), commits.count);
    try std.testing.expect(commits.calls[0].session.eql(created_session_0.slice()));
    try std.testing.expectEqual(@as(u64, 1), commits.calls[0].admission_id);
    try std.testing.expect(!commits.calls[0].from_peer);
    try std.testing.expect(first_reply == .accepted);
    try std.testing.expect(!first_reply.accepted.replayed);
    try std.testing.expectEqual(@as(u64, 1), first_reply.accepted.admission_id);

    const second_text = "second";
    const second_file = try tmp.dir.createFile(std.testing.io, "second-message", .{ .read = true });
    try second_file.writeStreamingAll(std.testing.io, second_text);
    try second_file.sync(std.testing.io);
    var second = try completeMessage("message-2", created_session_0.slice(), second_file, second_text);
    defer second.removeTemporaryContent(std.testing.io) catch unreachable;
    const second_reply = storage.submitMessageWithModel(&second, null, .{});
    try std.testing.expect(second_reply == .accepted);
    try std.testing.expect(first_reply.accepted.admission_id < second_reply.accepted.admission_id);
    // The Host stamps each admission with its wall clock, to the second.
    const after = try sqlite.pragmaInt(storage.sqliteDatabase(), "SELECT unixepoch()");
    const stamped = try sqlite.pragmaInt(storage.sqliteDatabase(), "SELECT admitted_at FROM message_admission WHERE admission_id=1");
    try std.testing.expect(before <= stamped and stamped <= after);
    // A replayed or restarted admission keeps the time it was admitted at.
    try store_testing.sqlite_only.exec(&storage, "UPDATE message_admission SET admitted_at=1000 WHERE admission_id=1", .{});

    const replay = storage.submitMessageWithModel(&first, commits.callback(), .{});
    // A replayed admission installs nothing.
    try std.testing.expectEqual(@as(usize, 1), commits.count);
    try std.testing.expect(replay == .accepted);
    try std.testing.expect(replay.accepted.replayed);
    try std.testing.expectEqual(first_reply.accepted.admission_id, replay.accepted.admission_id);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(first_text), &replay.accepted.content.digest);

    const session = try storage.inspectSessionForTesting(created_session_0.slice());
    try std.testing.expectEqual(@as(u64, 2), session.pending_messages);
    const observed = try store_testing.observeCommandForTesting(&storage, "message-1");
    try std.testing.expect(observed.status == .accepted);
    try std.testing.expect(observed.kind == .message);
    try std.testing.expect(observed.kind.message != null);
    const accepted_observation = observed.kind.message.?.queue.?;
    try std.testing.expectEqual(first_reply.accepted.admission_id, accepted_observation.admission_id);
    try std.testing.expect(accepted_observation.state == .queued);

    var reader: ContentReader = undefined;
    reader.open(try storage.openContent(observed.kind.message.?.content));
    var actual: [first_text.len]u8 = undefined;
    var offset: usize = 0;
    while (offset < actual.len) {
        const count = try reader.read(offset, actual[offset..@min(actual.len, offset + 31)]);
        try std.testing.expect(count != 0);
        offset += count;
    }
    reader.close();
    try std.testing.expectEqualSlices(u8, first_text, &actual);

    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const restarted = try store_testing.observeCommandForTesting(&storage, "message-1");
    try std.testing.expectEqual(first_reply.accepted.admission_id, restarted.kind.message.?.queue.?.admission_id);
    try std.testing.expectEqual(@as(u64, 2), (try storage.inspectSessionForTesting(created_session_0.slice())).pending_messages);
    try std.testing.expectEqual(@as(u32, 1000), try sqlite.pragmaInt(storage.sqliteDatabase(), "SELECT admitted_at FROM message_admission WHERE admission_id=1"));
}

test "a message's text is stored once and its parts replay as lengths of it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "text-once-config");
    const answer = [_]TestingAnswerPart{ .{ .encoded = "one ", .decoded = "one " }, .{ .encoded = "", .decoded = "" }, .{ .encoded = "tw\\u00f6", .decoded = "tw\u{f6}" } };
    try answerTestTurn(&storage, &tmp, session.slice(), "text-once", &answer);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM content WHERE payload=CAST('one tw\u{f6}' AS BLOB) AND private=0", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM content WHERE payload IN (CAST('one ' AS BLOB),CAST('tw\u{f6}' AS BLOB))", .{}));
    try std.testing.expectEqual(@as(u64, 3), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_output_part WHERE text_content_id IS NULL", .{}));
    try std.testing.expectEqual(@as(u64, 4 + 0 + 4), try store_testing.sqlite_only.queryU64(&storage, "SELECT sum(text_length) FROM model_output_part", .{}));
    try std.testing.expectEqual(try store_testing.sqlite_only.queryU64(&storage, "SELECT content_id FROM conversation_entry WHERE entry_kind=3", .{}), try store_testing.sqlite_only.queryU64(&storage, "SELECT message_content_id FROM model_output_item WHERE item_kind=2", .{}));
    // Each part kind holds exactly its text shape, and a message names its text.
    for ([_]struct { ConstraintProbe, [:0]const u8 }{
        .{ .check_violation, "UPDATE model_output_part SET text_length=NULL WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_part SET text_content_id=extras_content_id WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_part SET text_length=-1 WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_part SET part_kind=0 WHERE part_ordinal=0" },
        .{ .accepted, "UPDATE model_output_part SET part_kind=0,text_length=NULL WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_part SET part_kind=3,part_array=2,text_length=NULL WHERE part_ordinal=0" },
        .{ .accepted, "UPDATE model_output_part SET part_kind=3,part_array=2,text_length=NULL,text_content_id=extras_content_id WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_part SET part_kind=4,text_content_id=extras_content_id WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_item SET message_content_id=NULL WHERE item_kind=2" },
        .{ .check_violation, "UPDATE model_output_item SET item_kind=1,phase=0 WHERE item_kind=2" },
    }) |case| try std.testing.expectEqual(case[0], try probeConstraint(storage.sqliteDatabase(), case[1]));
    try submitTestMessage(&storage, &tmp, "text-once-next", "text-once-next", session.slice(), "next");
    const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var view: HistoricalView = undefined;
    storage.openHistoricalView(next, &view);
    defer view.close();
    var cursor: TestingHistoryCursor = .{};
    var bytes: [512]u8 = undefined;
    while (try cursor.next(&view)) |entry| {
        if (entry.kind != .provider_output) continue;
        try std.testing.expectEqualStrings("message{\"id\":\"m\"}|content.output_text=one |content.output_text=|content.output_text=tw\u{f6}", try renderTestingEntry(&view, entry, &bytes));
        break;
    } else return error.MissingMessage;
    try std.testing.expect(!storage.isFenced());
}

test "a large message's parts read only their own ranges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "large-parts-config");
    // Many small parts before one large one: each small part's reader must
    // not read ahead into the rest of the text.
    const large = try std.testing.allocator.alloc(u8, 1024 * 1024 + 4096);
    defer std.testing.allocator.free(large);
    @memset(large, 'a');
    var answer: [65]TestingAnswerPart = undefined;
    for (answer[0..64]) |*part| part.* = .{ .encoded = "x", .decoded = "x" };
    answer[64] = .{ .encoded = large, .decoded = large };
    try answerTestTurn(&storage, &tmp, session.slice(), "large-parts", &answer);
    try submitTestMessage(&storage, &tmp, "large-parts-next", "large-parts-next", session.slice(), "next");
    const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var view: HistoricalView = undefined;
    storage.openHistoricalView(next, &view);
    defer view.close();
    var cursor: TestingHistoryCursor = .{};
    while (try cursor.next(&view)) |entry| {
        if (entry.kind != .provider_output) continue;
        _ = try view.openOutput(entry.position);
        const before = storage.testing_content_work.blob.load(.monotonic);
        var window: [4096]u8 = undefined;
        var text_bytes: u64 = 0;
        while (try view.nextOutputPart()) |part| {
            const text = part.text orelse continue;
            var reader: HistoricalReader = undefined;
            try view.openContent(text, &reader);
            defer reader.close();
            var offset: u64 = 0;
            while (true) {
                const count = try reader.read(offset, &window);
                if (count == 0) break;
                offset += count;
            }
            text_bytes += offset;
        }
        try std.testing.expectEqual(@as(u64, 64 + large.len), text_bytes);
        try std.testing.expectEqual(text_bytes, storage.testing_content_work.blob.load(.monotonic) - before);
        break;
    } else return error.MissingMessage;
    try std.testing.expect(!storage.isFenced());
}
