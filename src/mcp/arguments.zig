//! A call's arguments as the server receives them (D62). The model fills in
//! the saved schema, which carries `rui_call_description`; the server is
//! sent only the fields its own schema lists, and the description stays
//! with Rui for the conversation line.
//!
//! A functional core: checked JSON in, bytes out.
const std = @import("std");
const document = @import("document.zig");
const shape = @import("shape.zig");
const json = @import("../codecs/json.zig");
const codec_abi = @import("../codec_abi.zig");

pub const Split = struct {
    /// The `rui_call_description` string's contents as written, or null
    /// when the model left it out, sent a non-string, or sent more than
    /// `shape.description_max_bytes` decoded bytes (D143).
    description: ?[]const u8,
};

/// Writes `arguments`, a checked JSON object, keeping only the members
/// whose key is a property of `input_schema`, the saved schema with the
/// description property added. Members keep their order and spelling.
pub fn writeForServer(writer: *std.Io.Writer, input_schema: []const u8, arguments: []const u8) std.Io.Writer.Error!Split {
    std.debug.assert(document.kind(arguments) == .object);
    const properties = document.member(input_schema, "properties");
    var split: Split = .{ .description = null };
    try writer.writeByte('{');
    var first = true;
    var members = document.Members.init(arguments);
    while (members.next()) |found| {
        if (document.keyIs(found.key, shape.description_property)) {
            if (split.description == null) split.description = description(found.value);
            continue;
        }
        const listed = properties orelse continue;
        if (document.kind(listed) != .object or !hasKey(listed, found.key)) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("\"{s}\":{s}", .{ found.key, found.value });
    }
    try writer.writeByte('}');
    return split;
}

/// Finds the first valid root description without retaining the arguments.
/// The range names raw string contents; at most 200 decoded bytes (and
/// therefore at most 1200 raw bytes). Source and JSON errors propagate even
/// after a description has been found.
pub fn descriptionRange(source: anytype) !?codec_abi.Range {
    var reader: json.Reader = undefined;
    var capture: DescriptionCapture = .{};
    try reader.readSource(source, &capture);
    return capture.range;
}

const DescriptionCapture = struct {
    range: ?codec_abi.Range = null,
    description_key: bool = false,

    pub fn key(self: *DescriptionCapture, reader: *const json.Reader, depth: u8) void {
        if (depth != 1) return;
        const text = reader.text() orelse {
            self.description_key = false;
            return;
        };
        self.description_key = std.mem.eql(u8, text, shape.description_property);
    }

    pub fn begin(_: *DescriptionCapture, _: *const json.Reader, _: json.Kind, _: u8) void {}

    pub fn end(self: *DescriptionCapture, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
        if (depth != 1 or !self.description_key or self.range != null) return;
        if (kind == .string and descriptionFits(reader.decoded)) self.range = reader.string();
    }
};

fn descriptionFits(decoded: u64) bool {
    return decoded <= shape.description_max_bytes;
}

fn description(value: []const u8) ?[]const u8 {
    if (document.kind(value) != .string) return null;
    const text = document.contents(value);
    if (!descriptionFits(document.decodedLength(text))) return null;
    return text;
}

/// Whether `properties` has a member whose key decodes the same as `key`,
/// both as written; differently escaped spellings are one name.
fn hasKey(properties: []const u8, key: []const u8) bool {
    var own = document.Members.init(properties);
    while (own.next()) |found| {
        if (document.sameText(found.key, key)) return true;
    }
    return false;
}

fn forServer(buffer: []u8, saved: []const u8, arguments: []const u8) !struct { text: []const u8, split: Split } {
    var writer: std.Io.Writer = .fixed(buffer);
    const split = try writeForServer(&writer, saved, arguments);
    return .{ .text = writer.buffered(), .split = split };
}

const schema = "{\"properties\":{\"q\":{},\"n\":{},\"rui_call_description\":{}}}";

test "the server gets only the fields its schema lists, and Rui keeps the description" {
    var buffer: [256]u8 = undefined;
    const out = try forServer(&buffer, schema, "{\"q\":\"x\",\"rui_call_description\":\"Find x\",\"extra\":1,\"n\":2}");
    try std.testing.expectEqualStrings("{\"q\":\"x\",\"n\":2}", out.text);
    try std.testing.expectEqualStrings("Find x", out.split.description.?);
    try document.check(out.text);
}

test "a missing, mistyped or oversized description is absent" {
    var buffer: [512]u8 = undefined;
    try std.testing.expect((try forServer(&buffer, schema, "{\"q\":1}")).split.description == null);
    try std.testing.expect((try forServer(&buffer, schema, "{\"rui_call_description\":5}")).split.description == null);
    const long = "{\"rui_call_description\":\"" ++ &@as([shape.description_max_bytes + 1]u8, @splat('a')) ++ "\"}";
    try std.testing.expect((try forServer(&buffer, schema, long)).split.description == null);
    const exact = "{\"rui_call_description\":\"" ++ &@as([shape.description_max_bytes]u8, @splat('a')) ++ "\"}";
    try std.testing.expectEqual(@as(usize, shape.description_max_bytes), (try forServer(&buffer, schema, exact)).split.description.?.len);
}

