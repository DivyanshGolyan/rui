//! The one text form of an Activity row's facts, for a reader that has only text (the `read_transcript` tool).
//!
//! `writeFacts` walks the row's payload by reflection and prints each field as ` name=value`, so a field added to
//! an Activity row prints without an edit here, and a field of a type this module has not classified is a compile
//! error naming it. A caller that wants a field in different words lists it in `skipped` with the reason.
//! An integer field whose name ends in `_at` is an instant in seconds and prints as RFC 3339 UTC; the row's own time is `at`.
const std = @import("std");
const activity_read = @import("activity_read.zig");
const bounded = @import("bounded.zig");
const connection = @import("connection.zig");
const content_value = @import("content_value.zig");
const facts = @import("activity_facts.zig");
const tool_presentation = @import("tool_presentation.zig");

/// Fields no token is printed for, each owned by another part of the line.
const skipped = .{
    // The caller prints the origin word (person, a peer's Session, `Action N`).
    .{ "Message", "origin" },
    // Display words, printed by the caller as the row's line.
    .{ "ProposalMetadata", "description" },
    .{ "ApprovalRequested", "description" },
};

const Leaf = enum { integer, flag, tag, quoted, presentation, hosted, body };

fn leaf(comptime Owner: type, comptime name: []const u8, comptime T: type) Leaf {
    const Base = switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
    return switch (@typeInfo(Base)) {
        .int => .integer,
        .bool => .flag,
        .@"enum" => .tag,
        .array => |array| if (array.child == activity_read.ProposalFieldReference) .body else bad(Owner, name, T),
        .@"struct" => if (bounded.isBounded(Base) or Base == connection.Name)
            .quoted
        else if (Base == tool_presentation.ToolPresentation)
            .presentation
        else if (Base == facts.Item.HostedAction)
            .hosted
        else if (Base == content_value.Reference or Base == activity_read.ProposalFieldReference)
            .body
        else
            bad(Owner, name, T),
        .@"union" => if (Base == content_value.Value) .body else bad(Owner, name, T),
        else => bad(Owner, name, T),
    };
}

fn bad(comptime Owner: type, comptime name: []const u8, comptime T: type) noreturn {
    @compileError("entry_text cannot print " ++ @typeName(Owner) ++ "." ++ name ++ " of type " ++ @typeName(T) ++ ": classify it in `leaf` or list it in `skipped`");
}

fn isSkipped(comptime Owner: type, comptime name: []const u8) bool {
    @setEvalBranchQuota(100_000);
    const owner = comptime shortName(Owner);
    inline for (skipped) |entry| {
        if (comptime std.mem.eql(u8, entry[0], owner) and std.mem.eql(u8, entry[1], name)) return true;
    }
    return false;
}

fn shortName(comptime T: type) []const u8 {
    const full = @typeName(T);
    const dot = comptime std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

/// Prints ` at=<time>` and then ` name=value` for every fact of `item`, in declaration order.
/// Null optionals print nothing. Body values (content references) are printed by the caller's body preview.
pub noinline fn writeFacts(out: *std.Io.Writer, item: *const facts.Item) std.Io.Writer.Error!void {
    try out.writeAll(" at=");
    try writeInstant(out, item.at);
    switch (item.value) {
        inline else => |payload| try writePayload(out, payload),
    }
}

fn writePayload(out: *std.Io.Writer, payload: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(payload);
    if (T == tool_presentation.ToolPresentation) return writePresentation(out, payload);
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        if (comptime !isSkipped(T, name)) try writeField(out, T, name, @field(payload, name));
    }
}

fn writeField(out: *std.Io.Writer, comptime Owner: type, comptime name: []const u8, value: @FieldType(Owner, name)) std.Io.Writer.Error!void {
    const Field = @FieldType(Owner, name);
    const present = if (comptime @typeInfo(Field) == .optional) (value orelse return) else value;
    switch (comptime leaf(Owner, name, Field)) {
        .integer => if (comptime std.mem.endsWith(u8, name, "_at")) {
            try out.print(" {s}=", .{name});
            try writeInstant(out, present);
        } else try out.print(" {s}={d}", .{ name, present }),
        .flag => try out.print(" {s}={}", .{ name, present }),
        .tag => try out.print(" {s}={s}", .{ name, @tagName(present) }),
        .quoted => {
            try out.print(" {s}=", .{name});
            try std.json.Stringify.value(present.slice(), .{}, out);
        },
        .presentation => try writePresentation(out, present),
        // The kind and how many targets the Store holds; the targets and the pattern are the row's body.
        .hosted => try out.print(" {s}.kind={s} {s}.targets_total={d}", .{ name, @tagName(present.kind), name, present.targets_total }),
        .body => {},
    }
}

fn writePresentation(out: *std.Io.Writer, presentation: tool_presentation.ToolPresentation) std.Io.Writer.Error!void {
    try out.print(" code={s}", .{@tagName(presentation.code)});
    if (presentation.publication_position) |position| try out.print(" publication_position={d}", .{position});
}

