//! Schema SQLite mechanism tests.

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
const schema_version = store_schema.schema_version;
const openRaw = shared_fixtures.openRaw;
const storeId = shared_fixtures.storeId;

test "fresh Store uses current schema and rejects the prior version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});

    var storage: Store = undefined;
    try storage.open(std.testing.io, database, root);
    try std.testing.expectEqual(schema_version, try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA user_version"));
    {
        const removed_index = try sqlite.prepare(
            storage.sqliteDatabase(),
            "SELECT count(*) FROM sqlite_schema WHERE type='index' AND name='model_operation_runnable'",
        );
        defer _ = c.sqlite3_finalize(removed_index);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(removed_index));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(removed_index, 0));
    }
    {
        // Uncertainty is derived from resolution and retry facts, not stored.
        const stored_uncertainty = try sqlite.prepare(
            storage.sqliteDatabase(),
            "SELECT (SELECT count(*) FROM pragma_table_info('action_operation') WHERE name='uncertain')+" ++
                "(SELECT count(*) FROM pragma_table_info('model_operation') WHERE name='uncertain')",
        );
        defer _ = c.sqlite3_finalize(stored_uncertainty);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stored_uncertainty));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(stored_uncertainty, 0));
    }
    {
        // An Action stores only its authorization; its denial is its Resolution.
        const stored_permission = try sqlite.prepare(
            storage.sqliteDatabase(),
            "SELECT count(*) FROM pragma_table_info('action_operation') WHERE name='permission_state'",
        );
        defer _ = c.sqlite3_finalize(stored_permission);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stored_permission));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(stored_permission, 0));
    }
    try storage.close();
    // Model the prior format's rollback-journal header; rejection must
    // happen before the WAL switch, leaving that Store unmodified.
    {
        var raw: ?*c.sqlite3 = null;
        var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{database}, 0), &raw));
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw.?, "PRAGMA journal_mode=DELETE");
        try sqlite.exec(raw.?, std.fmt.comptimePrint("PRAGMA user_version={d}", .{store_schema.migration_baseline - 1}));
    }
    const before = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, database, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(before);
    try std.testing.expectEqual(@as(u8, 1), before[18]);

    var refused: Store = undefined;

    try std.testing.expectError(
        error.WrongStoreVersion,
        refused.open(std.testing.io, database, root),
    );
    const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, database, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    var wal_buffer: [platform.max_database_path_bytes + "-wal".len]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, try std.fmt.bufPrint(&wal_buffer, "{s}-wal", .{database}), .{}));
}

test "existing Store strictly validates current format and wire metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    var storage: Store = undefined;
    try storage.open(std.testing.io, database, root);
    try std.testing.expectEqual(@as(u64, schema_version), try store_testing.sqlite_only.queryU64(&storage, "SELECT CAST(meta_value AS INTEGER) FROM store_meta WHERE meta_key='format'", .{}));
    try storage.close();
    const Case = struct { sql: [:0]const u8, refusal: anyerror };
    const cases = [_]Case{
        .{ .sql = "UPDATE store_meta SET meta_value='13' WHERE meta_key='wire_version'", .refusal = error.WrongStoreVersion },
        .{ .sql = std.fmt.comptimePrint("UPDATE store_meta SET meta_value='{d}' WHERE meta_key='format'", .{schema_version - 1}), .refusal = error.WrongStoreVersion },
        .{ .sql = "DELETE FROM store_meta WHERE meta_key='format'", .refusal = error.WrongStoreVersion },
    };
    for (cases) |case| {
        var raw: ?*c.sqlite3 = null;
        var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{database}, 0), &raw));
        try sqlite.exec(raw.?, "UPDATE store_meta SET meta_value='" ++ std.fmt.comptimePrint("{d}", .{schema_version}) ++ "' WHERE meta_key='format';UPDATE store_meta SET meta_value='" ++ protocol.wire_version ++ "' WHERE meta_key='wire_version'");
        try sqlite.exec(raw.?, case.sql);
        _ = c.sqlite3_close(raw);
        const before = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, database, std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(before);
        var refused: Store = undefined;
        try std.testing.expectError(case.refusal, refused.open(std.testing.io, database, root));
        const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, database, std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(after);
        try std.testing.expectEqualSlices(u8, before, after);
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{database}, 0), &raw));
        try sqlite.exec(raw.?, "DELETE FROM store_meta WHERE meta_key='format'");
        try sqlite.exec(raw.?, std.fmt.comptimePrint("INSERT INTO store_meta(meta_key,meta_value) VALUES('format','{d}')", .{schema_version}));
        _ = c.sqlite3_close(raw);
    }
    try storage.open(std.testing.io, database, root);
    try storage.close();
}