test "an escaped spelling of a listed field is kept as written" {
    var buffer: [256]u8 = undefined;
    const out = try forServer(&buffer, schema, "{\"\\u0071\":\"x\"}");
    try std.testing.expectEqualStrings("{\"\\u0071\":\"x\"}", out.text);
}

test "a schema with no properties lists no fields" {
    var buffer: [256]u8 = undefined;
    const out = try forServer(&buffer, "{\"type\":\"object\"}", "{\"q\":1,\"rui_call_description\":\"d\"}");
    try std.testing.expectEqualStrings("{}", out.text);
    try std.testing.expectEqualStrings("d", out.split.description.?);
}

test "escaped names longer than any fixed buffer still match" {
    const a: [300]u8 = @splat('a');
    const escaped = "\\u0061" ++ a[1..];
    const saved = "{\"properties\":{\"" ++ a ++ "\":{}}}";
    var buffer: [1024]u8 = undefined;
    const out = try forServer(&buffer, saved, "{\"" ++ escaped ++ "\":1}");
    try std.testing.expectEqualStrings("{\"" ++ escaped ++ "\":1}", out.text);
    const other = "{\"properties\":{\"" ++ a[1..] ++ "b\":{}}}";
    try std.testing.expectEqualStrings("{}", (try forServer(&buffer, other, "{\"" ++ escaped ++ "\":1}")).text);
}

// A source with no argument-sized allocation, also able to fail after a
// valid description to check that extraction still consumes the document.
const DescriptionSource = struct {
    bytes: []const u8,
    at: usize = 0,
    fail_at: ?usize = null,

    pub fn peek(self: *DescriptionSource) error{SourceFailed}!?u8 {
        if (self.fail_at) |at| if (self.at >= at) return error.SourceFailed;
        return if (self.at < self.bytes.len) self.bytes[self.at] else null;
    }

    pub fn take(self: *DescriptionSource) error{SourceFailed}!?u8 {
        const byte = try self.peek();
        if (byte != null) self.at += 1;
        return byte;
    }
};

fn expectDescriptionParity(arguments: []const u8) !void {
    var buffer: [2048]u8 = undefined;
    const split = (try forServer(&buffer, schema, arguments)).split;
    var source: DescriptionSource = .{ .bytes = arguments };
    const range = try descriptionRange(&source);
    if (split.description) |expected| {
        const found = range orelse return error.TestUnexpectedResult;
        const start: usize = @intCast(found.start);
        const length: usize = @intCast(found.length);
        try std.testing.expectEqualStrings(expected, arguments[start..][0..length]);
        try std.testing.expect(length <= 6 * shape.description_max_bytes);
    } else try std.testing.expect(range == null);
}

test "streamed description matches server split for absent invalid nested and duplicate fields" {
    for ([_][]const u8{
        "{}",
        "{\"rui_call_description\":5}",
        "{\"rui_call_description\":null}",
        "{\"nested\":{\"rui_call_description\":\"hidden\"}}",
        "{\"rui_call_description\":{\"rui_call_description\":\"hidden\"}}",
        "{\"rui_call_description\":false,\"rui_call_description\":\"valid\",\"rui_call_description\":\"later\"}",
        "{\"rui_call_\\u0064escription\":\"escaped key\"}",
        "{\"" ++ @as([65]u8, @splat('x')) ++ "\":\"not a description\"}",
        "{\"rui_call_description\":\"" ++ @as([201]u8, @splat('a')) ++ "\"}",
        "{\"rui_call_description\":\"" ++ @as([201]u8, @splat('a')) ++ "\",\"rui_call_description\":\"valid\"}",
    }) |arguments| try expectDescriptionParity(arguments);
}

fn repeatedDescriptionText(comptime text: []const u8, comptime count: usize) [text.len * count]u8 {
    var result: [text.len * count]u8 = undefined;
    for (0..count) |index| {
        @memcpy(result[index * text.len ..][0..text.len], text);
    }
    return result;
}

test "streamed description accepts 200 decoded bytes including 1200 raw escaped bytes and UTF-8" {
    try expectDescriptionParity("{\"rui_call_description\":\"" ++ repeatedDescriptionText("\\u0061", 200) ++ "\"}");
    try expectDescriptionParity("{\"rui_call_description\":\"" ++ repeatedDescriptionText("é", 100) ++ "\"}");
    try expectDescriptionParity("{\"rui_call_description\":\"" ++ repeatedDescriptionText("é", 101) ++ "\"}");
}

test "streamed description propagates source errors before and after a match" {
    const arguments = "{\"rui_call_description\":\"valid\",\"q\":1}";
    for ([_]usize{ 0, arguments.len - 1 }) |fail_at| {
        var source: DescriptionSource = .{ .bytes = arguments, .fail_at = fail_at };
        try std.testing.expectError(error.SourceFailed, descriptionRange(&source));
    }
}
