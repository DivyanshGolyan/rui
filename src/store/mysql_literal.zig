//! A typed statement's arguments as MySQL literal text: an rsql
//! `Template`'s parts, with each `Slot` written as a literal. Integers are
//! decimal, booleans 0 or 1, bytes `X'hex'`, text and enum tags
//! `_utf8mb4 X'hex' COLLATE utf8mb4_0900_bin`, and null `NULL`. Hex leaves
//! nothing to escape, and the collation keeps a comparison of two literals
//! binary, as a comparison of two columns is.
//!
//! `length` gives a statement's exact length before anything is written,
//! so its caller knows whether it fits the open batch, or can frame a
//! COM_QUERY for one it streams, and then `write` writes exactly that.
//! Nothing is copied whole: `write` hex-encodes through the writer's buffer.
const std = @import("std");
const Bounded = @import("../bounded.zig").Bounded;
const protocol = @import("../protocol.zig");
const rsql = @import("rsql.zig");

const text_head = "_utf8mb4 X'";
const text_tail = "' COLLATE utf8mb4_0900_bin";
const bytes_head = "X'";
const bytes_tail = "'";
const null_text = "NULL";

/// What a statement's slots other than its arguments take: the Access's
/// second for `@now`, and the opening's served providers for `@served`.
pub const Bound = struct {
    now: i64,
    served: *const protocol.Routes,
};

/// An integer argument above the largest BIGINT, which SQLite also refuses
/// to bind (`sqlite.bindU64`).
pub const Error = error{IntegerOutOfRange};

/// The length of `template` with `args` and `bound` in its slots, as
/// `write` writes it.
pub fn length(comptime template: rsql.Template, comptime Args: type, args: *const Args, bound: Bound) Error!usize {
    var total: usize = comptime partsLength(template);
    inline for (template.slots) |slot| total += try slotLength(Args, slot, args, bound);
    return total;
}

/// Writes `template` with its slots filled. `length` must have accepted
/// the same values: an integer out of range is a programmer error here.
pub fn write(comptime template: rsql.Template, comptime Args: type, args: *const Args, bound: Bound, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(template.parts[0]);
    inline for (template.slots, template.parts[1..]) |slot, part| {
        try writeSlot(Args, slot, args, bound, w);
        try w.writeAll(part);
    }
}

/// The length of `n` bytes as `X'hex'`.
pub fn bytesLength(n: usize) usize {
    return bytes_head.len + 2 * n + bytes_tail.len;
}

/// The length of `n` bytes of text as a literal.
pub fn textLength(n: usize) usize {
    return text_head.len + 2 * n + text_tail.len;
}

/// `bytes` as hex digits, two per byte, with no quotes: what goes between
/// the quotes of a literal, and what a content chunk streams.
pub fn writeHex(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    const digits = "0123456789abcdef";
    var chunk: [128]u8 = undefined;
    var at: usize = 0;
    while (at < bytes.len) {
        const n: usize = @min(chunk.len / 2, bytes.len - at);
        for (bytes[at..][0..n], 0..) |byte, i| {
            chunk[2 * i] = digits[byte >> 4];
            chunk[2 * i + 1] = digits[byte & 0xf];
        }
        try w.writeAll(chunk[0 .. 2 * n]);
        at += n;
    }
}

fn partsLength(comptime template: rsql.Template) usize {
    var total: usize = 0;
    for (template.parts) |part| total += part.len;
    return total;
}

fn ArgType(comptime Args: type, comptime index: usize) type {
    return @typeInfo(Args).@"struct".field_types[index];
}

fn argument(comptime Args: type, comptime index: usize, args: *const Args) ArgType(Args, index) {
    return @field(args, @typeInfo(Args).@"struct".field_names[index]);
}

fn served(provider: protocol.Provider, bound: Bound) []const u8 {
    return rsql.servedBinding(provider, protocol.routeOf(bound.served.*, provider) != .unserved);
}

