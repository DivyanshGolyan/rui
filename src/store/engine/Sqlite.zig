//! The SQLite engine: the Store's connection, its prepared statements and
//! its reused content read handle, and the round mechanics Access runs on
//! them. A statement steps in process, so a pass is never a round trip.

const std = @import("std");
const platform = @import("../../platform.zig");
const protocol = @import("../../protocol.zig");
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
// Entry.release closes the read transaction before the next request, including
// errors and yielded historical scans. Logical readers cannot pin the WAL.
read_blob: ContentBlob = .{},

/// The read handle on a content payload, reused within one Entry: reading
/// on through one row reuses SQLite's overflow-page index, about
/// length/1024 bytes of its heap. `Entry.release` closes it.
pub const ContentBlob = struct {
    handle: ?*c.sqlite3_blob = null,
    content_id: i64 = 0,

    pub fn close(self: *ContentBlob) void {
        // Close reports only an earlier read failure, already returned.
        if (self.handle) |handle| _ = c.sqlite3_blob_close(handle);
        self.* = .{};
    }
};

/// Writes one content payload in place, at offsets the writer chooses.
pub const ContentSink = struct {
    blob: *c.sqlite3_blob,

    pub fn write(sink: ContentSink, bytes: []const u8, offset: u64) error{ ContentWriteFailed, ContentTooLarge }!void {
        if (offset > std.math.maxInt(c_int)) return error.ContentTooLarge;
        if (c.sqlite3_blob_write(sink.blob, bytes.ptr, @intCast(bytes.len), @intCast(offset)) != c.SQLITE_OK) return error.ContentWriteFailed;
    }

    pub fn close(sink: ContentSink) void {
        // Close reports only an earlier write failure, already returned.
        _ = c.sqlite3_blob_close(sink.blob);
    }
};

/// Opens the database file, sets its limits and PRAGMAs, and validates or
/// bootstraps its schema. It runs once per process; noinline keeps its
/// path buffers off the caller's frame, which lives as long as the Host.
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

    var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
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
    // The handle may still be null on later failure paths; never unwrap
    // it while unwinding an open failure.
    errdefer {
        if (database) |db| _ = c.sqlite3_close(db);
    }

    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_LENGTH, @intCast(protocol.max_sqlite_content_bytes + 4096));
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_SQL_LENGTH, 16 * 1024);
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_COLUMN, 32);
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_EXPR_DEPTH, protocol.max_json_depth);
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_COMPOUND_SELECT, 4);
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_FUNCTION_ARG, 16);
    // 65: a settlement's wide duplicate read binds its Operation and 64 digests as
    // ?1..?65 (`model_settlement.batch_items`); a created Session's INSERT binds 17.
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_VARIABLE_NUMBER, rsql.max_parameters);
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_TRIGGER_DEPTH, 0);
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_LIKE_PATTERN_LENGTH, 4096);
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_ATTACHED, 0);
    try sqlite.setLimit(database.?, c.SQLITE_LIMIT_WORKER_THREADS, 0);
    try sqlite.dbConfig(database.?, c.SQLITE_DBCONFIG_DEFENSIVE, 1);
    try sqlite.dbConfig(database.?, c.SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0);
    // Before the first read: the Host keeps the file lock until close, and
    // WAL then keeps its index in heap memory, so no -shm file exists.
    try sqlite.exec(database.?, "PRAGMA locking_mode=EXCLUSIVE");
    if (existing) {
        if (options.found_schema_version) |found| found.* = try sqlite.pragmaInt(database.?, "PRAGMA user_version");
        try store_schema.openExisting(io, database.?, selector);
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
    // Validation precedes this, so an incompatible Store keeps its journal mode.
    const journal_mode = sqlite.diagnosticTextPragma(database.?, "PRAGMA journal_mode=WAL") orelse return error.StoreJournalModeFailed;
    if (!std.mem.eql(u8, journal_mode.slice(), "wal")) return error.StoreJournalModeFailed;
    // Checkpoints truncate a grown WAL back to the auto-checkpoint size.
    try sqlite.exec(database.?, "PRAGMA journal_size_limit=4194304");
    if (!existing) try store_schema.bootstrap(database.?, selector);
    // A new Host never inherits a lost Action's sender authority. It
    // clears every Session's rows, so it cannot tie to one as a typed
    // Write must; its text is held to rsql's portability rules only.
    const sender_sweep = "UPDATE action_operation SET sender_handle=NULL WHERE sender_handle IS NOT NULL";
    if (@import("builtin").is_test) @import("../mysql_dialect_check.zig").shadowPrepare(comptime rsql.render(.mysql, sender_sweep));
    try sqlite.exec(database.?, comptime portable(sender_sweep));

    if (@import("builtin").is_test) try sqlite.createTouchOracleForTesting(database.?);
    return .{ .database = database.? };
}