test "SQLite selector mismatch retains caller-owned evidence after failed open" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    const saved_selector = "/" ++ @as([protocol.max_store_bytes - 1]u8, @splat('s'));
    var storage: Store = undefined;
    try storage.open(std.testing.io, database, saved_selector);
    try storage.close();
    var refused: Store = undefined;
    try std.testing.expectError(error.StoreIdentityMismatch, refused.open(std.testing.io, database, root));
    var evidence: store_schema.IdentityMismatch = .{};
    try std.testing.expectError(error.StoreIdentityMismatch, refused.openTarget(std.testing.io, .{ .sqlite = database }, root, .{ .identity_mismatch = &evidence }));
    try std.testing.expectEqualStrings(saved_selector, evidence.saved_selector.slice());
    try refused.open(std.testing.io, database, saved_selector);
    try refused.close();
    try std.testing.expectEqualStrings(saved_selector, evidence.saved_selector.slice());
}

test "SQLite selector mismatch retains migration evidence and rolls back metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    var storage: Store = undefined;
    try storage.open(std.testing.io, database, root);
    try storage.close();
    const original_id = try storeId(database);
    {
        const raw = try openRaw(database);
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw, "UPDATE store_meta SET meta_value='56' WHERE meta_key='format';PRAGMA user_version=56");
        var evidence: store_schema.IdentityMismatch = .{};
        try std.testing.expectError(error.StoreIdentityMismatch, store_schema.migrate(std.testing.io, raw, "/different/canonical/store", 56, &.{}, &evidence));
        try std.testing.expectEqualStrings(root, evidence.saved_selector.slice());
        try std.testing.expectEqual(@as(u32, 56), try sqlite.pragmaInt(raw, "PRAGMA user_version"));
        try std.testing.expectEqual(@as(u32, 56), try sqlite.pragmaInt(raw, "SELECT CAST(meta_value AS INTEGER) FROM store_meta WHERE meta_key='format'"));
        const selector = try sqlite.prepare(raw, "SELECT meta_value FROM store_meta WHERE meta_key='store_selector'");
        defer _ = c.sqlite3_finalize(selector);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(selector));
        var saved: protocol.Bounded(protocol.max_store_bytes) = .{};
        try sqlite.readText(selector, 0, &saved);
        try std.testing.expectEqualStrings(root, saved.slice());
    }
    try std.testing.expectEqualStrings(&original_id, &try storeId(database));
}

test "metadata seed preserves exact SQLite bootstrap bytes and digest" {
    // The pre-refactor seed text: parameter slots, tuple order and random
    // expression are format, not merely row-equivalent implementation details.
    try std.testing.expectEqualStrings(
        "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version',?1),('store_selector',?2),('format','" ++
            std.fmt.comptimePrint("{d}", .{schema_version}) ++ "'),('store_id',lower(hex(randomblob(16))))",
        comptime store_schema.sqliteMetaSeedSql(),
    );
    const pinned = store_schema.bootstrap_digests[store_schema.bootstrap_digests.len - 1];
    try std.testing.expectEqual(schema_version, pinned.schema_version);
    try std.testing.expectEqual(pinned.digest, comptime store_schema.digest());
}

test "SQLite invalid identity metadata is not a selector mismatch" {
    const cases = .{
        .{ "PRAGMA application_id=0", error.WrongStoreIdentity },
        .{ "DELETE FROM store_meta WHERE meta_key='store_selector'", error.WrongStoreIdentity },
        .{ "DELETE FROM store_meta WHERE meta_key='store_id'", error.WrongStoreIdentity },
        .{ "UPDATE store_meta SET meta_value='not-an-id' WHERE meta_key='store_id'", error.WrongStoreIdentity },
        .{ "UPDATE store_meta SET meta_value=CAST(x'ff' AS TEXT) WHERE meta_key='store_selector'", error.InvalidUtf8 },
        .{ "UPDATE store_meta SET meta_value=printf('%0493d',0) WHERE meta_key='store_selector'", error.ValueTooLong },
    };
    inline for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [protocol.max_store_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
        const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
        var storage: Store = undefined;
        try storage.open(std.testing.io, database, root);
        try storage.close();
        {
            const raw = try openRaw(database);
            defer _ = c.sqlite3_close(raw);
            try sqlite.exec(raw, case[0]);
        }
        for ([_][]const u8{ root, "/different/canonical/store" }) |selector| {
            var evidence: store_schema.IdentityMismatch = .{};
            try evidence.saved_selector.set("unchanged");
            var refused: Store = undefined;
            try std.testing.expectError(case[1], refused.openTarget(std.testing.io, .{ .sqlite = database }, selector, .{ .identity_mismatch = &evidence }));
            try std.testing.expectEqualStrings("unchanged", evidence.saved_selector.slice());
        }
    }
}