fn slotLength(comptime Args: type, comptime slot: rsql.Slot, args: *const Args, bound: Bound) Error!usize {
    return switch (slot) {
        .argument => |index| valueLength(ArgType(Args, index), argument(Args, index, args)),
        .now => std.fmt.count("{d}", .{bound.now}),
        .served => |provider| textLength(served(provider, bound).len),
    };
}

fn writeSlot(comptime Args: type, comptime slot: rsql.Slot, args: *const Args, bound: Bound, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (slot) {
        .argument => |index| try writeValue(ArgType(Args, index), argument(Args, index, args), w),
        .now => try w.print("{d}", .{bound.now}),
        .served => |provider| try writeText(served(provider, bound), w),
    }
}

/// Whether `T` is a `Bounded` text.
fn isBounded(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasField(T, "bytes")) return false;
    const bytes = @typeInfo(@FieldType(T, "bytes"));
    return bytes == .array and T == Bounded(bytes.array.len);
}

/// The types `sqlite.bindValue` binds, each written as the literal of the
/// value SQLite would bind.
fn valueLength(comptime T: type, value: T) Error!usize {
    if (T == []const u8) return textLength(value.len);
    if (T == rsql.Positive) return std.fmt.count("{d}", .{value.get()});
    if (T == rsql.Bytes) return bytesLength(value.bytes.len);
    if (T == rsql.SessionHead) return textLength(value.ref.len);
    if (comptime isBounded(T)) return textLength(value.len);
    return switch (@typeInfo(T)) {
        .optional => |optional| if (value) |present| valueLength(optional.child, present) else null_text.len,
        .bool => 1,
        .int => if (value > std.math.maxInt(i64)) error.IntegerOutOfRange else std.fmt.count("{d}", .{value}),
        .@"enum" => textLength(@tagName(value).len),
        .array => |array| if (array.child == u8) bytesLength(array.len) else @compileError("rsql: an Args array is [n]u8"),
        else => @compileError("rsql: " ++ @typeName(T) ++ " is not a typed statement value"),
    };
}

fn writeValue(comptime T: type, value: T, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (T == []const u8) return writeText(value, w);
    if (T == rsql.Positive) return w.print("{d}", .{value.get()});
    if (T == rsql.Bytes) return writeBytes(value.bytes, w);
    if (T == rsql.SessionHead) return writeText(&value.ref, w);
    if (comptime isBounded(T)) return writeText(value.slice(), w);
    switch (@typeInfo(T)) {
        .optional => |optional| if (value) |present| try writeValue(optional.child, present, w) else try w.writeAll(null_text),
        .bool => try w.writeByte(if (value) '1' else '0'),
        .int => {
            std.debug.assert(value <= std.math.maxInt(i64));
            try w.print("{d}", .{value});
        },
        .@"enum" => try writeText(@tagName(value), w),
        .array => try writeBytes(&value, w),
        else => comptime unreachable,
    }
}

fn writeText(text: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(text_head);
    try writeHex(w, text);
    try w.writeAll(text_tail);
}

fn writeBytes(bytes: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(bytes_head);
    try writeHex(w, bytes);
    try w.writeAll(bytes_tail);
}

const Tag = enum { first, second_tag };

const all_unserved = protocol.routesAll(.unserved);

fn expectRendered(comptime text: []const u8, comptime Args: type, args: Args, bound: Bound, expected: []const u8) !void {
    const template = comptime rsql.mysqlRendering(text).rendered;
    const len = try length(template, Args, &args, bound);
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try write(template, Args, &args, bound, &w);
    try std.testing.expectEqualStrings(expected, w.buffered());
    try std.testing.expectEqual(len, w.buffered().len);
}

