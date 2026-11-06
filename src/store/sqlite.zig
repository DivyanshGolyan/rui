//! The SQLite C binding and the statement-level helpers every Store file uses:
//! preparing, caching and stepping statements, binding parameters and reading columns.

const std = @import("std");
const protocol = @import("../protocol.zig");
const rsql = @import("rsql.zig");
const store_schema = @import("schema.zig");
const change_ring = @import("../change_ring.zig");
pub const c = @import("sqlite");

pub const sqlite_heap_bytes: u64 = 16 * 1024 * 1024;

pub fn diagnosticSignedPragma(database: *c.sqlite3, sql: [:0]const u8) ?i64 {
    const statement = prepare(database, sql) catch return null;
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return null;
    return c.sqlite3_column_int64(statement, 0);
}

pub fn diagnosticUnsignedPragma(database: *c.sqlite3, sql: [:0]const u8) ?u64 {
    const value = diagnosticSignedPragma(database, sql) orelse return null;
    if (value < 0) return null;
    return @intCast(value);
}

pub fn diagnosticTextPragma(
    database: *c.sqlite3,
    sql: [:0]const u8,
) ?protocol.Bounded(16) {
    const statement = prepare(database, sql) catch return null;
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return null;
    var value: protocol.Bounded(16) = .{};
    readText(statement, 0, &value) catch return null;
    return value;
}

pub fn pragmaInt(database: *c.sqlite3, sql: [:0]const u8) !u32 {
    const statement = try prepare(database, sql);
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.PragmaReadFailed;
    const value = c.sqlite3_column_int64(statement, 0);
    if (value < 0 or value > std.math.maxInt(u32)) return error.CorruptStore;
    return @intCast(value);
}

pub fn prepare(database: *c.sqlite3, sql: [:0]const u8) !*c.sqlite3_stmt {
    var statement: ?*c.sqlite3_stmt = null;
    // Callers finalize these short-lived statements; allow SQLite lookaside.
    if (c.sqlite3_prepare_v3(database, sql, -1, 0, &statement, null) != c.SQLITE_OK) {
        return error.StatementPrepareFailed;
    }
    return statement orelse error.StatementPrepareFailed;
}

/// Every statement a Store entry point runs, prepared on first use and kept
/// until `close`. Comptime SQL has static storage, so its address is the key.
/// Bound: one per SQL text in this file, about 175. The Store tests reach 99,
/// holding 600 KB of SQLite heap, so all of them stay near 1 MB of the 16 MB
/// limit, once per Host and independent of Sessions. Open addressing, at
/// most half full, with slots in the SQLite heap.
pub const StatementCache = struct {
    slots: []Slot = &.{},
    count: usize = 0,

    const Slot = struct { sql: ?[*:0]const u8 = null, statement: ?*c.sqlite3_stmt = null };

    /// A cached statement never allocates, so a warm ROLLBACK cannot fail
    /// for memory.
    pub fn find(self: *const StatementCache, sql: [*:0]const u8) ?*c.sqlite3_stmt {
        if (self.slots.len == 0) return null;
        return probe(self.slots, sql).statement;
    }

    pub fn insert(self: *StatementCache, sql: [*:0]const u8, statement: *c.sqlite3_stmt) !void {
        if ((self.count + 1) * 2 > self.slots.len) try self.grow();
        const slot = probe(self.slots, sql);
        std.debug.assert(slot.sql == null);
        slot.* = .{ .sql = sql, .statement = statement };
        self.count += 1;
    }

    fn probe(slots: []Slot, sql: [*:0]const u8) *Slot {
        const mask = slots.len - 1;
        var index = std.hash.int(@intFromPtr(sql)) & mask;
        while (true) : (index = (index + 1) & mask) {
            const slot = &slots[index];
            if (slot.sql == null or slot.sql.? == sql) return slot;
        }
    }

    fn grow(self: *StatementCache) !void {
        const len = @max(64, self.slots.len * 2);
        const memory = c.sqlite3_malloc64(len * @sizeOf(Slot)) orelse return error.OutOfMemory;
        const slots = @as([*]Slot, @ptrCast(@alignCast(memory)))[0..len];
        @memset(slots, .{});
        for (self.slots) |slot| {
            if (slot.sql) |sql| probe(slots, sql).* = slot;
        }
        if (self.slots.len != 0) c.sqlite3_free(self.slots.ptr);
        self.slots = slots;
    }

    /// Evict one idle prepared form without breaking an open-addressed
    /// probe chain. Reinsert the following cluster in place; no allocation.
    pub fn remove(self: *StatementCache, sql: [*:0]const u8) void {
        if (self.slots.len == 0) return;
        const slot = probe(self.slots, sql);
        const statement = slot.statement orelse return;
        std.debug.assert(c.sqlite3_stmt_busy(statement) == 0);
        _ = c.sqlite3_finalize(statement);
        const mask = self.slots.len - 1;
        var index = (@intFromPtr(slot) - @intFromPtr(self.slots.ptr)) / @sizeOf(Slot);
        slot.* = .{};
        self.count -= 1;
        index = (index + 1) & mask;
        while (self.slots[index].sql) |key| {
            const displaced = self.slots[index];
            self.slots[index] = .{};
            probe(self.slots, key).* = displaced;
            index = (index + 1) & mask;
        }
    }

    /// Test aid: every entry point reset each statement it stepped.
    pub fn assertIdle(self: *const StatementCache) void {
        for (self.slots) |slot| {
            if (slot.statement) |statement| std.debug.assert(c.sqlite3_stmt_busy(statement) == 0);
        }
    }

    pub fn deinit(self: *StatementCache) void {
        for (self.slots) |slot| _ = c.sqlite3_finalize(slot.statement);
        if (self.slots.len != 0) c.sqlite3_free(self.slots.ptr);
        self.* = undefined;
    }
};