/// Undoes `open` when the Store fails to open after it: closes the
/// connection and lifts the heap limit. Nothing is cached yet.
pub fn abandon(self: *const Sqlite) void {
    _ = c.sqlite3_close(self.database);
    _ = c.sqlite3_hard_heap_limit64(0);
}

/// Registers `rui_served` over `served`, which must keep its address for
/// the connection's life.
pub fn serve(self: *Sqlite, served: *protocol.Routes) error{StoreOpenFailed}!void {
    if (c.sqlite3_create_function_v2(self.database, "rui_served", 1, c.SQLITE_UTF8 | c.SQLITE_DETERMINISTIC, served, sqlite.servedFunction, null, null, null) != c.SQLITE_OK)
        return error.StoreOpenFailed;
}

/// Prepares what error paths run, so they roll back without preparing or
/// allocating.
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

/// Closes the Entry's content read handle; test builds also check that
/// every statement it stepped was reset.
pub fn releaseEntry(self: *Sqlite) void {
    self.read_blob.close();
    if (@import("builtin").is_test) self.statements.assertIdle();
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

fn handleOf(statement: ?Statement) *c.sqlite3_stmt {
    return @ptrCast(statement.?);
}

pub fn statementFor(self: *Sqlite, comptime S: type) error{ StatementPrepareFailed, OutOfMemory }!Statement {
    return @ptrCast(try self.cachedTyped(S));
}

pub fn bind(statement: ?Statement, comptime S: type, args: *const S.Args, now: i64) Failure!void {
    return sqlite.bindArgs(handleOf(statement), S, args, now);
}

/// Resets a statement bound but never stepped (`sqlite.resetUnstepped`).
pub fn discard(statement: ?Statement) void {
    if (statement) |bound| sqlite.resetUnstepped(@ptrCast(bound));
}

/// Steps `statement`: true at a row, false at its end.
pub fn nextRow(statement: ?Statement) Failure!bool {
    return switch (c.sqlite3_step(handleOf(statement))) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => error.StatementFailed,
    };
}

pub fn decodeRow(comptime Row: type, statement: ?Statement, row: *Row) error{CorruptStore}!void {
    return sqlite.decodeRow(Row, handleOf(statement), row);
}

/// Steps a write to its end, and returns the rows it changed.
pub fn stepWrite(self: *const Sqlite, statement: ?Statement) Failure!u64 {
    switch (c.sqlite3_step(handleOf(statement))) {
        c.SQLITE_DONE => {},
        c.SQLITE_FULL => return error.CanonicalStorageFull,
        else => return error.StatementFailed,
    }
    return @intCast(c.sqlite3_changes64(self.database));
}

/// Resets a statement its pass stepped, and checks it (`sqlite.resetCached`).
pub fn endStatement(statement: ?Statement) void {
    if (statement) |stepped| sqlite.resetCached(@ptrCast(stepped));
}

pub fn writePayload(self: *Sqlite, content_id: u64, bytes: []const u8) Failure!void {
    var blob: ?*c.sqlite3_blob = null;
    if (c.sqlite3_blob_open(self.database, "main", "content", "payload", @intCast(content_id), 1, &blob) != c.SQLITE_OK) return error.ContentWriteFailed;
    defer _ = c.sqlite3_blob_close(blob);
    if (c.sqlite3_blob_write(blob, bytes.ptr, @intCast(bytes.len), 0) != c.SQLITE_OK) return error.ContentWriteFailed;
}

/// Reads through the one reused blob handle, which `releaseEntry` closes.
pub fn readRaw(self: *Sqlite, content_id: u64, offset: u64, destination: []u8) Failure!void {
    if (offset > std.math.maxInt(c_int)) return error.RangeOutOfBounds;
    const id: i64 = @intCast(content_id);
    const blob = &self.read_blob;
    if (blob.handle == null) {
        // A failed open leaves the handle null.
        if (c.sqlite3_blob_open(self.database, "main", "content", "payload", id, 0, &blob.handle) != c.SQLITE_OK) return error.ContentReadFailed;
        blob.content_id = id;
    } else if (blob.content_id != id) {
        // A failed reopen aborts the handle; close remains its release.
        if (c.sqlite3_blob_reopen(blob.handle, id) != c.SQLITE_OK) return error.ContentReadFailed;
        blob.content_id = id;
    }
    if (c.sqlite3_blob_read(blob.handle, destination.ptr, @intCast(destination.len), @intCast(offset)) != c.SQLITE_OK) return error.ContentReadFailed;
}

/// A sink on the payload of `content_id`, whose row holds `length` bytes.
pub fn openSink(self: *Sqlite, content_id: u64, length: u64) Failure!ContentSink {
    var blob: ?*c.sqlite3_blob = null;
    if (c.sqlite3_blob_open(self.database, "main", "content", "payload", @intCast(content_id), 1, &blob) != c.SQLITE_OK) return error.ContentWriteFailed;
    if (std.debug.runtime_safety) std.debug.assert(c.sqlite3_blob_bytes(blob) == length);
    return .{ .blob = blob.? };
}

