//! Walking a JSON message an MCP server sent, as values. `check` runs the
//! codecs' RFC 8259 reader over the whole message once; after that the
//! walkers here trust its syntax and hand out slices of it, so no part of a
//! message is copied or allocated to be read.
const std = @import("std");
const json = @import("../codecs/json.zig");

pub const Error = json.Error;

/// Checks that `bytes` are one JSON object.
pub fn check(bytes: []const u8) Error!void {
    var reader: json.Reader = undefined;
    try reader.read(bytes, Ignore{});
}

const Ignore = struct {
    pub fn key(_: Ignore, _: *json.Reader, _: u8) void {}
    pub fn begin(_: Ignore, _: *json.Reader, _: json.Kind, _: u8) void {}
    pub fn end(_: Ignore, _: *json.Reader, _: json.Kind, _: u8) void {}
};

pub const Kind = enum { object, array, string, number, true_value, false_value, null_value };

/// The kind of a checked value, from its first byte.
pub fn kind(value: []const u8) Kind {
    return switch (value[0]) {
        '{' => .object,
        '[' => .array,
        '"' => .string,
        't' => .true_value,
        'f' => .false_value,
        'n' => .null_value,
        else => .number,
    };
}

pub const Member = struct {
    /// The key's contents as written, escapes and all.
    key: []const u8,
    /// The whole value, from its first byte to its last.
    value: []const u8,
};

/// The members of a checked object, in order.
pub const Members = struct {
    object: []const u8,
    at: usize,

    pub fn init(object: []const u8) Members {
        std.debug.assert(object[0] == '{');
        return .{ .object = object, .at = 1 };
    }

    pub fn next(self: *Members) ?Member {
        var at = json.skipSpace(self.object, self.at);
        if (self.object[at] == ',') at = json.skipSpace(self.object, at + 1);
        if (self.object[at] == '}') {
            self.at = at;
            return null;
        }
        const key = json.stringAt(self.object, at);
        at = json.skipSpace(self.object, key.end);
        std.debug.assert(self.object[at] == ':');
        at = json.skipSpace(self.object, at + 1);
        const end = json.valueEnd(self.object, at);
        self.at = end;
        return .{ .key = slice(self.object, key.contents), .value = self.object[at..end] };
    }
};

/// The items of a checked array, in order.
pub const Items = struct {
    array: []const u8,
    at: usize,

    pub fn init(array: []const u8) Items {
        std.debug.assert(array[0] == '[');
        return .{ .array = array, .at = 1 };
    }

    pub fn next(self: *Items) ?[]const u8 {
        var at = json.skipSpace(self.array, self.at);
        if (self.array[at] == ',') at = json.skipSpace(self.array, at + 1);
        if (self.array[at] == ']') {
            self.at = at;
            return null;
        }
        const end = json.valueEnd(self.array, at);
        self.at = end;
        return self.array[at..end];
    }
};

fn slice(document: []const u8, range: anytype) []const u8 {
    return document[@intCast(range.start)..][0..@intCast(range.length)];
}

/// Whether string contents as written decode to `name`.
pub fn keyIs(written: []const u8, name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, written, '\\') == null) return std.mem.eql(u8, written, name);
    var text: json.Text = .{ .length = 0 };
    json.decode(written, &text);
    return std.mem.eql(u8, text.slice() orelse return false, name);
}

/// The value of the member of `object` whose key decodes to `name`; the
/// first one when a server repeats a key.
pub fn member(object: []const u8, name: []const u8) ?[]const u8 {
    var members = Members.init(object);
    while (members.next()) |found| {
        if (keyIs(found.key, name)) return found.value;
    }
    return null;
}

/// The contents of a checked string value, without its quotes.
pub fn contents(string: []const u8) []const u8 {
    std.debug.assert(kind(string) == .string);
    return string[1 .. string.len - 1];
}