pub fn resetCached(statement: *c.sqlite3_stmt) void {
    _ = c.sqlite3_reset(statement);
    _ = c.sqlite3_clear_bindings(statement);
    // Clearing bindings expires a statement whose plan read a bound value (a
    // bound LIMIT, or a bind compared with a partial index's WHERE), so every
    // later use would re-prepare it. Debug covers the Host binaries that
    // integration tests drive.
    const builtin = @import("builtin");
    if ((builtin.is_test or builtin.mode == .debug) and c.sqlite3_expired(statement) != 0) {
        std.debug.panic("cached statement plan depends on a bound value: {s}", .{c.sqlite3_sql(statement)});
    }
}

/// Resets a cached statement that was bound but not stepped since its
/// last `resetCached`, such as one queued after a failed step. Its plan
/// read no bound value: SQLite re-prepares with bound values only inside a
/// step, and the `resetCached` after that step would have panicked. So an
/// expiry it carries came from a schema change, which its next step
/// re-prepares for, and the check does not apply.
pub fn resetUnstepped(statement: *c.sqlite3_stmt) void {
    _ = c.sqlite3_reset(statement);
    _ = c.sqlite3_clear_bindings(statement);
}

pub fn exec(database: *c.sqlite3, sql: [:0]const u8) !void {
    if (c.sqlite3_exec(database, sql, null, null, null) != c.SQLITE_OK) return error.SqliteExecFailed;
}

pub fn rollback(database: *c.sqlite3) void {
    _ = c.sqlite3_exec(database, "ROLLBACK", null, null, null);
}

pub fn dbConfig(database: *c.sqlite3, operation: c_int, value: c_int) !void {
    var prior: c_int = 0;
    if (c.sqlite3_db_config(database, operation, value, &prior) != c.SQLITE_OK) {
        return error.SqliteConfigurationFailed;
    }
}

/// The tests' touch oracle watches each table that carries a Session.
/// An inserted or deleted row changes every Session it names
/// (`schema.sessionColumns`); an updated row changes its first Session,
/// and its second too when the update sets a column that Session reads
/// (`schema.readByBoth`).
pub const touch_oracle_tables = .{
    "session",          "session_revision",      "message_admission", "sent_rejection",
    "turn",             "session_stop",          "session_archive",   "model_operation",
    "action_operation", "conversation_entry",    "model_output_item", "model_tool_call",
    "session_change",   "session_skill_catalog",
};

