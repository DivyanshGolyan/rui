//! Open SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const std = @import("std");
const platform = @import("../../store_path.zig");
const protocol = @import("../../protocol.zig");
const tool_defs = @import("../../tools.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const sqlite_heap_bytes = sqlite.sqlite_heap_bytes;
const testingStoreToolSet = store_testing.testingStoreToolSet;
const testingStore = store_testing.testingSqliteStore;
const createMaximumCanonicalStore = shared_fixtures.createMaximumCanonicalStore;

test "Store open failures return typed errors without unwinding panics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    // A database path below a missing directory cannot be created; the open
    // must fail as a typed error rather than unwrapping a null handle.
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/missing-dir/store.sqlite3", .{root});
    var refused: Store = undefined;
    try std.testing.expectError(error.StoreOpenFailed, refused.open(std.testing.io, database, root));
}

test "Store target owns SQLite identity routes and neutral diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var expected: @import("../../bounded.zig").Bounded(protocol.max_store_bytes) = .{};
    try expected.set(root);
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite3", .{root});
    var storage: Store = undefined;
    try storage.openTarget(std.testing.io, .{ .sqlite = path }, root, .{});
    defer storage.close() catch unreachable;
    @memset(&root_buffer, 'x');
    @memset(&path_buffer, 'x');
    try std.testing.expectEqual(.sqlite, storage.kind());
    try std.testing.expectEqualStrings(expected.slice(), storage.storeId());
    try std.testing.expect(storage.admissionDiagnostic().doublewrite == null);
    const diagnostic = storage.diagnostic();
    try std.testing.expect(diagnostic == .sqlite);
    try std.testing.expectEqualStrings("wal", diagnostic.sqlite.journal_mode.?.slice());
    try std.testing.expect(storage.hostTools().set_id != 0);
    // The SQL callback must borrow final Store storage, not the opening's
    // temporary options or the admitted engine value.
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(storage.sqliteDatabase(), "SELECT rui_served('openai')"));
    storage.served.openai = .unserved;
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(storage.sqliteDatabase(), "SELECT rui_served('openai')"));
}

test "Store target SQLite tail failure closes statements and releases the heap limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const empty_tool_set: tool_defs.HostToolSet = .{ .records = &.{}, .digests = &.{} };
    var refused: Store = undefined;
    try std.testing.expectError(error.InvalidHostToolSet, testingStoreToolSet(&refused, &tmp, std.testing.io, &empty_tool_set));
    try std.testing.expectEqual(@as(i64, 0), c.sqlite3_hard_heap_limit64(-1));
    // Reopening the same file proves statement finalization and connection
    // cleanup, not merely that the error made it to the caller.
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try std.testing.expect(storage.hostTools().set_id != 0);
}

test "an outside SQLite writer cannot take the open Store's lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
    const database = try std.fmt.bufPrintSentinel(&database_buffer, "{s}/store.sqlite3", .{root}, 0);
    var storage: Store = undefined;
    try storage.open(std.testing.io, database, root);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;

    var blocker: ?*c.sqlite3 = null;
    try std.testing.expectEqual(
        @as(c_int, c.SQLITE_OK),
        c.sqlite3_open_v2(
            database.ptr,
            &blocker,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_NOMUTEX,
            null,
        ),
    );
    var blocker_open = true;
    defer if (blocker_open) {
        _ = c.sqlite3_close(blocker);
    };
    // The Store's exclusive lock refuses the outside writer, never the Host.
    try std.testing.expectEqual(
        @as(c_int, c.SQLITE_BUSY),
        c.sqlite3_exec(blocker, "BEGIN IMMEDIATE", null, null, null),
    );

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration(
        "busy-save",
        "",
        workspace,
        "model-a",
    );
    const configured = try storage.configure(&command, .{});
    try std.testing.expect(configured == .accepted);
    try std.testing.expect(!storage.isFenced());

    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_close(blocker));
    blocker_open = false;
    try storage.close();
    storage_open = false;

    var reopened: Store = undefined;
    try reopened.open(std.testing.io, database, root);
    defer reopened.close() catch unreachable;
    try std.testing.expect((try store_testing.observeCommandForTesting(&reopened, "busy-save")).status != .absent);
    try std.testing.expect((try reopened.inspectSessionForTesting(configured.accepted.session.slice())).found);
}

