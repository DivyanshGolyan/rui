//! A call's arguments as the server receives them (D62). The model fills in
//! the saved schema, which carries `rui_call_description`; the server is
//! sent only the fields its own schema lists, and the description stays
//! with Rui for the conversation line.
//!
//! A functional core: checked JSON in, bytes out.
const std = @import("std");
const document = @import("document.zig");
const shape = @import("shape.zig");

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

fn description(value: []const u8) ?[]const u8 {
    if (document.kind(value) != .string) return null;
    const text = document.contents(value);
    if (document.decodedLength(text) > shape.description_max_bytes) return null;
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
