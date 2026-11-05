//! Text-protocol result rows into typed Rows, the MySQL twin of
//! `sqlite.decodeRow`. Each value streams from the receive buffer straight
//! into its field, so no row is copied whole and nothing grows with a value.
//!
//! A value is held to its field's type as SQLite's decoding holds it:
//! integers are decimal digits of an integer column, at most the largest
//! BIGINT and never negative; a `bool` is only 0 or 1; an `rsql.Positive`
//! is above 0; `[n]u8` and `rsql.Blob` come only from a binary string
//! column, `[n]u8` of exactly n bytes; text (`Bounded`, an enum tag, a
//! SessionHead's reference) is UTF-8 within its bound, from any column, as
//! SQLite reads any value as text. Anything else is `CorruptStore`.
//!
//! The decoder reads its events from a `source`: anything with
//! `fn next() !mysql.Event`, such as `mysql_connection.Connection`. After a
//! failure the rest of the result is still due; its owner drains it.
const std = @import("std");
const Bounded = @import("../bounded.zig").Bounded;
const mysql = @import("wire/mysql.zig");
const rsql = @import("rsql.zig");

/// MySQL's `binary` character set: a column of bytes, not text. Numbers
/// carry it too, so a column of bytes is a string type with it.
const binary_charset = 63;

/// What a value of a column may decode to.
pub const Kind = enum(u8) {
    integer,
    /// A string or blob of bytes.
    bytes,
    other,
};

pub fn kindOf(column: mysql.Column) Kind {
    return switch (column.type) {
        // A DECIMAL is what MySQL's SUM of integers returns; its digits
        // still parse only when it has no fraction.
        .tiny, .short, .long, .longlong, .int24, .decimal, .newdecimal => .integer,
        .varchar, .var_string, .string, .tiny_blob, .medium_blob, .long_blob, .blob => if (column.charset == binary_charset) .bytes else .other,
        else => .other,
    };
}

/// The columns `Row` decodes: one per field, three for a SessionHead.
pub fn columnCount(comptime Row: type) usize {
    var count: usize = 0;
    for (@typeInfo(Row).@"struct".field_types) |Field| count += if (Field == rsql.SessionHead) 3 else 1;
    return count;
}

/// A result set's column kinds, which every row of it is checked against.
pub fn Columns(comptime Row: type) type {
    return struct { kinds: [columnCount(Row)]Kind };
}

/// After a `.columns` event of `count`: reads the `.column` events that
/// follow. A count other than `Row`'s is `CorruptStore`.
pub fn readColumns(comptime Row: type, source: anytype, count: u16) !Columns(Row) {
    if (count != columnCount(Row)) return error.CorruptStore;
    var columns: Columns(Row) = undefined;
    for (&columns.kinds) |*kind| switch (try source.next()) {
        .column => |column| kind.* = kindOf(column),
        else => return error.ProtocolViolation,
    };
    return columns;
}

/// After a `.row` event: reads its values into `row`, field by field in
/// place. A pointer field fills what it points to (`rsql.fillsInPlace`).
pub fn decodeRow(comptime Row: type, columns: *const Columns(Row), source: anytype, row: *Row) !void {
    comptime var column: usize = 0;
    const info = @typeInfo(Row).@"struct";
    inline for (info.field_names, info.field_types) |name, Field| {
        if (Field == rsql.SessionHead) {
            try decodeHead(columns.kinds[column..][0..3], source, &@field(row, name));
            column += 3;
        } else {
            try decodeValue(Field, columns.kinds[column], try nextValue(source), source, &@field(row, name));
            column += 1;
        }
    }
}

fn nextValue(source: anytype) !?u32 {
    return switch (try source.next()) {
        .value => |len| len,
        else => error.ProtocolViolation,
    };
}

/// Reads a value's `destination.len` bytes into `destination`.
fn readBytes(source: anytype, destination: []u8) !void {
    var filled: usize = 0;
    while (filled < destination.len) switch (try source.next()) {
        .bytes => |bytes| {
            if (bytes.len > destination.len - filled) return error.ProtocolViolation;
            @memcpy(destination[filled..][0..bytes.len], bytes);
            filled += bytes.len;
        },
        else => return error.ProtocolViolation,
    };
}