test "production Store applies finite durable SQLite settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA busy_timeout"));
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA foreign_keys"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA mmap_size"));
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA temp_store"));
    try std.testing.expectEqual(@as(u32, 2), try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA synchronous"));
    try std.testing.expectEqual(@as(u32, 4194304), try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA journal_size_limit"));
    try std.testing.expectEqualStrings("exclusive", (sqlite.diagnosticTextPragma(storage.sqliteDatabase(), "PRAGMA locking_mode") orelse return error.TestUnexpectedResult).slice());
    try std.testing.expectEqual(@as(u32, 4096), try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA page_size"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(storage.sqliteDatabase(), "PRAGMA trusted_schema"));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_threadsafe());
    try std.testing.expectEqual(@as(i64, sqlite_heap_bytes), c.sqlite3_hard_heap_limit64(-1));
    try std.testing.expectEqual(@as(c_int, 16 * 1024), c.sqlite3_limit(storage.sqliteDatabase(), c.SQLITE_LIMIT_SQL_LENGTH, -1));
    try std.testing.expectEqual(@as(c_int, 65), c.sqlite3_limit(storage.sqliteDatabase(), c.SQLITE_LIMIT_VARIABLE_NUMBER, -1));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_limit(storage.sqliteDatabase(), c.SQLITE_LIMIT_ATTACHED, -1));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_limit(storage.sqliteDatabase(), c.SQLITE_LIMIT_WORKER_THREADS, -1));

    const diagnostic = storage.diagnostic().sqlite;
    try std.testing.expectEqual(@as(?u64, sqlite_heap_bytes), diagnostic.hard_heap_limit_bytes);
    try std.testing.expectEqual(@as(?u64, 4096), diagnostic.page_size_bytes);
    try std.testing.expectEqual(@as(?i64, -1024), diagnostic.cache_size_setting);
    try std.testing.expect(diagnostic.cache_spill_threshold.? > 0);
    try std.testing.expectEqual(@as(?u64, 0), diagnostic.mmap_size_bytes);
    try std.testing.expectEqual(@as(?i64, 2), diagnostic.synchronous);
    try std.testing.expectEqual(@as(?i64, 1), diagnostic.temp_store);
    try std.testing.expectEqual(@as(?u64, 0), diagnostic.busy_timeout_ms);
    try std.testing.expectEqualStrings("wal", diagnostic.journal_mode.?.slice());
    try std.testing.expect(diagnostic.process_memory_current_bytes != null);
    try std.testing.expect(diagnostic.process_memory_highwater_bytes != null);
    try std.testing.expect(diagnostic.cache_used_bytes != null);
    try std.testing.expect(diagnostic.cache_spills != null);
    // Readback alone would only prove configuration. A single SQLite-owned
    // allocation larger than the process-global hard ceiling must be denied
    // by the pinned library while this Store owns the configured limit.
    const over_limit = c.sqlite3_malloc64(sqlite_heap_bytes + 1);
    defer c.sqlite3_free(over_limit);
    try std.testing.expect(over_limit == null);
}

/// Rows in a raw copy's content table, or null when the copy lacks the table.
fn rawContentCount(path: []const u8) !?u64 {
    var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
    var raw: ?*c.sqlite3 = null;
    defer _ = c.sqlite3_close(raw);
    if (c.sqlite3_open(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{path}, 0), &raw) != c.SQLITE_OK) return error.StoreOpenFailed;
    const statement = sqlite.prepare(raw.?, "SELECT count(*) FROM content") catch return null;
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.QueryFailed;
    return @intCast(c.sqlite3_column_int64(statement, 0));
}

