//! The SQLite C binding and the statement-level helpers every Store file uses:
//! preparing, caching and stepping statements, binding parameters and reading columns.

const std = @import("std");
const protocol = @import("../protocol.zig");
const tool_catalog = @import("../tools.zig");
const rsql = @import("rsql.zig");
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

/// SQLite binds the text without copying it, so it borrows the caller's
/// Label, never a by-value copy that ends with this call.
pub fn bindOptionalLabel(statement: *c.sqlite3_stmt, index: c_int, label: *const ?protocol.Bounded(protocol.max_label_bytes)) !void {
    if (label.*) |*value| try bindText(statement, index, value.slice()) else try bindNullableI64(statement, index, null);
}

pub fn readNullableLabel(statement: *c.sqlite3_stmt, column: c_int) !?protocol.Bounded(protocol.max_label_bytes) {
    if (c.sqlite3_column_type(statement, column) == c.SQLITE_NULL) return null;
    var label: protocol.Bounded(protocol.max_label_bytes) = .{};
    try readText(statement, column, &label);
    if (!protocol.validLabel(label.slice())) return error.CorruptStore;
    return label;
}

pub fn readPositiveU64(statement: *c.sqlite3_stmt, column: c_int) !u64 {
    const value = c.sqlite3_column_int64(statement, column);
    if (value <= 0) return error.CorruptStore;
    return @intCast(value);
}

pub fn readPermissionMode(statement: *c.sqlite3_stmt, column: c_int) !u8 {
    const permission = c.sqlite3_column_int(statement, column);
    if (permission < 0 or permission > 1) return error.CorruptStore;
    return @intCast(permission);
}

pub fn readToolsMask(statement: *c.sqlite3_stmt, column: c_int) !u8 {
    const tools = c.sqlite3_column_int(statement, column);
    if (tools < 0 or tools > tool_catalog.toolBit(.bash)) return error.CorruptStore;
    return @intCast(tools);
}