/// A present integer value: decimal digits of at most the largest BIGINT.
fn readCount(kind: Kind, len: ?u32, source: anytype) !u64 {
    const n = len orelse return error.CorruptStore;
    const max_digits = comptime std.fmt.count("{d}", .{std.math.maxInt(i64)});
    if (kind != .integer or n == 0 or n > max_digits) return error.CorruptStore;
    var digits: [max_digits]u8 = undefined;
    try readBytes(source, digits[0..n]);
    var value: u64 = 0;
    for (digits[0..n]) |digit| {
        if (digit < '0' or digit > '9') return error.CorruptStore;
        value = value * 10 + (digit - '0');
    }
    if (value > std.math.maxInt(i64)) return error.CorruptStore;
    return value;
}

fn readPositive(kind: Kind, len: ?u32, source: anytype) !rsql.Positive {
    const value = try readCount(kind, len, source);
    if (value == 0) return error.CorruptStore;
    return .of(value);
}

/// Text of at most `destination.len` bytes, into its front.
fn readText(len: ?u32, source: anytype, destination: []u8) ![]const u8 {
    const n = len orelse return error.CorruptStore;
    if (n > destination.len) return error.CorruptStore;
    try readBytes(source, destination[0..n]);
    if (!std.unicode.utf8ValidateSlice(destination[0..n])) return error.CorruptStore;
    return destination[0..n];
}

fn decodeHead(kinds: *const [3]Kind, source: anytype, out: *rsql.SessionHead) !void {
    const Ref = @FieldType(rsql.SessionHead, "ref");
    var ref: Ref = undefined;
    if ((try readText(try nextValue(source), source, &ref)).len != ref.len) return error.CorruptStore;
    const workspace_key = try readPositive(kinds[1], try nextValue(source), source);
    out.* = .{ .ref = ref, .workspace_key = workspace_key, .next_position = try readPositive(kinds[2], try nextValue(source), source) };
}

/// Whether `T` is an `rsql.Blob`: bytes up to its capacity.
fn isBlob(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "blob_capacity") and T == rsql.Blob(T.blob_capacity);
}

/// Whether `T` is a `Bounded` text.
fn isBounded(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasField(T, "bytes")) return false;
    const bytes = @typeInfo(@FieldType(T, "bytes"));
    return bytes == .array and T == Bounded(bytes.array.len);
}

fn maxTagBytes(comptime Enum: type) usize {
    var maximum: usize = 0;
    for (std.meta.tags(Enum)) |value| maximum = @max(maximum, @tagName(value).len);
    return maximum;
}

/// Decodes the value whose `.value` event said `len` into `out`.
fn decodeValue(comptime T: type, kind: Kind, len: ?u32, source: anytype, out: *T) !void {
    if (T == rsql.SessionHead) @compileError("rsql: a SessionHead is a Row field of its own, never optional or behind a pointer");
    if (T == rsql.Positive) {
        out.* = try readPositive(kind, len, source);
        return;
    }
    if (comptime isBounded(T)) {
        out.len = (try readText(len, source, &out.bytes)).len;
        return;
    }
    if (comptime isBlob(T)) {
        const n = len orelse return error.CorruptStore;
        if (kind != .bytes or n > T.blob_capacity) return error.CorruptStore;
        try readBytes(source, out.bytes[0..n]);
        out.len = @intCast(n);
        return;
    }
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            comptime std.debug.assert(pointer.size == .one);
            try decodeValue(pointer.child, kind, len, source, out.*);
        },
        .optional => |optional| {
            if (len == null) {
                out.* = null;
            } else if (comptime isBounded(optional.child) or isBlob(optional.child)) {
                // Naming only `len` leaves the bytes unwritten until they arrive.
                out.* = optional.child{ .len = 0 };
                try decodeValue(optional.child, kind, len, source, &out.*.?);
            } else {
                var present: optional.child = undefined;
                try decodeValue(optional.child, kind, len, source, &present);
                out.* = present;
            }
        },
        .bool => out.* = switch (try readCount(kind, len, source)) {
            0 => false,
            1 => true,
            else => return error.CorruptStore,
        },
        .int => out.* = std.math.cast(T, try readCount(kind, len, source)) orelse return error.CorruptStore,
        .@"enum" => {
            var tag: [maxTagBytes(T)]u8 = undefined;
            out.* = std.meta.stringToEnum(T, try readText(len, source, &tag)) orelse return error.CorruptStore;
        },
        // Bytes of exactly the array's length, such as a digest.
        .array => |array| {
            comptime std.debug.assert(array.child == u8);
            if (kind != .bytes or len != array.len) return error.CorruptStore;
            try readBytes(source, out);
        },
        else => @compileError("rsql: " ++ @typeName(T) ++ " is not a typed statement value"),
    }
}