/// Test builds: a temporary trigger on each table that carries a Session
/// notes every Session whose rows change, for `untouchedForTesting`.
/// It precedes every cached statement, so none re-prepares.
pub fn createTouchOracleForTesting(database: *c.sqlite3) !void {
    if (!@import("builtin").is_test) @compileError("test-only oracle");
    try setLimit(database, c.SQLITE_LIMIT_TRIGGER_DEPTH, 1);
    try exec(database, "CREATE TEMP TABLE touched_oracle(session_ref TEXT)");
    inline for (comptime touchOracleTriggers(.sqlite, "touched_oracle")) |text| try exec(database, text);
}

/// The touch oracle's triggers in `dialect`, one statement each, writing
/// each Session they note into the table `oracle`. On each table of
/// `touch_oracle_tables`: INSERT and DELETE note every Session column,
/// UPDATE notes the first, and where the table has columns both Sessions
/// read (`readByBoth`), a further UPDATE trigger notes the other Session
/// columns when one of those columns changes. SQLite fires that one on
/// any assignment to those columns (`UPDATE OF`); MySQL has no `UPDATE OF`,
/// so its trigger compares OLD and NEW with `<=>` and notes only a change.
/// SQLite's are TEMP triggers on `main`.
pub fn touchOracleTriggers(comptime dialect: rsql.Dialect, comptime oracle: []const u8) []const [:0]const u8 {
    comptime {
        var result: []const [:0]const u8 = &.{};
        for (touch_oracle_tables) |table| {
            const sessions = store_schema.sessionColumns(table);
            for ([_][]const u8{ "INSERT", "UPDATE", "DELETE" }) |event| {
                const columns = if (std.mem.eql(u8, event, "UPDATE")) sessions[0..1] else sessions;
                const body = oracleBody(event, columns, oracle);
                result = result ++ .{switch (dialect) {
                    .sqlite => std.fmt.comptimePrint("CREATE TEMP TRIGGER touched_{s}_{s} AFTER {s} ON main.{s} BEGIN {s} END", .{ table, event, event, table, body }),
                    .mysql => std.fmt.comptimePrint("CREATE TRIGGER touched_{s}_{s} AFTER {s} ON {s} FOR EACH ROW BEGIN {s} END", .{ table, event, event, table, body }),
                }};
            }
            const both = store_schema.readByBoth(table);
            if (both.len != 0) {
                const body = oracleBody("UPDATE", sessions[1..], oracle);
                result = result ++ .{switch (dialect) {
                    .sqlite => std.fmt.comptimePrint("CREATE TEMP TRIGGER touched_{s}_UPDATE_sender AFTER UPDATE OF {s} ON main.{s} BEGIN {s} END", .{ table, joined(both, ","), table, body }),
                    .mysql => std.fmt.comptimePrint("CREATE TRIGGER touched_{s}_UPDATE_sender AFTER UPDATE ON {s} FOR EACH ROW BEGIN IF {s} THEN {s} END IF; END", .{ table, table, changed(both), body }),
                }};
            }
        }
        return result;
    }
}

/// `columns` joined by `separator`.
fn joined(comptime columns: []const []const u8, comptime separator: []const u8) []const u8 {
    comptime {
        var text: []const u8 = "";
        for (columns) |column| text = text ++ (if (text.len == 0) "" else separator) ++ column;
        return text;
    }
}

/// A MySQL trigger condition: some column of `columns` changed.
fn changed(comptime columns: []const []const u8) []const u8 {
    comptime {
        var tests: []const []const u8 = &.{};
        for (columns) |column| tests = tests ++ .{"NOT (OLD." ++ column ++ " <=> NEW." ++ column ++ ")"};
        return joined(tests, " OR ");
    }
}

