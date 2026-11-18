const std = @import("std");
const store_path = @import("../../store_path.zig");
const provider_route = @import("../../provider_route.zig");
const content_string = @import("../../content_string.zig");
const change_ring = @import("../../change_ring.zig");
const engine = @import("../engine.zig");
const rsql = @import("../rsql.zig");
const store_schema = @import("../schema.zig");
const sqlite = @import("../sqlite.zig");
const store_core = @import("../Store.zig");
const c = sqlite.c;
const Control = engine.Control;
const Failure = engine.Failure;
const Statement = engine.Statement;

const Sqlite = @This();

pub const Database = *c.sqlite3;

database: Database,
statements: sqlite.StatementCache = .{},
read_blob: ContentBlob = .{},

pub const ContentBlob = struct {
    handle: ?*c.sqlite3_blob = null,
    content_id: i64 = 0,

    pub fn close(self: *ContentBlob) void {
        if (self.handle) |handle| _ = c.sqlite3_blob_close(handle);
        self.* = .{};
    }
};

pub const ContentSink = struct {
    blob: *c.sqlite3_blob,

    pub fn write(sink: ContentSink, bytes: []const u8, offset: u64) error{ ContentWriteFailed, ContentTooLarge }!void {
        if (offset > std.math.maxInt(c_int)) return error.ContentTooLarge;
        if (c.sqlite3_blob_write(sink.blob, bytes.ptr, @intCast(bytes.len), @intCast(offset)) != c.SQLITE_OK) return error.ContentWriteFailed;
    }

    pub fn close(sink: ContentSink) void {
        _ = c.sqlite3_blob_close(sink.blob);
    }
};

pub noinline fn open(io: std.Io, database_path: []const u8, selector: []const u8, options: store_core.OpenOptions) !Sqlite {
    if (options.cache_kib == 0 or options.cache_kib > 4096) return error.InvalidSqliteCacheSize;
    if (c.sqlite3_hard_heap_limit64(@intCast(sqlite.sqlite_heap_bytes)) < 0) {
        return error.SqliteHeapLimitConfigurationFailed;
    }
    errdefer _ = c.sqlite3_hard_heap_limit64(0);

    const existing = blk: {
        const stat = std.Io.Dir.cwd().statFile(io, database_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        if (stat.kind != .file) return error.InvalidStoreDatabase;
        break :blk stat.size != 0;
    };

    var path_buffer: [store_path.max_database_path_bytes + 1:0]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{database_path}, 0);
    var database: ?*c.sqlite3 = null;
    const open_result = c.sqlite3_open_v2(
        path,
        &database,
        c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX,
        null,
    );
    if (open_result != c.SQLITE_OK) {
        if (database) |db| _ = c.sqlite3_close(db);
        return error.StoreOpenFailed;
    }
    errdefer {
        if (database) |db| _ = c.sqlite3_close(db);
    }

    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_LENGTH, @intCast(content_string.max_bytes + 4096));
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_SQL_LENGTH, 16 * 1024);
    const column_limit = comptime blk: {
        var widest: usize = 0;
        for (store_schema.tables) |table| {
            if (!table.engines.on(.sqlite)) continue;
            var columns: usize = 0;
            for (table.columns) |column| {
                if (column.engines.on(.sqlite)) columns += 1;
            }
            widest = @max(widest, columns);
        }
        break :blk @as(c_int, @intCast(widest));
    };
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_COLUMN, column_limit);
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_EXPR_DEPTH, @import("../../json_limits.zig").max_depth);
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_COMPOUND_SELECT, 4);
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_FUNCTION_ARG, 16);
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_VARIABLE_NUMBER, rsql.max_parameters);
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_TRIGGER_DEPTH, 0);
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_LIKE_PATTERN_LENGTH, 4096);
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_ATTACHED, 0);
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_WORKER_THREADS, 0);
    try sqlite.dbConfig(database.?, c.SQLITE_DBCONFIG_DEFENSIVE, 1);
    try sqlite.dbConfig(database.?, c.SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0);
    try sqlite.exec(database.?, "PRAGMA locking_mode=EXCLUSIVE");
    if (existing) {
        if (options.found_schema_version) |found| found.* = try sqlite.pragmaInt(database.?, "PRAGMA user_version");
        try store_schema.openExisting(io, database.?, selector, options.identity_mismatch, options.migration_notice);
    }
    try sqlite.exec(database.?, "PRAGMA busy_timeout=0");
    try sqlite.exec(database.?, "PRAGMA foreign_keys=ON");
    try sqlite.exec(database.?, "PRAGMA mmap_size=0");
    try sqlite.exec(database.?, "PRAGMA temp_store=FILE");
    var cache_size_buffer: [64:0]u8 = undefined;
    const cache_size = try std.fmt.bufPrintSentinel(&cache_size_buffer, "PRAGMA cache_size=-{d}", .{options.cache_kib}, 0);
    try sqlite.exec(database.?, cache_size);
    try sqlite.exec(database.?, if (options.cache_spill) "PRAGMA cache_spill=ON" else "PRAGMA cache_spill=OFF");
    try sqlite.exec(database.?, "PRAGMA synchronous=FULL");
    if (@import("../../os/os.zig").full_fsync) try sqlite.exec(database.?, "PRAGMA fullfsync=ON");
    const journal_mode = sqlite.diagnosticTextPragma(database.?, "PRAGMA journal_mode=WAL") orelse return error.StoreJournalModeFailed;
    if (!std.mem.eql(u8, journal_mode.slice(), "wal")) return error.StoreJournalModeFailed;
    try sqlite.exec(database.?, "PRAGMA journal_size_limit=4194304");
    if (!existing) try store_schema.bootstrap(database.?, selector);
    const sender_sweep = "UPDATE action_operation SET sender_handle=NULL WHERE sender_handle IS NOT NULL";
    if (@import("builtin").is_test) @import("../mysql_dialect_check.zig").shadowPrepare(comptime rsql.render(.mysql, sender_sweep));
    try sqlite.exec(database.?, comptime portable(sender_sweep));

    if (@import("builtin").is_test) try sqlite.createTouchOracleForTesting(database.?);
    return .{ .database = database.? };
}