test "each argument type is written as its literal" {
    const Args = struct {
        id: rsql.Positive,
        text: []const u8,
        bytes: rsql.Bytes,
        count: u32,
        flag: bool,
        tag: Tag,
        digest: [2]u8,
        head: rsql.SessionHead,
        label: Bounded(8),
        missing: ?u64,
    };
    var label: Bounded(8) = .{ .len = 0 };
    try label.set("é");
    try expectRendered(
        "SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10",
        Args,
        .{
            .id = .of(42),
            .text = "a'b",
            .bytes = .{ .bytes = &.{ 0, 0xff } },
            .count = 0,
            .flag = true,
            .tag = .second_tag,
            .digest = .{ 0xab, 0x01 },
            .head = .{ .ref = "abc123".*, .workspace_key = .of(1), .next_position = .of(2) },
            .label = label,
            .missing = null,
        },
        .{ .now = 0, .served = &all_unserved },
        "SELECT 42,_utf8mb4 X'612762' COLLATE utf8mb4_0900_bin,X'00ff',0,1," ++
            "_utf8mb4 X'7365636f6e645f746167' COLLATE utf8mb4_0900_bin,X'ab01'," ++
            "_utf8mb4 X'616263313233' COLLATE utf8mb4_0900_bin,_utf8mb4 X'c3a9' COLLATE utf8mb4_0900_bin,NULL",
    );
}

test "empty text and bytes are empty literals, never NULL" {
    const Args = struct { text: []const u8, bytes: rsql.Bytes, absent: ?rsql.Bytes };
    try expectRendered(
        "SELECT ?1,?2,?3",
        Args,
        .{ .text = "", .bytes = .{ .bytes = "" }, .absent = null },
        .{ .now = 0, .served = &all_unserved },
        "SELECT _utf8mb4 X'' COLLATE utf8mb4_0900_bin,X'',NULL",
    );
}

test "@now writes the bound second, and @served each provider's binding" {
    const Args = struct { provider: []const u8 };
    var routes = protocol.routesAll(.unserved);
    routes.codex = .endpoint;
    try expectRendered(
        "SELECT @now,@served(?1)",
        Args,
        .{ .provider = "x" },
        .{ .now = 1_700_000_000, .served = &routes },
        "SELECT 1700000000,(_utf8mb4 X'78' COLLATE utf8mb4_0900_bin IN (_utf8mb4 X'636f646578' COLLATE utf8mb4_0900_bin,_utf8mb4 X'' COLLATE utf8mb4_0900_bin))",
    );
}

test "an integer above the largest BIGINT is refused before anything is written" {
    const template = comptime rsql.mysqlRendering("SELECT ?1").rendered;
    const Args = struct { value: u64 };
    const bound: Bound = .{ .now = 0, .served = &all_unserved };
    try std.testing.expectError(error.IntegerOutOfRange, length(template, Args, &.{ .value = std.math.maxInt(i64) + 1 }, bound));
    try std.testing.expectEqual("SELECT 9223372036854775807".len, try length(template, Args, &.{ .value = std.math.maxInt(i64) }, bound));
}

test "length equals what write writes, for every decimal width and every byte" {
    const template = comptime rsql.mysqlRendering("SELECT ?1,?2,@now").rendered;
    const Args = struct { value: u64, bytes: rsql.Bytes };
    var all: [256]u8 = undefined;
    for (&all, 0..) |*byte, i| byte.* = @intCast(i);
    var buffer: [1024]u8 = undefined;
    var power: u64 = 1;
    for (0..19) |_| {
        for ([_]u64{ power - 1, power, power * 9 }) |value| {
            const args: Args = .{ .value = value, .bytes = .{ .bytes = all[0..@intCast(value % 257)] } };
            for ([_]i64{ std.math.minInt(i64), -1, 0, @intCast(value) }) |now| {
                const bound: Bound = .{ .now = now, .served = &all_unserved };
                var w: std.Io.Writer = .fixed(&buffer);
                try write(template, Args, &args, bound, &w);
                try std.testing.expectEqual(w.buffered().len, try length(template, Args, &args, bound));
            }
        }
        power *|= 10;
    }
}

test "hex is the bytes' lowercase hex, two digits each" {
    var all: [300]u8 = undefined;
    for (&all, 0..) |*byte, i| byte.* = @truncate(i * 7);
    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    try expected.writer.print("{x}", .{&all});
    var buffer: [600]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try writeHex(&out, &all);
    try std.testing.expectEqualStrings(expected.written(), out.buffered());
}