/// Runs `which`, which returns no rows.
pub fn control(self: *Sqlite, comptime which: Control) engine.ControlError!void {
    const statement = try controlStatement(self, which);
    defer sqlite.resetCached(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.SqliteExecFailed;
}

pub fn inTransaction(self: *const Sqlite) bool {
    return c.sqlite3_get_autocommit(self.database) == 0;
}

pub fn inWriteTransaction(self: *const Sqlite) bool {
    return c.sqlite3_txn_state(self.database, "main") == c.SQLITE_TXN_WRITE;
}

/// Rows changed since the connection opened, rolled-back changes included.
pub fn totalChanges(self: *const Sqlite) i64 {
    return c.sqlite3_total_changes64(self.database);
}

/// `text`, once it passes `rsql.portabilityError`: for the one data
/// statement opening runs outside the cache and outside a typed statement.
fn portable(comptime text: [:0]const u8) [:0]const u8 {
    if (rsql.portabilityError(text, rsql.reserved_names_checked)) |message| @compileError(message ++ ": " ++ text);
    return text;
}

/// Each control's text. rsql refuses transaction control
/// (`forbidden_words`) because only `control` may run it. A closed set: no
/// other text reaches `cachedStatic` outside test builds.
fn controlSql(comptime which: Control) [:0]const u8 {
    return switch (which) {
        .begin => "BEGIN IMMEDIATE",
        .commit => "COMMIT",
        .rollback => "ROLLBACK",
        // One write at a time holds the batch's one savepoint.
        .savepoint => "SAVEPOINT write",
        .release => "RELEASE write",
        .rollback_to => "ROLLBACK TO write",
    };
}

/// `which`'s prepared form, cached for the Store's lifetime; the caller
/// resets it before the Store runs the next request.
fn controlStatement(self: *Sqlite, comptime which: Control) !*c.sqlite3_stmt {
    return cachedStatic(self, comptime controlSql(which));
}

/// A typed statement's prepared form, cached like `controlStatement`'s.
/// Only a type `rsql.Read` or `rsql.Write` made passes, so its text passed
/// rsql's checks when that type was made (`rsql.isStatement`). A test
/// build also renders `S.mysql`, so it fails on a statement it reaches
/// here that has no MySQL spelling, and hands that text to the live
/// MySQL check (`mysql_dialect_check.shadowPrepare`); a release build
/// renders none.
pub fn cachedTyped(self: *Sqlite, comptime S: type) !*c.sqlite3_stmt {
    comptime if (!rsql.isStatement(S)) @compileError("cachedTyped runs only a type rsql.Read or rsql.Write made: " ++ @typeName(S));
    if (@import("builtin").is_test) @import("../mysql_dialect_check.zig").shadowPrepare(comptime S.mysql.prepared());
    return cachedStatic(self, S.sql);
}

/// A test fixture's or oracle's own text, prepared like `cachedTyped`'s.
/// Unchecked by rsql, and refused outside test builds.
fn fixtureStatement(self: *Sqlite, comptime sql: [:0]const u8) !*c.sqlite3_stmt {
    if (!@import("builtin").is_test) @compileError("test-only Store statement");
    return cachedStatic(self, sql);
}

/// Prepares `sql` once for the Store's lifetime. Reached only through
/// `controlStatement`, `cachedTyped` and `fixtureStatement`, each of which
/// passes static text, so the cache's key never aliases a reused buffer.
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

/// Sets the model of the revision before the current one of the
/// Operation `operation_id`'s Session (`Store.setHistoricalModelForTesting`).
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

/// `Store.damageOutputBagForTesting` on the Operation `operation_id`.
pub fn damageOutputBagForTesting(self: *Sqlite, operation_id: u64) !void {
    const statement = try fixtureStatement(self, "UPDATE content SET payload=CAST(CASE WHEN substr(CAST(payload AS TEXT),1,1)='X' THEN 'Y' ELSE 'X' END || substr(CAST(payload AS TEXT),2) AS BLOB) " ++
        "WHERE content_id=(SELECT extras_content_id FROM model_output_item WHERE operation_id=?1 AND item_ordinal=0)");
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, operation_id);
    try sqlite.expectDone(statement);
    if (c.sqlite3_changes(self.database) != 1) return error.InvalidTestingOutput;
}

/// A Session the touch oracle saw change that `touched` does not hold
/// (`Store.untouchedForTesting`).
pub fn untouchedForTesting(self: *Sqlite, touched: *const change_ring.Touched) ?change_ring.Id {
    // Cached, so a test that counts prepared or uncached statements sees
    // none. A test that makes SQLite fail gets no verdict.
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