pub fn abandon(self: *const Sqlite) void {
    _ = c.sqlite3_close(self.database);
    _ = c.sqlite3_hard_heap_limit64(0);
}

pub fn serve(self: *Sqlite, served: *provider_route.Routes) error{StoreOpenFailed}!void {
    if (c.sqlite3_create_function_v2(self.database, "rui_served", 1, c.SQLITE_UTF8 | c.SQLITE_DETERMINISTIC, served, sqlite.servedFunction, null, null, null) != c.SQLITE_OK)
        return error.StoreOpenFailed;
}

pub fn prepareRollback(self: *Sqlite) !void {
    _ = try controlStatement(self, .rollback);
    _ = try controlStatement(self, .rollback_to);
    _ = try controlStatement(self, .release);
}

pub fn close(self: *Sqlite) error{StoreCloseFailed}!void {
    self.statements.deinit();
    const close_result = c.sqlite3_close(self.database);
    if (close_result != c.SQLITE_OK) return error.StoreCloseFailed;
    _ = c.sqlite3_hard_heap_limit64(0);
}

pub fn releaseEntry(self: *Sqlite) void {
    self.read_blob.close();
    if (@import("builtin").is_test) self.statements.assertIdle();
}

pub fn releaseUnusedMemory(self: *Sqlite, comptime statements: anytype) void {
    inline for (statements) |S| self.statements.remove(S.sql);
    _ = c.sqlite3_db_release_memory(self.database);
}

pub fn diagnostic(self: *Sqlite) store_core.SqliteDiagnostic {
    var result: store_core.SqliteDiagnostic = .{};
    var current: c.sqlite3_int64 = 0;
    var highwater: c.sqlite3_int64 = 0;
    if (c.sqlite3_status64(c.SQLITE_STATUS_MEMORY_USED, &current, &highwater, 0) == c.SQLITE_OK and
        current >= 0 and highwater >= 0)
    {
        result.process_memory_current_bytes = @intCast(current);
        result.process_memory_highwater_bytes = @intCast(highwater);
    }

    var cache_used: c_int = 0;
    var unused_highwater: c_int = 0;
    if (c.sqlite3_db_status(
        self.database,
        c.SQLITE_DBSTATUS_CACHE_USED,
        &cache_used,
        &unused_highwater,
        0,
    ) == c.SQLITE_OK and cache_used >= 0) {
        result.cache_used_bytes = @intCast(cache_used);
    }
    var spills: c_int = 0;
    if (c.sqlite3_db_status(
        self.database,
        c.SQLITE_DBSTATUS_CACHE_SPILL,
        &spills,
        &unused_highwater,
        0,
    ) == c.SQLITE_OK and spills >= 0) {
        result.cache_spills = @intCast(spills);
    }

    const hard_heap_limit = c.sqlite3_hard_heap_limit64(-1);
    if (hard_heap_limit >= 0) result.hard_heap_limit_bytes = @intCast(hard_heap_limit);
    result.page_size_bytes = sqlite.diagnosticUnsignedPragma(self.database, "PRAGMA page_size");
    result.cache_size_setting = sqlite.diagnosticSignedPragma(self.database, "PRAGMA cache_size");
    result.cache_spill_threshold = sqlite.diagnosticSignedPragma(self.database, "PRAGMA cache_spill");
    result.mmap_size_bytes = sqlite.diagnosticUnsignedPragma(self.database, "PRAGMA mmap_size");
    result.synchronous = sqlite.diagnosticSignedPragma(self.database, "PRAGMA synchronous");
    result.temp_store = sqlite.diagnosticSignedPragma(self.database, "PRAGMA temp_store");
    result.busy_timeout_ms = sqlite.diagnosticUnsignedPragma(self.database, "PRAGMA busy_timeout");
    result.journal_mode = sqlite.diagnosticTextPragma(self.database, "PRAGMA journal_mode");
    return result;
}