/// A trigger body that notes each of `columns`' Sessions, new and old.
fn oracleBody(comptime event: []const u8, comptime columns: []const []const u8, comptime oracle: []const u8) []const u8 {
    var text: []const u8 = "";
    for (columns) |column| {
        if (!std.mem.eql(u8, event, "DELETE")) text = text ++ "INSERT INTO " ++ oracle ++ " VALUES(NEW." ++ column ++ ");";
        if (!std.mem.eql(u8, event, "INSERT")) text = text ++ "INSERT INTO " ++ oracle ++ " VALUES(OLD." ++ column ++ ");";
    }
    return text;
}

pub fn setLimit(database: *c.sqlite3, category: c_int, value: c_int) !void {
    _ = c.sqlite3_limit(database, category, value);
    if (c.sqlite3_limit(database, category, -1) != value) return error.SqliteLimitConfigurationFailed;
}

/// `rui_served(provider)`: 1 when the opening's served set has the label.
pub fn servedFunction(context: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    std.debug.assert(argc == 1);
    const routes: *const protocol.Routes = @ptrCast(@alignCast(c.sqlite3_user_data(context)));
    const text = c.sqlite3_value_text(argv[0]);
    const length = c.sqlite3_value_bytes(argv[0]);
    const served = if (text == null or length < 0) false else if (std.meta.stringToEnum(protocol.Provider, text[0..@intCast(length)])) |provider|
        protocol.routeOf(routes.*, provider) != .unserved
    else
        false;
    c.sqlite3_result_int(context, @intFromBool(served));
}

pub fn bindText(statement: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text64(statement, index, value.ptr, value.len, null, c.SQLITE_UTF8) != c.SQLITE_OK) {
        return error.BindFailed;
    }
}

pub fn bindOptionalText(statement: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (value.len == 0) {
        if (c.sqlite3_bind_null(statement, index) != c.SQLITE_OK) return error.BindFailed;
    } else try bindText(statement, index, value);
}

pub fn bindBlob(statement: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_blob64(statement, index, value.ptr, value.len, null) != c.SQLITE_OK) return error.BindFailed;
}

pub fn bindI64(statement: *c.sqlite3_stmt, index: c_int, value: anytype) !void {
    if (c.sqlite3_bind_int64(statement, index, @intCast(value)) != c.SQLITE_OK) return error.BindFailed;
}

pub fn bindU64(statement: *c.sqlite3_stmt, index: c_int, value: u64) !void {
    if (value > std.math.maxInt(i64)) return error.IntegerOutOfRange;
    try bindI64(statement, index, value);
}

pub fn bindNullableI64(statement: *c.sqlite3_stmt, index: c_int, value: ?i64) !void {
    const result = if (value) |actual|
        c.sqlite3_bind_int64(statement, index, actual)
    else
        c.sqlite3_bind_null(statement, index);
    if (result != c.SQLITE_OK) return error.BindFailed;
}

pub fn bindNullableU64(statement: *c.sqlite3_stmt, index: c_int, value: ?u64) !void {
    if (value) |present| return bindU64(statement, index, present);
    if (c.sqlite3_bind_null(statement, index) != c.SQLITE_OK) return error.BindFailed;
}

pub fn expectDone(statement: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.StatementFailed;
}

pub fn readText(statement: *c.sqlite3_stmt, index: c_int, destination: anytype) !void {
    try destination.set(try columnText(statement, index));
}

/// The column's text, held to the bound and UTF-8 check a
/// Bounded(capacity) read applies, without copying it into one.
pub fn boundedColumnText(statement: *c.sqlite3_stmt, index: c_int, comptime capacity: usize) ![]const u8 {
    const value = try columnText(statement, index);
    if (value.len > capacity) return error.ValueTooLong;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    return value;
}

/// The column's text as SQLite holds it, valid until the statement next
/// steps or resets.
fn columnText(statement: *c.sqlite3_stmt, index: c_int) ![]const u8 {
    const length = c.sqlite3_column_bytes(statement, index);
    if (length < 0) return error.CorruptStore;
    if (length == 0) return "";
    const pointer = c.sqlite3_column_text(statement, index) orelse return error.CorruptStore;
    const bytes: [*]const u8 = @ptrCast(pointer);
    return bytes[0..@intCast(length)];
}

