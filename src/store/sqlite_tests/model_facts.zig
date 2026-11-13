//! Model facts SQLite mechanism tests.
const std = @import("std");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const testingStore = store_testing.testingSqliteStore;

test "runtime catalog read failures never fall back and fence only engine failure" {
    for ([_]bool{ false, true }) |saved| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        if (saved) try storage.saveModelFacts(&.{.{ .id = "read-kept", .context_window = 100, .efforts = .{}, .openai_listed = true }}, null);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        // Failure while preparing the selected-facts read is memory pressure,
        // not permission to answer shipped facts or fence a healthy Store.
        sqlite.testing_fail_next_insert = true;
        defer sqlite.testing_fail_next_insert = false;
        try std.testing.expectError(error.OutOfMemory, storage.readModelCatalog(arena.allocator()));
        try std.testing.expect(!sqlite.testing_fail_next_insert);
        try std.testing.expect(!storage.isFenced());
        const selected = try storage.readModelCatalog(arena.allocator());
        if (saved) {
            try std.testing.expectEqual(@as(usize, 1), selected.len);
            try std.testing.expectEqualStrings("read-kept", selected[0].id);
        } else try std.testing.expect(selected.ptr == @import("../../model_catalog.zig").shipped.ptr);
        // Remove the selected statement before breaking its schema: schema
        // reprepare is deliberately a panic in the normal cached-plan guard.
        const cache = &storage.engine.sqlite.statements;
        const selected_sql = for (cache.slots) |slot| {
            if (slot.sql) |sql| if (std.mem.indexOf(u8, std.mem.span(sql), "LEFT JOIN model_fact") != null) break sql;
        } else return error.TestUnexpectedResult;
        cache.remove(selected_sql);
        try store_testing.sqliteExec(storage.sqliteDatabase(), "DROP TABLE model_fact", .{});
        // A failed selected read, with or without a saved source, must not
        // return the shipped catalog as a successful answer.
        try std.testing.expectError(error.StatementPrepareFailed, storage.readModelCatalog(arena.allocator()));
        try std.testing.expect(storage.isFenced());
        try std.testing.expectError(error.StoreFenced, storage.readModelCatalog(arena.allocator()));
    }
}

test "model catalog save releases its pager working set before leaving the queue" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    _ = sqlite.c.sqlite3_db_release_memory(storage.sqliteDatabase());
    const baseline_cache = storage.diagnostic().sqlite.cache_used_bytes.?;
    const catalog = @import("../../model_catalog.zig");
    var ids: [1024][64]u8 = undefined;
    var facts: [ids.len]catalog.Entry = undefined;
    for (&facts, &ids, 0..) |*fact, *id, index| {
        @memset(id, 'a');
        _ = try std.fmt.bufPrint(id, "catalog-{d:0>4}", .{index});
        fact.* = .{ .id = id, .context_window = 123, .efforts = .{}, .openai_listed = true };
    }
    try storage.saveModelFacts(&facts, "\"one\"");
    // Only the preexisting pinned fixture pages and accounting remain.
    try std.testing.expectEqual(baseline_cache, storage.diagnostic().sqlite.cache_used_bytes.?);
    try std.testing.expectEqual(@as(?u32, 123), (try storage.modelFact(facts[999].id)).?.context_window);
    try storage.saveModelFacts(&facts, "\"two\"");
    try std.testing.expectEqual(baseline_cache, storage.diagnostic().sqlite.cache_used_bytes.?);
    try std.testing.expectEqual(@as(u64, 2), (try storage.readModelCatalogSource()).?.generation);
}
