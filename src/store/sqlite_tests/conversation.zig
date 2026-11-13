//! Conversation SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const content_domain = @import("../domain/content.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const ContentReader = content_domain.ContentReader;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const testingPublicProjection = store_testing.testingPublicProjection;
const TestingCall = tests.TestingCall;
const configureTestSessionAsk = tests.configureTestSessionAsk;
const settleCallsForTesting = tests.settleCallsForTesting;
const settleTwoActionsForTesting = tests.settleTwoActionsForTesting;
const testingSessionReportWithProfile = tests.testingSessionReportWithProfile;
const testingStore = store_testing.testingSqliteStore;
const busyStatements = shared_fixtures.busyStatements;

test "public content SQL failure fences Store instead of reporting absence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "public-read-config");
    try submitTestMessage(&storage, &tmp, "public-read-text", "public-read-key", session.slice(), "text");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    var request: protocol.ConversationContent = .{ .position = 1 };
    try request.session.set(session.slice());
    const Interrupt = struct {
        fn progress(_: ?*anyopaque) callconv(.c) c_int {
            return 1;
        }
    };
    c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, Interrupt.progress, null);
    defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
    // The shared provenance query is interrupted during preparation, before
    // identity lookup can step. Either phase must retain the public fence.
    try std.testing.expectError(error.StatementPrepareFailed, storage.openPublicConversationContent(&request));
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.openPublicConversationContent(&request));
}

test "public content SQLite step failure fences after successful preparation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "step-config");
    try submitTestMessage(&storage, &tmp, "step-input", "step-key", session.slice(), "step text");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    var request = protocol.ConversationContent{ .position = 1 };
    try request.session.set(session.slice());
    try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&.{ .session = request.session, .position = 999 }));
    try std.testing.expect(!storage.isFenced());
    const Interrupt = struct {
        database: *c.sqlite3,
        interrupted_step: bool = false,

        fn progress(context: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            var statement = c.sqlite3_next_stmt(self.database, null);
            while (statement != null) : (statement = c.sqlite3_next_stmt(self.database, statement)) {
                // Preparation may also invoke progress. Interrupt only a
                // statement that has actually entered sqlite3_step.
                if (c.sqlite3_stmt_busy(statement) != 0) {
                    self.interrupted_step = true;
                    return 1;
                }
            }
            return 0;
        }
    };
    var interrupt = Interrupt{ .database = storage.sqliteDatabase() };
    c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, Interrupt.progress, &interrupt);
    defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
    try std.testing.expectError(error.ConversationReadFailed, storage.openPublicConversationContent(&request));
    try std.testing.expect(interrupt.interrupted_step);
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.openPublicConversationContent(&request));
}

const TestingPublicReadRoute = enum { page, content, cursor };

fn testingOrdinaryPublicCorruption(route: TestingPublicReadRoute, foreign_turn: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "ordinary-config");
    try submitTestMessage(&storage, &tmp, "ordinary-input", "ordinary-key", session.slice(), "public input");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    var request = protocol.ConversationPage{};
    request.session = session;
    const valid = try store_core.publicConversationPageForTesting(&storage, request);
    try std.testing.expectEqual(@as(usize, 1), valid.count);
    try std.testing.expect(valid.items[0].kind == .user);
    if (foreign_turn) {
        const foreign_session = try configureTestSession(&storage, "foreign-config");
        try submitTestMessage(&storage, &tmp, "foreign-input", "foreign-key", foreign_session.slice(), "other input");
        _ = (try storage.admitNextModelAttempt(.{})).?;
        const corrupt = try sqlite.prepare(storage.sqliteDatabase(), "UPDATE conversation_entry SET turn_id=(SELECT turn_id FROM turn WHERE session_ref=?1) WHERE session_ref=?2 AND entry_kind=1");
        defer _ = c.sqlite3_finalize(corrupt);
        try sqlite.bindText(corrupt, 1, foreign_session.slice());
        try sqlite.bindText(corrupt, 2, session.slice());
        try sqlite.expectDone(corrupt);
    } else {
        try store_testing.sqlite_only.exec(&storage, "UPDATE content SET private=1 WHERE content_id=(SELECT content_id FROM conversation_entry WHERE session_ref=?1 AND entry_kind=1)", .{session.slice()});
    }
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
    request.end = valid.end;
    if (route == .cursor) request.before_position = valid.items[0].position;
    const result: anyerror!void = if (route == .content)
        if (storage.openPublicConversationContent(&.{ .session = request.session, .position = valid.items[0].position })) |location| blk: {
            var reader: ContentReader = undefined;
            reader.open(location);
            reader.close();
            break :blk {};
        } else |err| err
    else if (store_core.publicConversationPageForTesting(&storage, request)) |_| {} else |err| err;
    try std.testing.expectError(error.CorruptStore, result);
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, store_core.publicConversationPageForTesting(&storage, request));
    try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
}