pub fn maxEnumTagBytes(comptime Enum: type) usize {
    var maximum: usize = 0;
    for (std.meta.tags(Enum)) |value| maximum = @max(maximum, @tagName(value).len);
    return maximum;
}

pub fn readDigest(statement: *c.sqlite3_stmt, index: c_int) ![32]u8 {
    if (c.sqlite3_column_bytes(statement, index) != 32) return error.CorruptStore;
    const pointer = c.sqlite3_column_blob(statement, index) orelse return error.CorruptStore;
    const bytes: [*]const u8 = @ptrCast(pointer);
    return bytes[0..32].*;
}

/// A required positive integer column; anything else is a contradiction.
pub fn readPositive(statement: *c.sqlite3_stmt, index: c_int) !u64 {
    return try readOptionalPositive(statement, index) orelse error.CorruptStore;
}

pub fn readOptionalPositive(statement: *c.sqlite3_stmt, index: c_int) !?u64 {
    if (c.sqlite3_column_type(statement, index) == c.SQLITE_NULL) return null;
    if (c.sqlite3_column_type(statement, index) != c.SQLITE_INTEGER) return error.CorruptStore;
    const value = c.sqlite3_column_int64(statement, index);
    if (value <= 0) return error.CorruptStore;
    return @intCast(value);
}

pub fn readCount(statement: *c.sqlite3_stmt, index: c_int) !u64 {
    if (c.sqlite3_column_type(statement, index) != c.SQLITE_INTEGER) return error.CorruptStore;
    const value = c.sqlite3_column_int64(statement, index);
    if (value < 0) return error.CorruptStore;
    return @intCast(value);
}

/// A BLOB column's bytes, borrowed until the statement steps or resets.
pub fn columnBytes(statement: *c.sqlite3_stmt, index: c_int) []const u8 {
    const length: usize = @intCast(c.sqlite3_column_bytes(statement, index));
    const pointer = c.sqlite3_column_blob(statement, index) orelse return "";
    return @as([*]const u8, @ptrCast(pointer))[0..length];
}

/// The persisted closed grammar is the corruption boundary; a saved effort is
/// trusted after it parses and is never checked against the catalog again.
pub fn readNullableEffort(statement: *c.sqlite3_stmt, index: c_int) !?protocol.ReasoningEffort {
    if (c.sqlite3_column_type(statement, index) == c.SQLITE_NULL) return null;
    if (c.sqlite3_column_type(statement, index) != c.SQLITE_TEXT) return error.CorruptStore;
    var value: protocol.Bounded(16) = .{};
    readText(statement, index, &value) catch return error.CorruptStore;
    return std.meta.stringToEnum(protocol.ReasoningEffort, value.slice()) orelse error.CorruptStore;
}

pub fn bindNullableEffort(statement: *c.sqlite3_stmt, index: c_int, value: ?protocol.ReasoningEffort) !void {
    if (value) |effort| return bindText(statement, index, @tagName(effort));
    if (c.sqlite3_bind_null(statement, index) != c.SQLITE_OK) return error.BindFailed;
}

pub fn readNullableTokens(statement: *c.sqlite3_stmt, index: c_int, allow_zero: bool) !?u64 {
    if (c.sqlite3_column_type(statement, index) == c.SQLITE_NULL) return null;
    if (c.sqlite3_column_type(statement, index) != c.SQLITE_INTEGER) return error.CorruptStore;
    const value = c.sqlite3_column_int64(statement, index);
    if (value < 0 or (!allow_zero and value == 0)) return error.CorruptStore;
    return @intCast(value);
}

/// The longest fixed value a statement binds by value: an `[n]u8` Args
/// field, such as a 32-byte digest or a call's 120-byte field
/// certificate, and a `protocol.Bounded` text.
pub const max_copied_bytes = 256;

/// SQLITE_TRANSIENT, the destructor -1: SQLite copies a value bound with
/// it before the bind returns, so the caller's bytes may change at once.
/// Read through an extern union, since -1 is no aligned function address
/// and `@ptrFromInt` refuses it on targets that align functions.
var transient: extern union { bits: usize, destructor: c.sqlite3_destructor_type } = .{ .bits = std.math.maxInt(usize) };