test "a new Store draws its own Store id, keeps it, and is refused without it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var first_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const first = try std.fmt.bufPrint(&first_buffer, "{s}/first.sqlite3", .{root});
    var second_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const second = try std.fmt.bufPrint(&second_buffer, "{s}/second.sqlite3", .{root});
    var storage: Store = undefined;
    try storage.open(std.testing.io, first, root);
    try storage.close();
    try storage.open(std.testing.io, second, root);
    try storage.close();
    const id = try storeId(first);
    try std.testing.expect(!std.mem.eql(u8, &id, &try storeId(second)));
    try storage.open(std.testing.io, first, root);
    try storage.close();
    try std.testing.expectEqualStrings(&id, &try storeId(first));
    for ([_][:0]const u8{ "UPDATE store_meta SET meta_value=upper(meta_value) WHERE meta_key='store_id'", "DELETE FROM store_meta WHERE meta_key='store_id'" }) |damage| {
        {
            const raw = try openRaw(first);
            defer _ = c.sqlite3_close(raw);
            try sqlite.exec(raw, damage);
        }
        var refused: Store = undefined;
        try std.testing.expectError(error.WrongStoreIdentity, refused.open(std.testing.io, first, root));
    }
}

test "existing Store rejects a table rebuilt without one of its CHECKs, and stays unmodified" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    var storage: Store = undefined;
    try storage.open(std.testing.io, database, root);
    try storage.close();
    const original = comptime for (store_schema.objects(.sqlite)) |object| {
        if (std.mem.eql(u8, object.name, "content")) break object.sql;
    } else unreachable;
    // The same text without its first CHECK clause.
    const unchecked = comptime blk: {
        const start = std.mem.indexOf(u8, original, " CHECK(").?;
        var depth: usize = 0;
        var end = start + " CHECK".len;
        while (true) : (end += 1) {
            if (original[end] == '(') depth += 1;
            if (original[end] == ')') depth -= 1;
            if (depth == 0) break;
        }
        break :blk original[0..start] ++ original[end + 1 ..];
    };
    const Rebuild = struct {
        fn run(path: []const u8, comptime create: []const u8) !void {
            var raw: ?*c.sqlite3 = null;
            var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
            try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{path}, 0), &raw));
            defer _ = c.sqlite3_close(raw);
            try sqlite.exec(raw.?, "PRAGMA foreign_keys=OFF");
            try sqlite.exec(raw.?, "BEGIN; CREATE TEMP TABLE kept AS SELECT * FROM content; DROP TABLE content; " ++
                create ++ "; INSERT INTO content SELECT * FROM kept; DROP TABLE kept; COMMIT");
        }
    };
    // Rebuilt from its own text, the Store still opens.
    try Rebuild.run(database, original);
    try storage.open(std.testing.io, database, root);
    try storage.close();
    try Rebuild.run(database, unchecked);
    const before = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, database, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(before);
    var refused: Store = undefined;
    try std.testing.expectError(error.WrongStoreSchema, refused.open(std.testing.io, database, root));
    const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, database, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

test "existing Store rejects noncanonical durable authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});

    var storage: Store = undefined;
    try storage.open(std.testing.io, database, root);
    try sqlite.exec(storage.sqliteDatabase(), "CREATE TABLE tool_result_authority(call_id INTEGER PRIMARY KEY, result_content_id INTEGER NOT NULL)");
    try storage.close();

    var refused: Store = undefined;

    try std.testing.expectError(
        error.WrongStoreSchema,
        refused.open(std.testing.io, database, root),
    );
}