test "public ordinary private bytes and cursor fence" {
    try testingOrdinaryPublicCorruption(.content, false);
    try testingOrdinaryPublicCorruption(.cursor, false);
}

test "public ordinary private page fences" {
    try testingOrdinaryPublicCorruption(.page, false);
}

test "public foreign Turn bytes and cursor fence" {
    try testingOrdinaryPublicCorruption(.content, true);
    try testingOrdinaryPublicCorruption(.cursor, true);
}

test "public foreign Turn page fences" {
    try testingOrdinaryPublicCorruption(.page, true);
}

fn testingToolPublicCorruption(route: TestingPublicReadRoute, damage: enum { private, missing, sibling_ordinal, sibling_call_id, sibling_arguments }, target_sibling: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "tool-config");
    try submitTestMessage(&storage, &tmp, "tool-input", "tool-key", session.slice(), "run tool");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "sibling", .name = "other", .encoded_call_id = "sibling-call", .decoded_call_id = "sibling-call", .encoded_arguments = "[]", .decoded_arguments = "[]" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "tool-output", &calls);
    // Damaging the first rejection must leave the requested sibling healthy;
    // identical rejection bytes would deduplicate into one content identity.
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(DISTINCT rejection_content_id) FROM model_tool_call", .{}));
    var request = protocol.ConversationPage{};
    try request.session.set(session.slice());
    const valid = try store_core.publicConversationPageForTesting(&storage, request);
    try std.testing.expectEqual(@as(usize, 3), valid.count);
    const item = valid.items[if (target_sibling) 0 else 1];
    try std.testing.expect(item.kind == .tool_result and item.ordinal == (if (target_sibling) @as(u64, 2) else 1));
    {
        var reader: ContentReader = undefined;
        reader.open(try storage.openPublicConversationContent(&.{ .session = request.session, .position = item.position, .ordinal = item.ordinal }));
        defer reader.close();
        var bytes: [64]u8 = undefined;
        const count = try reader.read(0, &bytes);
        try std.testing.expectEqualStrings(if (target_sibling) "Unknown tool: other." else "Unknown tool: unknown.", bytes[0..count]);
    }
    // Keep counts, acceptance positions and results intact for sibling damage:
    // reading the healthy highest ordinal must validate the entire group.
    switch (damage) {
        .sibling_ordinal => try store_testing.sqlite_only.exec(&storage, "UPDATE model_tool_call SET item_ordinal=item_ordinal+1000 WHERE call_ordinal=0", .{}),
        .sibling_call_id => try store_testing.sqlite_only.exec(&storage, "UPDATE model_tool_call SET call_id_content_id=(SELECT name_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0", .{}),
        .sibling_arguments => try store_testing.sqlite_only.exec(&storage, "UPDATE model_tool_call SET arguments_content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0", .{}),
        .private => try store_testing.sqlite_only.exec(&storage, "UPDATE content SET private=1 WHERE content_id=(SELECT rejection_content_id FROM model_tool_call WHERE call_ordinal=0)", .{}),
        .missing => {
            try store_testing.sqlite_only.withoutForeignKeys(&storage, "DELETE FROM content WHERE content_id=(SELECT rejection_content_id FROM model_tool_call WHERE call_ordinal=0)", .{});
        },
    }
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
    request.end = item.position;
    if (route == .cursor) {
        request.before_position = item.position;
        request.before_ordinal = item.ordinal;
    }
    const result: anyerror!void = if (route == .content)
        if (storage.openPublicConversationContent(&.{ .session = request.session, .position = item.position, .ordinal = item.ordinal })) |location| blk: {
            var reader: ContentReader = undefined;
            reader.open(location);
            reader.close();
            break :blk {};
        } else |err| err
    else if (store_core.publicConversationPageForTesting(&storage, request)) |_| {} else |err| err;
    try std.testing.expectError(error.CorruptStore, result);
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, store_core.publicConversationPageForTesting(&storage, request));
    try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
}