/// Binds a typed statement's `Args` as ?1..?N, then `now` as ?(N+1) when
/// the text uses @now. Integers, `[n]u8` arrays, `protocol.Bounded` texts
/// and a SessionHead's reference are copied into the
/// statement when it is bound: SQLite holds the copy, in its own heap,
/// until the statement is rebound or reset, so a caller may reuse their
/// memory at once. Only a `[]const u8` text and an `rsql.Bytes` blob are
/// read in place when a pass steps the statement, so their bytes must not
/// change before then (`Access` checks this in Debug and test builds).
/// Enum tag names are static.
pub fn bindArgs(statement: *c.sqlite3_stmt, comptime S: type, args: *const S.Args, now: i64) !void {
    const info = @typeInfo(S.Args).@"struct";
    inline for (info.field_names, info.field_types, 1..) |name, Field, index| {
        try bindValue(statement, index, Field, @field(args, name));
    }
    if (S.uses_now) try bindI64(statement, info.field_names.len + 1, now);
}

/// Whether binding a `T` reads the caller's bytes in place when its pass
/// steps it, rather than copying them when it is bound.
pub fn borrows(comptime T: type) bool {
    if (T == []const u8 or T == rsql.Bytes) return true;
    return switch (@typeInfo(T)) {
        .optional => |optional| borrows(optional.child),
        else => false,
    };
}

/// The bytes a borrowed argument binds in place (`borrows`), or null.
pub fn borrowed(comptime T: type, value: T) ?[]const u8 {
    if (T == []const u8) return value;
    if (T == rsql.Bytes) return value.bytes;
    return switch (@typeInfo(T)) {
        .optional => |optional| if (value) |present| borrowed(optional.child, present) else null,
        else => null,
    };
}

fn bindCopied(statement: *c.sqlite3_stmt, index: c_int, bytes: []const u8, comptime text: bool) !void {
    const result = if (text)
        c.sqlite3_bind_text64(statement, index, bytes.ptr, bytes.len, transient.destructor, c.SQLITE_UTF8)
    else
        c.sqlite3_bind_blob64(statement, index, bytes.ptr, bytes.len, transient.destructor);
    if (result != c.SQLITE_OK) return error.BindFailed;
}

fn bindValue(statement: *c.sqlite3_stmt, index: c_int, comptime T: type, value: T) !void {
    // An empty slice may carry any address; "" is a real one, so it binds '' and not NULL.
    if (T == []const u8) return bindText(statement, index, if (value.len == 0) "" else value);
    if (T == rsql.Positive) return bindU64(statement, index, value.get());
    if (T == rsql.Bytes) return bindBlob(statement, index, value.bytes);
    if (T == rsql.SessionHead) return bindCopied(statement, index, &value.ref, true);
    if (comptime isBounded(T)) {
        comptime std.debug.assert(@typeInfo(@FieldType(T, "bytes")).array.len <= max_copied_bytes);
        return bindCopied(statement, index, if (value.len == 0) "" else value.slice(), true);
    }
    switch (@typeInfo(T)) {
        .optional => |optional| if (value) |present| try bindValue(statement, index, optional.child, present) else {
            if (c.sqlite3_bind_null(statement, index) != c.SQLITE_OK) return error.BindFailed;
        },
        .bool => try bindI64(statement, index, @as(i64, @intFromBool(value))),
        .int => try bindU64(statement, index, value),
        // Tag names are static.
        .@"enum" => try bindText(statement, index, @tagName(value)),
        .array => |array| {
            if (array.child != u8 or array.len > max_copied_bytes) @compileError("rsql: an Args array is [n]u8 of at most max_copied_bytes, bound by value");
            try bindCopied(statement, index, &value, false);
        },
        .pointer => @compileError("rsql: " ++ @typeName(T) ++ " would be read when its pass runs, after its owner may change it; bind a [n]u8 by value"),
        else => @compileError("rsql: " ++ @typeName(T) ++ " is not a typed statement value"),
    }
}

