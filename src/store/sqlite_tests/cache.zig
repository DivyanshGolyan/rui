//! Cache SQLite mechanism tests.
const std = @import("std");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const StatementCache = sqlite.StatementCache;
const TestingAnswerPart = store_testing.TestingAnswerPart;
const answerTestTurn = store_testing.answerTestTurn;
const configureTestSession = store_testing.configureTestSession;
const testingStore = store_testing.testingSqliteStore;

test "a warm Turn prepares no statement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "warm-config");
    const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
    try answerTestTurn(&storage, &tmp, session.slice(), "cold", &answer);
    try answerTestTurn(&storage, &tmp, session.slice(), "warming", &answer);
    const Steps = struct {
        cache: *const StatementCache,
        uncached: usize = 0,

        fn traced(mask: c_uint, context: ?*anyopaque, statement: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            std.debug.assert(mask == c.SQLITE_TRACE_STMT);
            const self: *@This() = @ptrCast(@alignCast(context.?));
            for (self.cache.slots) |slot| {
                if (slot.statement == @as(?*c.sqlite3_stmt, @ptrCast(statement))) return 0;
            }
            self.uncached += 1;
            return 0;
        }
    };
    var steps = Steps{ .cache = &storage.engine.sqlite.statements };
    const prepared = storage.engine.sqlite.statements.count;
    _ = c.sqlite3_trace_v2(storage.sqliteDatabase(), c.SQLITE_TRACE_STMT, Steps.traced, &steps);
    defer _ = c.sqlite3_trace_v2(storage.sqliteDatabase(), 0, null, null);
    try answerTestTurn(&storage, &tmp, session.slice(), "warm", &answer);
    try std.testing.expectEqual(@as(usize, 0), steps.uncached);
    try std.testing.expectEqual(prepared, storage.engine.sqlite.statements.count);
}

test "prepared cache eviction keeps colliding probe chains reachable" {
    var database: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &database));
    defer _ = c.sqlite3_close(database.?);
    var cache: sqlite.StatementCache = .{};
    defer cache.deinit();
    const keys = comptime keys: {
        @setEvalBranchQuota(100_000);
        var result: [65][:0]const u8 = undefined;
        for (&result, 0..) |*key, index| key.* = std.fmt.comptimePrint("SELECT {d}", .{index});
        break :keys result;
    };
    var buckets: [64]?[:0]const u8 = @splat(null);
    for (keys) |key| {
        const bucket = std.hash.int(@intFromPtr(key.ptr)) & 63;
        if (buckets[bucket]) |first| {
            for ([_][:0]const u8{ first, key }) |sql| {
                var statement: ?*c.sqlite3_stmt = null;
                try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v3(database.?, sql, -1, 0, &statement, null));
                try cache.insert(sql, statement.?);
            }
            const survivor = cache.find(key).?;
            cache.remove(first);
            try std.testing.expect(cache.find(first) == null);
            try std.testing.expectEqual(survivor, cache.find(key).?);
            cache.remove(first); // An already-evicted form is a no-op.
            try std.testing.expectEqual(@as(usize, 1), cache.count);
            cache.remove(key);
            try std.testing.expectEqual(@as(usize, 0), cache.count);
            return;
        }
        buckets[bucket] = key;
    }
    unreachable; // 65 static keys in 64 initial buckets must collide.
}