/// Events as a test hands them out, each value's bytes split `split` at a
/// time, as a receive buffer would cut them.
const Script = struct {
    events: []const mysql.Event,
    split: usize,
    at: usize = 0,
    /// Of the `.bytes` event at `at`, the part already handed out.
    offset: usize = 0,

    pub fn next(self: *Script) error{EndOfScript}!mysql.Event {
        if (self.at == self.events.len) return error.EndOfScript;
        const event = self.events[self.at];
        if (event != .bytes) {
            self.at += 1;
            return event;
        }
        const rest = event.bytes[self.offset..];
        const n = @min(rest.len, self.split);
        self.offset += n;
        if (self.offset == event.bytes.len) {
            self.at += 1;
            self.offset = 0;
        }
        return .{ .bytes = rest[0..n] };
    }
};

fn column(column_type: mysql.ColumnType, charset: u16) mysql.Event {
    return .{ .column = .{ .name = "c", .type = column_type, .flags = @bitCast(@as(u16, 0)), .charset = charset };
}

const utf8mb4_0900_bin = 309;
const integer_column = column(.longlong, binary_charset);
const bytes_column = column(.blob, binary_charset);
const text_column = column(.var_string, utf8mb4_0900_bin);

/// A value's events as the client emits them: no `.bytes` for an empty one.
fn value(comptime text: []const u8) [if (text.len == 0) 1 else 2]mysql.Event {
    return if (text.len == 0) .{.{ .value = 0 }} else .{ .{ .value = text.len }, .{ .bytes = text } };
}

/// Decodes one row of `events` (a result's column events, then the row's
/// values) at every split.
fn decodeAll(comptime Row: type, events: []const mysql.Event, row: *Row) !void {
    var largest: usize = 1;
    for (events) |event| if (event == .bytes) {
        largest = @max(largest, event.bytes.len);
    };
    for (1..largest + 1) |split| {
        var script: Script = .{ .events = events, .split = split };
        const columns = try readColumns(Row, &script, @intCast(columnCount(Row)));
        try decodeRow(Row, &columns, &script, row);
        try std.testing.expectEqual(events.len, script.at);
    }
}

const Tag = enum { open, closed_for_good };

test "a row decodes each field type, its values streamed in pieces" {
    const Row = struct {
        id: rsql.Positive,
        count: u32,
        flag: bool,
        tag: Tag,
        digest: [3]u8,
        head: rsql.SessionHead,
        label: Bounded(8),
        blob: rsql.Blob(4),
        missing: ?u64,
        absent_label: ?Bounded(4),
        present_label: ?Bounded(4),
        into: *Bounded(16),
    };
    const events = [_]mysql.Event{
        integer_column, integer_column, integer_column, text_column, bytes_column, text_column, integer_column, integer_column,
        text_column,    bytes_column,   integer_column, text_column, text_column,  text_column,
    } ++ value("9223372036854775807") ++ value("0") ++ value("1") ++ value("closed_for_good") ++ value("\x00\xff\x10") ++
        value("abc123") ++ value("7") ++ value("8") ++ value("é!") ++ value("") ++
        [_]mysql.Event{ .{ .value = null }, .{ .value = null } } ++ value("ok") ++ value("in place");
    var target: Bounded(16) = .{ .len = 0 };
    var row: Row = undefined;
    row.into = &target;
    try decodeAll(Row, &events, &row);
    try std.testing.expectEqual(std.math.maxInt(i64), row.id.get());
    try std.testing.expectEqual(0, row.count);
    try std.testing.expect(row.flag);
    try std.testing.expectEqual(Tag.closed_for_good, row.tag);
    try std.testing.expectEqualSlices(u8, "\x00\xff\x10", &row.digest);
    try std.testing.expectEqualSlices(u8, "abc123", &row.head.ref);
    try std.testing.expectEqual(7, row.head.workspace_key.get());
    try std.testing.expectEqual(8, row.head.next_position.get());
    try std.testing.expectEqualStrings("é!", row.label.slice());
    try std.testing.expectEqual(0, row.blob.len);
    try std.testing.expectEqual(null, row.missing);
    try std.testing.expectEqual(null, row.absent_label);
    try std.testing.expectEqualStrings("ok", row.present_label.?.slice());
    try std.testing.expectEqualStrings("in place", target.slice());
}

fn expectCorrupt(comptime Field: type, kind: mysql.Event, events: []const mysql.Event) !void {
    const Row = struct { field: Field };
    var script: Script = .{ .events = events, .split = 1 };
    const columns: Columns(Row) = .{ .kinds = .{kindOf(kind.column)} };
    var row: Row = undefined;
    try std.testing.expectError(error.CorruptStore, decodeRow(Row, &columns, &script, &row));
}

test "a value that breaks its field's type is CorruptStore" {
    // Integers: digits only, within BIGINT, never negative, from an integer column.
    try expectCorrupt(u64, integer_column, &value("-1"));
    try expectCorrupt(u64, integer_column, &value("9223372036854775808"));
    try expectCorrupt(u64, integer_column, &value("12345678901234567890"));
    try expectCorrupt(u64, integer_column, &value("1.5"));
    try expectCorrupt(u64, integer_column, &value(""));
    try expectCorrupt(u64, text_column, &value("1"));
    try expectCorrupt(u8, integer_column, &value("256"));
    try expectCorrupt(rsql.Positive, integer_column, &value("0"));
    try expectCorrupt(bool, integer_column, &value("2"));
    try expectCorrupt(u64, integer_column, &.{.{ .value = null }});
    // Bytes: from a binary column only, a digest of its exact length.
    try expectCorrupt([2]u8, text_column, &value("ab"));
    try expectCorrupt([2]u8, column(.long, binary_charset), &value("12"));
    try expectCorrupt([2]u8, bytes_column, &value("abc"));
    try expectCorrupt(rsql.Blob(2), bytes_column, &value("abc"));
    try expectCorrupt(rsql.Blob(2), text_column, &value("ab"));
    // Text: within its bound, UTF-8, a known tag.
    try expectCorrupt(Bounded(2), text_column, &value("abc"));
    try expectCorrupt(Bounded(2), text_column, &value("\xff"));
    try expectCorrupt(Tag, text_column, &value("shut"));
    try expectCorrupt(Tag, text_column, &value("closed_for_good!"));
    try expectCorrupt(Bounded(2), text_column, &.{.{ .value = null }});
}

test "a result of another column count is CorruptStore" {
    const Row = struct { a: u64, head: rsql.SessionHead };
    var script: Script = .{ .events = &.{}, .split = 1 };
    try std.testing.expectError(error.CorruptStore, readColumns(Row, &script, 2));
    try std.testing.expectEqual(4, columnCount(Row));
}

test "column kinds: integers and DECIMAL, bytes by the binary character set" {
    try std.testing.expectEqual(Kind.integer, kindOf(column(.newdecimal, binary_charset).column));
    try std.testing.expectEqual(Kind.integer, kindOf(column(.tiny, binary_charset).column));
    try std.testing.expectEqual(Kind.bytes, kindOf(column(.var_string, binary_charset).column));
    try std.testing.expectEqual(Kind.bytes, kindOf(column(.medium_blob, binary_charset).column));
    try std.testing.expectEqual(Kind.other, kindOf(column(.medium_blob, utf8mb4_0900_bin).column));
    try std.testing.expectEqual(Kind.other, kindOf(column(.datetime, binary_charset).column));
}