/// Fills `row` from the current row, field by field in place, so a Row
/// over 1 KiB is never copied. A pointer field fills what it points to
/// (`rsql.fillsInPlace`). Every value that breaks its type is
/// `CorruptStore`, here and nowhere else.
pub fn decodeRow(comptime Row: type, statement: *c.sqlite3_stmt, row: *Row) error{CorruptStore}!void {
    comptime var column: c_int = 0;
    const info = @typeInfo(Row).@"struct";
    inline for (info.field_names, info.field_types) |name, Field| {
        decodeValue(Field, statement, column, &@field(row, name)) catch return error.CorruptStore;
        column += if (Field == rsql.SessionHead) 3 else 1;
    }
}

/// Whether `T` is an `rsql.Blob`: bytes up to its capacity.
fn isBlob(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "blob_capacity") and T == rsql.Blob(T.blob_capacity);
}

/// Whether `T` is a `protocol.Bounded`: text up to its capacity.
fn isBounded(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasField(T, "bytes")) return false;
    const bytes = @typeInfo(@FieldType(T, "bytes"));
    return bytes == .array and T == protocol.Bounded(bytes.array.len);
}

fn decodeValue(comptime T: type, statement: *c.sqlite3_stmt, column: c_int, out: *T) !void {
    if (T == rsql.SessionHead) {
        const ref = try columnText(statement, column);
        if (ref.len != @sizeOf(@FieldType(rsql.SessionHead, "ref"))) return error.CorruptStore;
        out.* = .{
            .ref = ref[0..@sizeOf(@FieldType(rsql.SessionHead, "ref"))].*,
            .workspace_key = .of(try readPositive(statement, column + 1)),
            .next_position = .of(try readPositive(statement, column + 2)),
        };
        return;
    }
    if (T == rsql.Positive) {
        out.* = .of(try readPositive(statement, column));
        return;
    }
    // Text goes straight into the Row's own bytes.
    if (comptime isBounded(T)) return out.set(try columnText(statement, column));
    if (comptime isBlob(T)) {
        // The type first: reading the bytes may convert the value.
        if (c.sqlite3_column_type(statement, column) != c.SQLITE_BLOB) return error.CorruptStore;
        const bytes = columnBytes(statement, column);
        if (bytes.len > T.blob_capacity) return error.CorruptStore;
        @memcpy(out.bytes[0..bytes.len], bytes);
        out.len = @intCast(bytes.len);
        return;
    }
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            comptime std.debug.assert(pointer.size == .one);
            try decodeValue(pointer.child, statement, column, out.*);
        },
        .optional => |optional| {
            if (c.sqlite3_column_type(statement, column) == c.SQLITE_NULL) {
                out.* = null;
            } else if (comptime isBounded(optional.child) or isBlob(optional.child)) {
                // Naming only `len` leaves the bytes unwritten until `set` fills them.
                out.* = optional.child{ .len = 0 };
                try decodeValue(optional.child, statement, column, &out.*.?);
            } else {
                var present: optional.child = undefined;
                try decodeValue(optional.child, statement, column, &present);
                out.* = present;
            }
        },
        .bool => out.* = switch (try readCount(statement, column)) {
            0 => false,
            1 => true,
            else => return error.CorruptStore,
        },
        .int => out.* = std.math.cast(T, try readCount(statement, column)) orelse return error.CorruptStore,
        .@"enum" => out.* = std.meta.stringToEnum(T, try columnText(statement, column)) orelse return error.CorruptStore,
        // A blob of exactly the array's length, such as a digest.
        .array => |array| {
            comptime std.debug.assert(array.child == u8);
            // The type first: reading the bytes may convert the value.
            if (c.sqlite3_column_type(statement, column) != c.SQLITE_BLOB) return error.CorruptStore;
            const bytes = columnBytes(statement, column);
            if (bytes.len != array.len) return error.CorruptStore;
            @memcpy(out, bytes);
        },
        else => @compileError("rsql: " ++ @typeName(T) ++ " is not a typed statement value"),
    }
}
