//! Compaction SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const historical_domain = @import("../domain/historical.zig");
const history_floor_domain = @import("../domain/history_floor.zig");
const store_testing = @import("../testing.zig");
const settleCompactionForTesting = store_testing.settleCompactionForTesting;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const testingStore = store_testing.testingSqliteStore;
const TestingSteps = shared_fixtures.TestingSteps;

/// The floor walk as admission and settlement take it: `FloorSearch`'s
/// facts round, then a round a page, through the transition runner, outside
/// any transaction.
const TestingFloorWalk = struct {
    pub const rounds = transition.rounds(.{
        .facts = .{ .always, error.CorruptStore },
        .page = .{ .paged, error.CorruptStore },
    });
    pub const round_budget = 1;
    pub const commit: transition.Commit = .none;
    pub const begin: ?rounds.At = null;
    pub const Input = struct { operation: u64 };
    pub const Result = ?history_floor_domain.Room;
    pub const Ordinary = store_core.Ordinary.none;

    input: Input,
    search: history_floor_domain.FloorSearch = undefined,

    pub fn step(t: *TestingFloorWalk, r: *transition.Round(TestingFloorWalk), ran: ?rounds.At) !transition.Next(TestingFloorWalk) {
        if (ran == null) {
            t.search = .{ .operation = t.input.operation };
            t.search.start(r);
            return .{ .round = .facts };
        }
        if (t.search.next(r)) return .{ .round = .page };
        return .{ .done = t.search.room() };
    }

    fn deeper(store: *Store, operation: u64) !?history_floor_domain.Room {
        const entry = try store_core.enter(store, .none);
        defer entry.release();
        var walk: TestingFloorWalk = .{ .input = .{ .operation = operation } };
        return transition.run(&entry, TestingFloorWalk, &walk, .{});
    }
};

