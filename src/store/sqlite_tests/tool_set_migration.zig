//! Tool set migration SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const std = @import("std");
const platform = @import("../../store_path.zig");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const store_schema = @import("../schema.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const openRaw = shared_fixtures.openRaw;

test "schema 65 migration freezes each Operation offer and conservatively adopts current Session intent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/offers-64.sqlite3", .{root});
    {
        const raw = try openRaw(path);
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw, store_testing.baseline_sqlite_ddl);
        try sqlite.exec(raw, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
        try sqlite.exec(raw, store_testing.baseline_rows);
        for (store_schema.migrations) |step| {
            if (step.from >= 64) break;
            for (step.sqlite) |statement| try sqlite.exec(raw, statement);
        }
        try sqlite.exec(raw, store_testing.operation_offer_migration_seed);
        try sqlite.exec(raw, std.fmt.comptimePrint("PRAGMA application_id={d};PRAGMA user_version=64", .{store_schema.application_id}));
        const meta = try sqlite.prepare(raw, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version',?1),('store_selector',?2),('format','64')");
        defer _ = c.sqlite3_finalize(meta);
        try sqlite.bindText(meta, 1, protocol.wire_version);
        try sqlite.bindText(meta, 2, root);
        try sqlite.expectDone(meta);
    }
    // Reopening must neither reproject old Operations nor widen current intent.
    for (0..2) |_| {
        var storage: Store = undefined;
        try storage.open(std.testing.io, path, root);
        defer storage.close() catch unreachable;
        try std.testing.expectEqual(@as(u64, 4), try store_testing.queryU64(&storage, "SELECT tool_set_id FROM model_operation WHERE operation_id=1", .{}));
        try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT tool_set_id FROM model_operation WHERE operation_id=99", .{}));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref='d8mv7p' AND revision=2 AND tool_set_id=4 AND loaded_tool_set_id=2", .{}));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision WHERE session_ref='d8mv7p' AND revision=1 AND tool_set_id=4 AND loaded_tool_set_id IS NULL", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM pragma_foreign_key_check", .{}));
    }
}