test "Store WAL lifecycle at the maximum path: sidecars, lock ownership, crash copy, checkpoint and restore" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const vfs = c.sqlite3_vfs_find(null) orelse return error.SqliteVfsUnavailable;
    try std.testing.expectEqual(@as(c_int, 512), vfs.*.mxPathname);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store_buffer: [protocol.max_store_bytes]u8 = undefined;
    const store_path = try createMaximumCanonicalStore(&tmp, &store_buffer);
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}{s}", .{ store_path, platform.database_suffix });
    try std.testing.expectEqual(@as(usize, platform.max_database_path_bytes), database.len);
    var wal_buffer: [platform.max_database_path_bytes + "-wal".len]u8 = undefined;
    const wal = try std.fmt.bufPrint(&wal_buffer, "{s}-wal", .{database});
    var shm_buffer: [platform.max_database_path_bytes + "-shm".len]u8 = undefined;
    const shm = try std.fmt.bufPrint(&shm_buffer, "{s}-shm", .{database});
    var journal_buffer: [platform.max_database_path_bytes + "-journal".len]u8 = undefined;
    const journal = try std.fmt.bufPrint(&journal_buffer, "{s}-journal", .{database});
    try tmp.dir.createDir(io, "crash", .default_dir);
    try tmp.dir.createDir(io, "database-only", .default_dir);

    var storage: Store = undefined;
    try storage.open(io, database, store_path);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;
    try store_testing.sqlite_only.exec(&storage, "INSERT INTO content(digest,byte_length,private,payload) VALUES(randomblob(32),0,0,zeroblob(0))", .{});
    const crash_rows = try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM content", .{});
    try std.testing.expect((try cwd.statFile(io, wal, .{})).size > 0);
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, shm, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, journal, .{}));

    // The open Host excludes every other reader and a second owner.
    {
        var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
        var raw: ?*c.sqlite3 = null;
        defer _ = c.sqlite3_close(raw);
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{database}, 0), &raw, c.SQLITE_OPEN_READONLY, null));
        var statement: ?*c.sqlite3_stmt = null;
        const prepared = c.sqlite3_prepare_v2(raw, "SELECT count(*) FROM content", -1, &statement, null);
        defer _ = c.sqlite3_finalize(statement);
        try std.testing.expect(prepared == c.SQLITE_BUSY or (prepared == c.SQLITE_OK and c.sqlite3_step(statement) == c.SQLITE_BUSY));
    }
    var refused: Store = undefined;
    if (refused.open(io, database, store_path)) |_| return error.TestUnexpectedResult else |_| {}
    // The failed open released the process-wide heap limit; restore it.
    _ = c.sqlite3_hard_heap_limit64(sqlite_heap_bytes);

    // A process crash leaves exactly these files; the WAL holds the commits.
    try cwd.copyFile(database, tmp.dir, "crash/rui.sqlite3", io, .{});
    try cwd.copyFile(wal, tmp.dir, "crash/rui.sqlite3-wal", io, .{});
    try cwd.copyFile(database, tmp.dir, "database-only/rui.sqlite3", io, .{});

    // A payload past the auto-checkpoint size moves into the database file,
    // and the next commit truncates the reset WAL to the size limit.
    try store_testing.sqlite_only.exec(&storage, "INSERT INTO content(digest,byte_length,private,payload) VALUES(randomblob(32),6291456,0,zeroblob(6291456))", .{});
    try store_testing.sqlite_only.exec(&storage, "INSERT INTO content(digest,byte_length,private,payload) VALUES(randomblob(32),0,0,zeroblob(0))", .{});
    try std.testing.expect((try cwd.statFile(io, database, .{})).size > 6291456);
    try std.testing.expect((try cwd.statFile(io, wal, .{})).size <= 4194304);
    try storage.close();
    storage_open = false;
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, wal, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, shm, .{}));

    // Restoring the complete crash copy at the original path recovers its
    // commits; the database file alone does not.
    try tmp.dir.copyFile("crash/rui.sqlite3", cwd, database, io, .{});
    try tmp.dir.copyFile("crash/rui.sqlite3-wal", cwd, wal, io, .{});
    try storage.open(io, database, store_path);
    storage_open = true;
    try std.testing.expectEqual(crash_rows, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM content", .{}));
    var database_only_buffer: [protocol.max_store_bytes + 32]u8 = undefined;
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const database_only = try std.fmt.bufPrint(&database_only_buffer, "{s}/database-only/rui.sqlite3", .{root});
    const surviving = try rawContentCount(database_only);
    try std.testing.expect(surviving == null or surviving.? < crash_rows);
}

test "measurement Store can disable cache spill without changing other limits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    var storage: Store = undefined;
    try storage.openTarget(
        std.testing.io,
        .{ .sqlite = database },
        root,
        .{ .cache_spill = false },
    );
    defer storage.close() catch unreachable;

    const diagnostic = storage.diagnostic().sqlite;
    try std.testing.expectEqual(@as(?i64, 0), diagnostic.cache_spill_threshold);
    try std.testing.expectEqual(@as(?u64, sqlite_heap_bytes), diagnostic.hard_heap_limit_bytes);
    try std.testing.expectEqual(@as(?i64, -1024), diagnostic.cache_size_setting);
    try std.testing.expectEqual(@as(?i64, 2), diagnostic.synchronous);
    try std.testing.expectEqualStrings("wal", diagnostic.journal_mode.?.slice());
}

test "measurement Store can force a smaller SQLite cache without changing production defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});

    var storage: Store = undefined;
    try storage.openTarget(std.testing.io, .{ .sqlite = database }, root, .{ .cache_kib = 32 });
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(?i64, -32), storage.diagnostic().sqlite.cache_size_setting);
    var refused: Store = undefined;

    try std.testing.expectError(
        error.InvalidSqliteCacheSize,
        refused.openTarget(std.testing.io, .{ .sqlite = database }, root, .{ .cache_kib = 0 }),
    );
    try std.testing.expectError(
        error.InvalidSqliteCacheSize,
        refused.openTarget(std.testing.io, .{ .sqlite = database }, root, .{ .cache_kib = 4097 }),
    );
}