test "a compaction's floor counts the output bytes a request sends, and none its base covers" {
    // A 200,000-byte answer with no usage passes level 2's 128,000 bytes,
    // unless a compaction base covers it and the request sends none of it.
    const answer = try std.testing.allocator.alloc(u8, 200_000);
    defer std.testing.allocator.free(answer);
    @memset(answer, 'a');
    const item = try std.fmt.allocPrint(std.testing.allocator, "{{\"type\":\"message\",\"id\":\"a1\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":\"{s}\"}}]}}", .{answer});
    defer std.testing.allocator.free(item);
    for ([_]bool{ false, true }) |covered| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try tests.configureTestSessionAsk(&storage, "floor-bytes-config");
        try submitTestMessage(&storage, &tmp, "floor-bytes-first", "floor-bytes-first", session.slice(), "first");
        const answered = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try settleItemsForTesting(&storage, &tmp, answered, &.{item}, answer);
        if (covered) {
            try submitTestMessage(&storage, &tmp, "floor-bytes-covered", "floor-bytes-covered", session.slice(), "c");
            const call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(call, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
            const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCompactionForTesting(&storage, &tmp, base, &.{.compaction});
        }
        try submitTestMessage(&storage, &tmp, "floor-bytes-small", "floor-bytes-small", session.slice(), "small");
        const call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try storage.settleModelAttemptFailure(call, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
        const compaction = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const room = try TestingFloorWalk.deeper(&storage, compaction.operation_id);
        if (covered) {
            try std.testing.expect(room == null);
        } else {
            // The floor drops the answer and keeps "small" above it.
            const position = try store_testing.sqliteQueryU64(storage.sqliteDatabase(), "SELECT admission_position FROM model_operation WHERE operation_id=?1", .{answered.operation_id});
            try std.testing.expectEqual(@as(u8, 2), room.?.choice.level);
            try std.testing.expect(room.?.choice.floor >= position);
        }
    }
}

test "a compaction's floor walk reads past its first page to the level that drops least" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try tests.configureTestSessionAsk(&storage, "floor-pages-config");
    // After the first, twenty 30,000-byte Messages: level 1's 512,000
    // bytes are past at the eighteenth from the newest, on the second page.
    const text = try std.testing.allocator.alloc(u8, 30_000);
    defer std.testing.allocator.free(text);
    @memset(text, 'p');
    try submitTestMessage(&storage, &tmp, "floor-pages-first", "floor-pages-first", session.slice(), "first");
    var key: [32]u8 = undefined;
    for (0..20) |index| {
        const name = try std.fmt.bufPrint(&key, "floor-pages-{d}", .{index});
        try submitTestMessage(&storage, &tmp, name, name, session.slice(), text);
    }
    const call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(call, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
    const compaction = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const room = (try TestingFloorWalk.deeper(&storage, compaction.operation_id)).?;
    try std.testing.expectEqual(@as(u8, 1), room.choice.level);
}

test "a compaction's floor read costs the same however long its Session's history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try tests.configureTestSessionAsk(&storage, "floor-steps-config");
    // 200 KB Messages: level 1's 512,000 bytes are past at the fourth.
    const text = try std.testing.allocator.alloc(u8, 200_000);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');
    try submitTestMessage(&storage, &tmp, "floor-steps-first", "floor-steps-first", session.slice(), "first");
    try submitTestMessage(&storage, &tmp, "floor-steps-big", "floor-steps-big", session.slice(), text);
    const call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(call, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
    const compaction = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const Walk = struct {
        fn steps(store: *Store, operation: u64) !u64 {
            // The first read prepares the walk's statements.
            _ = try deeper(store, operation);
            var counter: TestingSteps = .{};
            counter.begin(store.sqliteDatabase());
            defer counter.end(store.sqliteDatabase());
            try std.testing.expect(try deeper(store, operation) != null);
            return counter.steps;
        }
        fn deeper(store: *Store, operation: u64) !?history_floor_domain.Room {
            return TestingFloorWalk.deeper(store, operation);
        }
        /// 1,000 more copies of the big Message, older than the rest: the
        /// first Message moves past them, as the walk keeps it either way.
        fn addOlder(store: *Store, ref: []const u8, comptime first: u64) !void {
            const sequence = std.fmt.comptimePrint("WITH RECURSIVE sequence(value) AS (VALUES({d}) UNION ALL SELECT value+1 FROM sequence WHERE value<{d}) ", .{ first, first + 999 });
            try store_testing.sqlite_only.withoutForeignKeys(store, sequence ++
                "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,content_id,recorded_at) " ++
                "SELECT session_ref,entry_ordinal+value*10,session_position-value-1,entry_kind,turn_id,source_admission_id+value*10,NULL,NULL,content_id,recorded_at " ++
                "FROM conversation_entry CROSS JOIN sequence WHERE session_ref=?1 AND entry_ordinal=2", .{ref});
        }
    };
    try store_testing.sqlite_only.withoutForeignKeys(&storage, "UPDATE conversation_entry SET session_position=session_position+3000 WHERE session_ref=?1", .{session.slice()});
    try store_testing.sqlite_only.withoutForeignKeys(&storage, "UPDATE model_operation SET admission_position=admission_position+3000 WHERE session_ref=?1", .{session.slice()});
    try store_testing.sqlite_only.withoutForeignKeys(&storage, "UPDATE session SET next_position=next_position+3000 WHERE session_ref=?1", .{session.slice()});
    try Walk.addOlder(&storage, session.slice(), 1);
    const thousand = try Walk.steps(&storage, compaction.operation_id);
    try Walk.addOlder(&storage, session.slice(), 1001);
    try std.testing.expectEqual(@as(u64, 2002), try store_testing.sqliteQueryU64(storage.sqliteDatabase(), "SELECT count(*) FROM conversation_entry", .{}));
    try std.testing.expectEqual(thousand, try Walk.steps(&storage, compaction.operation_id));
}