inline fn handleOf(statement: ?Statement) *c.sqlite3_stmt {
    return @ptrCast(statement.?);
}

pub inline fn statementFor(self: *Sqlite, comptime S: type) error{ StatementPrepareFailed, OutOfMemory }!Statement {
    return @ptrCast(try self.cachedTyped(S));
}

pub inline fn bind(statement: ?Statement, comptime S: type, args: *const S.Args, now: i64) Failure!void {
    return sqlite.bindArgs(handleOf(statement), S, args, now);
}

pub inline fn discard(statement: ?Statement) void {
    if (statement) |bound| sqlite.resetUnstepped(@ptrCast(bound));
}

pub inline fn nextRow(statement: ?Statement) Failure!bool {
    return switch (c.sqlite3_step(handleOf(statement))) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => error.StatementFailed,
    };
}

pub inline fn decodeRow(comptime Row: type, statement: ?Statement, row: *Row) error{CorruptStore}!void {
    return sqlite.decodeRow(Row, handleOf(statement), row);
}

pub inline fn stepWrite(self: *const Sqlite, statement: ?Statement) Failure!u64 {
    switch (c.sqlite3_step(handleOf(statement))) {
        c.SQLITE_DONE => {},
        c.SQLITE_FULL => return error.CanonicalStorageFull,
        else => return error.StatementFailed,
    }
    return @intCast(c.sqlite3_changes64(self.database));
}

pub inline fn endStatement(statement: ?Statement) void {
    if (statement) |stepped| sqlite.resetCached(@ptrCast(stepped));
}

pub fn queuePayload(_: *Sqlite, content_id: u64, bytes: []const u8, host: anytype) void {
    host.payload(content_id, bytes);
}

pub fn writePayload(self: *Sqlite, content_id: u64, bytes: []const u8) Failure!void {
    var blob: ?*c.sqlite3_blob = null;
    if (c.sqlite3_blob_open(self.database, "main", "content", "payload", @intCast(content_id), 1, &blob) != c.SQLITE_OK) return error.ContentWriteFailed;
    defer _ = c.sqlite3_blob_close(blob);
    if (c.sqlite3_blob_write(blob, bytes.ptr, @intCast(bytes.len), 0) != c.SQLITE_OK) return error.ContentWriteFailed;
}

pub fn readRaw(self: *Sqlite, content_id: u64, offset: u64, destination: []u8) Failure!void {
    if (offset > std.math.maxInt(c_int)) return error.RangeOutOfBounds;
    const id: i64 = @intCast(content_id);
    const blob = &self.read_blob;
    if (blob.handle == null) {
        if (c.sqlite3_blob_open(self.database, "main", "content", "payload", id, 0, &blob.handle) != c.SQLITE_OK) return error.ContentReadFailed;
        blob.content_id = id;
    } else if (blob.content_id != id) {
        if (c.sqlite3_blob_reopen(blob.handle, id) != c.SQLITE_OK) return error.ContentReadFailed;
        blob.content_id = id;
    }
    if (c.sqlite3_blob_read(blob.handle, destination.ptr, @intCast(destination.len), @intCast(offset)) != c.SQLITE_OK) return error.ContentReadFailed;
}

pub fn openSink(self: *Sqlite, content_id: u64, length: u64) Failure!ContentSink {
    var blob: ?*c.sqlite3_blob = null;
    if (c.sqlite3_blob_open(self.database, "main", "content", "payload", @intCast(content_id), 1, &blob) != c.SQLITE_OK) return error.ContentWriteFailed;
    if (std.debug.runtime_safety) std.debug.assert(c.sqlite3_blob_bytes(blob) == length);
    return .{ .blob = blob.? };
}