test "public private tool bytes fence" {
    try testingToolPublicCorruption(.content, .private, false);
}

test "public private tool page fences" {
    try testingToolPublicCorruption(.page, .private, false);
}

test "public private tool cursor fences" {
    try testingToolPublicCorruption(.cursor, .private, false);
}

test "public completed tool group with missing exposed content fences" {
    try testingToolPublicCorruption(.page, .missing, false);
    try testingToolPublicCorruption(.content, .missing, false);
    try testingToolPublicCorruption(.cursor, .missing, false);
}

test "public completed tool group with corrupt sibling provenance fences" {
    for ([_]TestingPublicReadRoute{ .page, .cursor, .content }) |route| {
        try testingToolPublicCorruption(route, .sibling_ordinal, true);
        try testingToolPublicCorruption(route, .sibling_call_id, true);
        try testingToolPublicCorruption(route, .sibling_arguments, true);
        try testingToolPublicCorruption(route, .private, true);
        try testingToolPublicCorruption(route, .missing, true);
    }
}

test "public completed Action sibling corruption fences first Conversation read" {
    const faults = [_][:0]const u8{
        "UPDATE model_tool_call SET item_ordinal=item_ordinal+1000 WHERE call_ordinal=0",
        "UPDATE model_tool_call SET call_id_content_id=(SELECT name_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0",
        "UPDATE model_tool_call SET arguments_content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0",
        "UPDATE content SET private=1 WHERE content_id=(SELECT resolution_content_id FROM action_operation WHERE call_ordinal=0)",
        "DELETE FROM content WHERE content_id=(SELECT resolution_content_id FROM action_operation WHERE call_ordinal=0)",
    };
    for (faults) |fault| {
        for ([_]TestingPublicReadRoute{ .page, .cursor, .content }) |route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "message", session.slice(), "two tools");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "output");
            for ([_][]const u8{ "allow-first", "allow-second" }) |key| {
                const action_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT min(action_id) FROM action_operation WHERE resolution_code IS NULL", .{});
                var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
                try allow.key.set(key);
                try allow.session.set(session.slice());
                try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
                const action_binding = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
                _ = try storage.settleActionAttempt(action_binding, .succeeded, key, .{});
            }
            // Obtain only the immutable identity, not a traversal on another
            // public route that could accidentally supply validation authority.
            const position = try store_testing.sqlite_only.queryU64(&storage, "SELECT max(acceptance_position) FROM action_operation", .{});
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
            try sqlite.exec(storage.sqliteDatabase(), fault);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
            var request: protocol.ConversationPage = .{ .end = position };
            try request.session.set(session.slice());
            if (route == .cursor) {
                request.before_position = position;
                request.before_ordinal = 2;
            }
            const result: anyerror!void = if (route == .content)
                if (storage.openPublicConversationContent(&.{ .session = request.session, .position = position, .ordinal = 2 })) |value| blk: {
                    var reader: ContentReader = undefined;
                    reader.open(value);
                    reader.close();
                    break :blk {};
                } else |err| err
            else if (store_core.publicConversationPageForTesting(&storage, request)) |_| {} else |err| err;
            try std.testing.expectError(error.CorruptStore, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, store_core.publicConversationPageForTesting(&storage, request));
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
        }
    }
}

