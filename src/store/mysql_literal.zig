const std = @import("std");
const Bounded = @import("../bounded.zig").Bounded;
const isBounded = @import("../bounded.zig").isBounded;
const provider_route = @import("../provider_route.zig");
const provider_name = @import("../provider_name.zig");
const rsql = @import("rsql.zig");

const text_head = "_utf8mb4 X'";
const text_tail = "' COLLATE utf8mb4_0900_bin";
const bytes_head = "X'";
const bytes_tail = "'";
const null_text = "NULL";

pub const Bound = struct {
    now: i64,
    served: *const provider_route.Served,
};

pub const Error = error{IntegerOutOfRange};

pub fn length(comptime template: rsql.Template, comptime Args: type, args: *const Args, bound: Bound) Error!usize {
    var total: usize = comptime partsLength(template);
    inline for (template.slots) |slot| total += try slotLength(Args, slot, args, bound);
    return total;
}

pub fn write(comptime template: rsql.Template, comptime Args: type, args: *const Args, bound: Bound, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(template.parts[0]);
    inline for (template.slots, template.parts[1..]) |slot, part| {
        try writeSlot(Args, slot, args, bound, w);
        try w.writeAll(part);
    }
}

pub fn bytesLength(n: usize) usize {
    return bytes_head.len + 2 * n + bytes_tail.len;
}

pub fn textLength(n: usize) usize {
    return text_head.len + 2 * n + text_tail.len;
}

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

/// The text served slot `index` binds: that served entry's name, or '' past the served set.
fn servedName(index: usize, bound: Bound) []const u8 {
    const entries = bound.served.items();
    return if (index < entries.len) entries[index].name.slice() else "";
}

fn slotLength(comptime Args: type, comptime slot: rsql.Slot, args: *const Args, bound: Bound) Error!usize {
    return switch (slot) {
        .argument => |index| valueLength(ArgType(Args, index), argument(Args, index, args)),
        .now => std.fmt.count("{d}", .{bound.now}),
        .served => |index| textLength(servedName(index, bound).len),
    };
}

fn writeSlot(comptime Args: type, comptime slot: rsql.Slot, args: *const Args, bound: Bound, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (slot) {
        .argument => |index| try writeValue(ArgType(Args, index), argument(Args, index, args), w),
        .now => try w.print("{d}", .{bound.now}),
        .served => |index| try writeText(servedName(index, bound), w),
    }
}

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

const all_unserved: provider_route.Served = .{};

fn expectRendered(comptime text: []const u8, comptime Args: type, args: Args, bound: Bound, expected: []const u8) !void {
    const template = comptime rsql.mysqlRendering(text).rendered;
    const len = try length(template, Args, &args, bound);
    var buffer: [2048]u8 = undefined;
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

fn servedLiteral(comptime text: []const u8) []const u8 {
    comptime {
        var hex: []const u8 = "";
        for (text) |byte| hex = hex ++ std.fmt.comptimePrint("{x:0>2}", .{byte});
        return "_utf8mb4 X'" ++ hex ++ "' COLLATE utf8mb4_0900_bin";
    }
}

test "@served binds each served name in slot order, and '' past the served set" {
    const Args = struct { provider: []const u8 };
    var set: provider_route.Served = .{};
    try set.put(provider_route.builtIn(.codex, .endpoint));
    try set.put(provider_route.builtIn(.chatgpt, .chatgpt_plan));
    const names = [_][]const u8{ "codex", "chatgpt" };
    const slots = comptime blk: {
        var list: []const u8 = "";
        for (0..provider_route.max_served) |index| {
            const text = if (index < names.len) names[index] else "";
            list = list ++ (if (index == 0) "" else ",") ++ servedLiteral(text);
        }
        break :blk list;
    };
    try expectRendered(
        "SELECT @now,@served(?1)",
        Args,
        .{ .provider = "x" },
        .{ .now = 1_700_000_000, .served = &set },
        "SELECT 1700000000,(_utf8mb4 X'78' COLLATE utf8mb4_0900_bin IN (" ++ slots ++ "))",
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