pub fn control(self: *Sqlite, comptime which: Control) engine.ControlError!void {
    const statement = try controlStatement(self, which);
    defer sqlite.resetCached(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.SqliteExecFailed;
}

pub inline fn inTransaction(self: *const Sqlite) bool {
    return c.sqlite3_get_autocommit(self.database) == 0;
}

pub fn inWriteTransaction(self: *const Sqlite) bool {
    return c.sqlite3_txn_state(self.database, "main") == c.SQLITE_TXN_WRITE;
}

pub inline fn totalChanges(self: *const Sqlite) i64 {
    return c.sqlite3_total_changes64(self.database);
}

fn portable(comptime text: [:0]const u8) [:0]const u8 {
    if (rsql.portabilityError(text, rsql.reserved_names_checked)) |message| @compileError(message ++ ": " ++ text);
    return text;
}

fn controlSql(comptime which: Control) [:0]const u8 {
    return switch (which) {
        .begin => "BEGIN IMMEDIATE",
        .commit => "COMMIT",
        .rollback => "ROLLBACK",
        .savepoint => "SAVEPOINT write",
        .release => "RELEASE write",
        .rollback_to => "ROLLBACK TO write",
    };
}

fn controlStatement(self: *Sqlite, comptime which: Control) !*c.sqlite3_stmt {
    return cachedStatic(self, comptime controlSql(which));
}

pub fn cachedTyped(self: *Sqlite, comptime S: type) !*c.sqlite3_stmt {
    comptime if (!rsql.isStatement(S)) @compileError("cachedTyped runs only a type rsql.Read or rsql.Write made: " ++ @typeName(S));
    if (@import("builtin").is_test) @import("../mysql_dialect_check.zig").shadowPrepareStatement(S);
    return cachedStatic(self, S.sql);
}

fn fixtureStatement(self: *Sqlite, comptime sql: [:0]const u8) !*c.sqlite3_stmt {
    if (!@import("builtin").is_test) @compileError("test-only Store statement");
    return cachedStatic(self, sql);
}

fn cachedStatic(self: *Sqlite, sql: [:0]const u8) !*c.sqlite3_stmt {
    if (self.statements.find(sql.ptr)) |statement| {
        std.debug.assert(c.sqlite3_stmt_busy(statement) == 0);
        return statement;
    }
    var prepared: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v3(self.database, sql, -1, c.SQLITE_PREPARE_PERSISTENT, &prepared, null) != c.SQLITE_OK) {
        return error.StatementPrepareFailed;
    }
    const statement = prepared orelse return error.StatementPrepareFailed;
    self.statements.insert(sql.ptr, statement) catch |err| {
        _ = c.sqlite3_finalize(statement);
        return err;
    };
    return statement;
}

pub fn setHistoricalModelForTesting(self: *Sqlite, operation_id: u64, model: []const u8) !void {
    const statement = try fixtureStatement(self, "UPDATE session_revision SET model=?2 " ++
        "WHERE (session_ref,revision)=(SELECT o.session_ref,o.settings_revision FROM model_operation o " ++
        "JOIN session s ON s.session_ref=o.session_ref WHERE o.operation_id=?1 AND o.settings_revision<s.revision)");
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, operation_id);
    try sqlite.bindText(statement, 2, model);
    try sqlite.expectDone(statement);
    if (c.sqlite3_changes(self.database) != 1) return error.InvalidTestingRevision;
}

pub fn damageOutputBagForTesting(self: *Sqlite, operation_id: u64) !void {
    const statement = try fixtureStatement(self, "UPDATE content SET payload=CAST(CASE WHEN substr(CAST(payload AS TEXT),1,1)='X' THEN 'Y' ELSE 'X' END || substr(CAST(payload AS TEXT),2) AS BLOB) " ++
        "WHERE content_id=(SELECT extras_content_id FROM model_output_item WHERE operation_id=?1 AND item_ordinal=0)");
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, operation_id);
    try sqlite.expectDone(statement);
    if (c.sqlite3_changes(self.database) != 1) return error.InvalidTestingOutput;
}

pub fn untouchedForTesting(self: *Sqlite, touched: *const change_ring.Touched) ?change_ring.Id {
    const statement = fixtureStatement(self, "SELECT DISTINCT session_ref FROM temp.touched_oracle WHERE session_ref IS NOT NULL") catch return null;
    defer sqlite.resetCached(statement);
    while (c.sqlite3_step(statement) == c.SQLITE_ROW) {
        const changed = c.sqlite3_column_text(statement, 0)[0..@intCast(c.sqlite3_column_bytes(statement, 0))];
        if (touched.contains(changed)) continue;
        var id: change_ring.Id = @splat('?');
        const length = @min(id.len, changed.len);
        @memcpy(id[0..length], changed[0..length]);
        return id;
    }
    return null;
}

pub fn clearTouchOracleForTesting(self: *Sqlite) void {
    const statement = fixtureStatement(self, "DELETE FROM temp.touched_oracle") catch return;
    defer sqlite.resetCached(statement);
    _ = c.sqlite3_step(statement);
}