/// RFC 3339 UTC, whole seconds. The civil date is computed from the day count (days since 1970-01-01) so a core
/// holds no clock type.
fn writeInstant(out: *std.Io.Writer, seconds: u64) std.Io.Writer.Error!void {
    const days: i64 = @intCast(seconds / 86_400);
    const second_of_day = seconds % 86_400;
    // Civil-from-days over eras of 400 years, counted from 0000-03-01.
    const shifted = days + 719_468;
    const era = @divFloor(shifted, 146_097);
    const day_of_era: i64 = shifted - era * 146_097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1_460) + @divFloor(day_of_era, 36_524) - @divFloor(day_of_era, 146_096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_index = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_index + 2, 5) + 1;
    const month = if (month_index < 10) month_index + 3 else month_index - 9;
    const year = year_of_era + era * 400 + @intFromBool(month <= 2);
    try out.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(year)),
        @as(u64, @intCast(month)),
        @as(u64, @intCast(day)),
        second_of_day / 3_600,
        second_of_day % 3_600 / 60,
        second_of_day % 60,
    });
}

test "INS-14 an instant prints as RFC 3339 UTC" {
    var buffer: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try writeInstant(&out, 0);
    try writeInstant(&out, 1_000_000_000);
    try writeInstant(&out, 1_709_164_800 + 86_399);
    try writeInstant(&out, 4_102_444_800);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z2001-09-09T01:46:40Z2024-02-29T23:59:59Z2100-01-01T00:00:00Z", out.buffered());
}

/// A value of `T` with every field present, for the owner test.
fn filled(comptime T: type) T {
    switch (@typeInfo(T)) {
        .int => return 1,
        .bool => return true,
        .void => return {},
        .@"enum" => return std.meta.tags(T)[0],
        .optional => |optional| return filled(optional.child),
        .array => |array| {
            var value: T = undefined;
            for (&value) |*element| element.* = filled(array.child);
            return value;
        },
        .@"union" => |union_info| return @unionInit(T, union_info.field_names[0], filled(union_info.field_types[0])),
        .@"struct" => |struct_info| {
            if (comptime bounded.isBounded(T)) {
                var value: T = .{};
                value.set("x") catch unreachable;
                return value;
            }
            var value: T = undefined;
            inline for (struct_info.field_names, struct_info.field_types) |name, Field| @field(value, name) = filled(Field);
            return value;
        },
        else => @compileError("filled: " ++ @typeName(T)),
    }
}

test "INS-14 entry text prints every fact of every Activity row" {
    @setEvalBranchQuota(100_000);
    inline for (comptime std.meta.tags(facts.Item.Kind)) |kind| {
        const payload = filled(@FieldType(facts.Item.Value, @tagName(kind)));
        const item: facts.Item = .{ .position = 1, .at = 1_000_000_000, .value = @unionInit(facts.Item.Value, @tagName(kind), payload) };
        var buffer: [4096]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        try writeFacts(&out, &item);
        const text = out.buffered();
        try std.testing.expect(std.mem.startsWith(u8, text, " at=2001-09-09T01:46:40Z"));
        const Payload = @TypeOf(payload);
        if (Payload == tool_presentation.ToolPresentation) {
            try std.testing.expect(std.mem.indexOf(u8, text, " code=") != null);
        } else inline for (@typeInfo(Payload).@"struct".field_names) |name| {
            if (comptime isSkipped(Payload, name)) continue;
            if (comptime leaf(Payload, name, @FieldType(Payload, name)) == .body) continue;
            var needle: [64]u8 = undefined;
            const expected = switch (comptime leaf(Payload, name, @FieldType(Payload, name))) {
                .presentation => " code=",
                .hosted => " action.kind=",
                else => std.fmt.bufPrint(&needle, " {s}=", .{name}) catch unreachable,
            };
            if (std.mem.indexOf(u8, text, expected) == null) {
                std.debug.print("{s} row prints no {s} in: {s}\n", .{ @tagName(kind), expected, text });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "INS-14 a peer origin prints neither its Session nor its label" {
    var peer: facts.NamedPeer = .{ .session = .{}, .label = .{} };
    try peer.session.set("abcdef");
    try peer.label.set("secret label");
    const message: facts.Item.Message = .{
        .admission = 7,
        .key = try .from("k1"),
        .turn = null,
        .state = .queued,
        .content = .{ .text = .{ .length = 3, .digest = @splat(0) } },
        .admitted_at = 1_000_000_000,
        .origin = .{ .peer = peer },
    };
    const item: facts.Item = .{ .position = 2, .at = 0, .value = .{ .received = message } };
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try writeFacts(&out, &item);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "abcdef") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "secret label") == null);
}

test "INS-14 a message row prints its admission facts and keeps the origin to the caller" {
    const message: facts.Item.Message = .{
        .admission = 7,
        .key = try .from("k1"),
        .turn = null,
        .state = .applied,
        .content = .{ .text = .{ .length = 3, .digest = @splat(0) } },
        .admitted_at = 1_000_000_000,
        .origin = .{ .action = 4 },
    };
    const item: facts.Item = .{ .position = 2, .at = 0, .value = .{ .user = message } };
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try writeFacts(&out, &item);
    try std.testing.expectEqualStrings(" at=1970-01-01T00:00:00Z admission=7 key=\"k1\" state=applied admitted_at=2001-09-09T01:46:40Z", out.buffered());
}