pub fn readProvider(statement: *c.sqlite3_stmt, column: c_int) !protocol.Provider {
    var name: protocol.Bounded(protocol.max_provider_bytes) = .{};
    try readText(statement, column, &name);
    return std.meta.stringToEnum(protocol.Provider, name.slice()) orelse error.CorruptStore;
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

/// Test builds: a temporary trigger on each table that carries a Session
/// notes every Session whose rows change, for `untouchedForTesting`.
/// It precedes every cached statement, so none re-prepares.
pub fn createTouchOracleForTesting(database: *c.sqlite3) !void {
    if (!@import("builtin").is_test) @compileError("test-only oracle");
    try setLimit(database, c.SQLITE_LIMIT_TRIGGER_DEPTH, 1);
    try exec(database, "CREATE TEMP TABLE touched_oracle(session_ref TEXT)");
    // Each table that carries a Session: the columns naming the Sessions a
    // new or removed row changes, then those an updated row changes. An
    // admission's sender, position, content and time are written once, so
    // an update changes only its recipient.
    const owners = .{
        .{ "session", .{"session_ref"}, .{"session_ref"} },
        .{ "session_revision", .{"session_ref"}, .{"session_ref"} },
        .{ "message_admission", .{ "session_ref", "sender_session_ref" }, .{"session_ref"} },
        .{ "sent_rejection", .{"sender_session_ref"}, .{"sender_session_ref"} },
        .{ "turn", .{"session_ref"}, .{"session_ref"} },
        .{ "session_stop", .{"session_ref"}, .{"session_ref"} },
        .{ "model_operation", .{"session_ref"}, .{"session_ref"} },
        .{ "action_operation", .{"session_ref"}, .{"session_ref"} },
        .{ "conversation_entry", .{"session_ref"}, .{"session_ref"} },
        .{ "model_output_item", .{"session_ref"}, .{"session_ref"} },
    };
    inline for (owners) |owner| {
        inline for (.{ "INSERT", "UPDATE", "DELETE" }) |event| {
            const body = comptime blk: {
                var text: []const u8 = "";
                const columns = if (std.mem.eql(u8, event, "UPDATE")) owner[2] else owner[1];
                for (columns) |column| {
                    if (!std.mem.eql(u8, event, "DELETE")) text = text ++ "INSERT INTO touched_oracle VALUES(NEW." ++ column ++ ");";
                    if (!std.mem.eql(u8, event, "INSERT")) text = text ++ "INSERT INTO touched_oracle VALUES(OLD." ++ column ++ ");";
                }
                break :blk text;
            };
            try exec(database, std.fmt.comptimePrint("CREATE TEMP TRIGGER touched_{s}_{s} AFTER {s} ON main.{s} BEGIN {s} END", .{ owner[0], event, event, owner[0], body }));
        }
    }
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

/// A positive id column, or null for SQL NULL.
pub fn optionalColumnId(statement: *c.sqlite3_stmt, column: c_int) ?i64 {
    if (c.sqlite3_column_type(statement, column) == c.SQLITE_NULL) return null;
    return c.sqlite3_column_int64(statement, column);
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

pub fn readNullablePositiveI64(statement: *c.sqlite3_stmt, index: c_int) !?i64 {
    if (c.sqlite3_column_type(statement, index) == c.SQLITE_NULL) return null;
    const value = c.sqlite3_column_int64(statement, index);
    if (value <= 0) return error.InvalidIdentity;
    return value;
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

/// Binds a typed statement's `Args` as ?1..?N, then `now` as ?(N+1) when
/// the text uses @now.
pub fn bindArgs(statement: *c.sqlite3_stmt, comptime S: type, args: *const S.Args, now: i64) !void {
    const info = @typeInfo(S.Args).@"struct";
    inline for (info.field_names, info.field_types, 1..) |name, Field, index| try bindValue(statement, index, Field, @field(args, name));
    if (S.uses_now) try bindI64(statement, info.field_names.len + 1, now);
}

fn bindValue(statement: *c.sqlite3_stmt, index: c_int, comptime T: type, value: T) !void {
    if (T == rsql.SessionHead) return bindCopied(statement, index, &value.ref);
    if (T == []const u8) return bindCopied(statement, index, value);
    if (T == rsql.Positive) return bindU64(statement, index, value.get());
    switch (@typeInfo(T)) {
        .optional => |optional| if (value) |present| try bindValue(statement, index, optional.child, present) else {
            if (c.sqlite3_bind_null(statement, index) != c.SQLITE_OK) return error.BindFailed;
        },
        .bool => try bindI64(statement, index, @as(i64, @intFromBool(value))),
        .int => try bindU64(statement, index, value),
        // Tag names are static, so SQLite may borrow them.
        .@"enum" => try bindText(statement, index, @tagName(value)),
        .array => |array| {
            comptime std.debug.assert(array.child == u8);
            const copy = try sqliteCopy(&value);
            if (c.sqlite3_bind_blob64(statement, index, copy, value.len, c.sqlite3_free) != c.SQLITE_OK) return error.BindFailed;
        },
        else => @compileError("rsql: " ++ @typeName(T) ++ " is not a typed statement value"),
    }
}

/// A typed statement is bound when queued and stepped when its round runs,
/// after the caller's arguments are gone, so SQLite owns a copy and frees it.
/// Not SQLITE_TRANSIENT: Zig refuses its address, -1, as a function pointer
/// on aarch64.
fn bindCopied(statement: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    // Empty text has no bytes to outlive.
    if (value.len == 0) return bindText(statement, index, "");
    const copy = try sqliteCopy(value);
    if (c.sqlite3_bind_text64(statement, index, copy, value.len, c.sqlite3_free, c.SQLITE_UTF8) != c.SQLITE_OK) return error.BindFailed;
}

/// `bytes` in memory SQLite frees; a bind frees it even when it fails.
fn sqliteCopy(bytes: []const u8) error{OutOfMemory}![*]u8 {
    const copy: [*]u8 = @ptrCast(c.sqlite3_malloc64(bytes.len) orelse return error.OutOfMemory);
    @memcpy(copy[0..bytes.len], bytes);
    return copy;
}

/// The current row as `Row`. Every value that breaks its type is
/// `CorruptStore`, here and nowhere else.
pub fn decodeRow(comptime Row: type, statement: *c.sqlite3_stmt) error{CorruptStore}!Row {
    var row: Row = undefined;
    comptime var column: c_int = 0;
    const info = @typeInfo(Row).@"struct";
    inline for (info.field_names, info.field_types) |name, Field| {
        @field(row, name) = decodeValue(Field, statement, column) catch return error.CorruptStore;
        column += if (Field == rsql.SessionHead) 3 else 1;
    }
    return row;
}

fn decodeValue(comptime T: type, statement: *c.sqlite3_stmt, column: c_int) !T {
    if (T == rsql.SessionHead) {
        const ref = try columnText(statement, column);
        if (ref.len != @sizeOf(@FieldType(rsql.SessionHead, "ref"))) return error.CorruptStore;
        return .{
            .ref = ref[0..@sizeOf(@FieldType(rsql.SessionHead, "ref"))].*,
            .workspace_key = .of(try readPositive(statement, column + 1)),
            .next_position = .of(try readPositive(statement, column + 2)),
        };
    }
    if (T == rsql.Positive) return .of(try readPositive(statement, column));
    switch (@typeInfo(T)) {
        .optional => |optional| {
            if (c.sqlite3_column_type(statement, column) == c.SQLITE_NULL) return null;
            return try decodeValue(optional.child, statement, column);
        },
        .bool => return switch (try readCount(statement, column)) {
            0 => false,
            1 => true,
            else => error.CorruptStore,
        },
        .int => return std.math.cast(T, try readCount(statement, column)) orelse error.CorruptStore,
        .@"enum" => return std.meta.stringToEnum(T, try columnText(statement, column)) orelse error.CorruptStore,
        .array => {
            comptime std.debug.assert(T == [32]u8);
            return readDigest(statement, column);
        },
        else => @compileError("rsql: " ++ @typeName(T) ++ " is not a typed statement value"),
    }
}