/// Writes the decoded text of string contents the reader accepted.
pub fn writeDecoded(writer: *std.Io.Writer, string_contents: []const u8) std.Io.Writer.Error!void {
    var sink: Sink = .{ .writer = writer };
    json.decodeContents(string_contents, &sink);
    return sink.failure orelse {};
}

/// How many bytes `writeDecoded` writes.
pub fn decodedLength(string_contents: []const u8) usize {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    writeDecoded(&counter.writer, string_contents) catch unreachable;
    return @intCast(counter.fullCount());
}

const Sink = struct {
    writer: *std.Io.Writer,
    failure: ?std.Io.Writer.Error = null,

    pub fn append(self: *Sink, bytes: []const u8, _: ?u21) void {
        if (self.failure != null) return;
        self.writer.writeAll(bytes) catch |err| {
            self.failure = err;
        };
    }
};

/// Writes `text` as a JSON string, quotes included. Only the quote, the
/// backslash and control bytes are escaped; `text` must be UTF-8.
pub fn writeString(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    std.debug.assert(std.unicode.utf8ValidateSlice(text));
    try writer.writeByte('"');
    var start: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte != '"' and byte != '\\' and byte >= 0x20) continue;
        try writer.writeAll(text[start..index]);
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.print("\\u{x:0>4}", .{byte}),
        }
        start = index + 1;
    }
    try writer.writeAll(text[start..]);
    try writer.writeByte('"');
}

test "members and items walk a checked message without copying it" {
    const message = " { \"a\" : [1, \"two\" , {\"x\":null}] ,\"b\\u0063\":true,\"a\":false } ";
    try check(message);
    const object = message[1 .. message.len - 1];
    var members = Members.init(object);
    const first = members.next().?;
    try std.testing.expectEqualStrings("a", first.key);
    try std.testing.expectEqual(Kind.array, kind(first.value));
    var items = Items.init(first.value);
    try std.testing.expectEqualStrings("1", items.next().?);
    try std.testing.expectEqualStrings("two", contents(items.next().?));
    try std.testing.expectEqualStrings("{\"x\":null}", items.next().?);
    try std.testing.expectEqual(null, items.next());
    const second = members.next().?;
    try std.testing.expect(keyIs(second.key, "bc"));
    try std.testing.expectEqual(Kind.true_value, kind(second.value));
    try std.testing.expectEqualStrings("false", members.next().?.value);
    try std.testing.expectEqual(null, members.next());

    try std.testing.expectEqualStrings("true", member(object, "bc").?);
    try std.testing.expectEqualStrings("[1, \"two\" , {\"x\":null}]", member(object, "a").?);
    try std.testing.expectEqual(null, member(object, "c"));
    var empty = Members.init("{ }");
    try std.testing.expectEqual(null, empty.next());
    var none = Items.init("[ ]");
    try std.testing.expectEqual(null, none.next());
}

test "strings decode and encode" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeDecoded(&writer, "a\\\"b\\u00e9\\n");
    try std.testing.expectEqualStrings("a\"b\xc3\xa9\n", writer.buffered());
    try std.testing.expectEqual(@as(usize, 6), decodedLength("a\\\"b\\u00e9\\n"));

    writer = .fixed(&buffer);
    try writeString(&writer, "q\"\\\n\r\t\x01\xc3\xa9");
    try std.testing.expectEqualStrings("\"q\\\"\\\\\\n\\r\\t\\u0001\xc3\xa9\"", writer.buffered());
    var check_buffer: [80]u8 = undefined;
    const wrapped = try std.fmt.bufPrint(&check_buffer, "{{\"k\":{s}}}", .{writer.buffered()});
    try check(wrapped);
}

test "check refuses what is not one object" {
    try std.testing.expectError(error.UnexpectedJsonDelimiter, check("[1]"));
    try std.testing.expectError(error.UnexpectedJsonEnd, check("{\"a\":"));
    try std.testing.expectError(error.TrailingJson, check("{} {}"));
}