test "public assistant message provenance binds the exact accepted item" {
    const faults = [_][:0]const u8{
        "DELETE FROM conversation_entry WHERE entry_kind=3",
        "UPDATE conversation_entry SET source_item_ordinal=source_item_ordinal+1 WHERE entry_kind=3",
        "UPDATE conversation_entry SET content_id=(SELECT content_id FROM conversation_entry WHERE entry_kind=1) WHERE entry_kind=3",
        "UPDATE model_output_item SET message_content_id=(SELECT content_id FROM conversation_entry WHERE entry_kind=1) WHERE item_kind=2",
        "UPDATE model_output_item SET attempt_ordinal=attempt_ordinal+1 WHERE item_kind=2",
        "UPDATE content SET private=1 WHERE content_id=(SELECT message_content_id FROM model_output_item WHERE item_kind=2)",
    };
    for (faults) |fault| {
        for ([_]enum { page, bytes, activity, activity_bytes, full }{ .page, .bytes, .activity, .activity_bytes, .full }) |route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const request = try testingPublicProjection(&storage, &tmp, &.{.{ .encoded = "visible", .decoded = "visible" }});
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
            try sqlite.exec(storage.sqliteDatabase(), fault);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
            try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON");
            try storage.close();
            try testingStore(&storage, &tmp, std.testing.io);
            const result: anyerror!void = switch (route) {
                .page => if (store_core.publicConversationPageForTesting(&storage, .{ .session = request.session })) |_| {} else |err| err,
                .bytes => if (storage.openPublicConversationContent(&request)) |location| blk: {
                    var owned: ContentReader = undefined;
                    owned.open(location);
                    owned.close();
                    break :blk {};
                } else |err| err,
                .activity => if (store_core.activityPageForTesting(&storage, .{ .session = request.session })) |_| {} else |err| err,
                .activity_bytes => if (storage.openActivityContent(&.{ .session = request.session, .position = request.position })) |location| blk: {
                    var owned: ContentReader = undefined;
                    owned.open(location);
                    owned.close();
                    break :blk {};
                } else |err| err,
                .full => if (testingSessionReportWithProfile(&storage, &tmp, request.session.slice(), 1024 * 1024, .full)) |report| blk: {
                    std.testing.allocator.free(report);
                    break :blk {};
                } else |err| err,
            };
            try std.testing.expectError(error.CorruptStore, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
        }
    }
}

test "missing assistant certificates respect page windows and fixed ends" {
    for ([_]bool{ false, true }) |activity| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const missing = try testingPublicProjection(&storage, &tmp, &.{.{ .encoded = "answer", .decoded = "answer" }});
        for (0..20) |index| {
            var key_buffer: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buffer, "later-{d}", .{index});
            try submitTestMessage(&storage, &tmp, key, key, missing.session.slice(), "later user input");
        }
        _ = (try storage.admitNextModelAttempt(.{})).?;
        try store_testing.sqlite_only.exec(&storage, "DELETE FROM conversation_entry WHERE entry_kind=3", .{});
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.sqliteDatabase()));
        try storage.close();
        try testingStore(&storage, &tmp, std.testing.io);
        // A historical window ending before the damage remains readable.
        _ = try store_core.publicConversationPageForTesting(&storage, .{ .session = missing.session, .end = missing.position - 1 });
        _ = try store_core.activityPageForTesting(&storage, .{ .session = missing.session, .end = missing.position - 1 });
        if (activity) {
            const latest = try store_core.activityPageForTesting(&storage, .{ .session = missing.session, .direction = .backward });
            try std.testing.expect(latest.more);
            var cursor = latest.items[latest.count - 1];
            while (true) {
                const older = store_core.activityPageForTesting(&storage, .{
                    .session = missing.session,
                    .end = latest.end,
                    .direction = .backward,
                    .position = cursor.position,
                    .ordinal = cursor.ordinal,
                }) catch |err| {
                    try std.testing.expectEqual(error.CorruptStore, err);
                    break;
                };
                try std.testing.expect(older.more);
                try std.testing.expect(older.items[older.count - 1].position < cursor.position);
                cursor = older.items[older.count - 1];
            }
        } else {
            const latest = try store_core.publicConversationPageForTesting(&storage, .{ .session = missing.session });
            try std.testing.expectEqual(@as(usize, 16), latest.count);
            try std.testing.expect(latest.more);
            try std.testing.expectError(error.CorruptStore, store_core.publicConversationPageForTesting(&storage, .{
                .session = missing.session,
                .end = latest.end,
                .before_position = latest.items[latest.count - 1].position,
                .before_ordinal = latest.items[latest.count - 1].ordinal,
            }));
        }
        try std.testing.expect(storage.isFenced());
    }
}
