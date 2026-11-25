const std = @import("std");
const document = @import("document.zig");

pub const description_property = "rui_call_description";
pub const description_max_bytes = @import("../tool_line.zig").max_bytes;

pub const Error = std.Io.Writer.Error || error{
    NameTaken,
    Malformed,
};

const property_text = "\"" ++ description_property ++ "\":{\"type\":\"string\",\"maxLength\":" ++
    std.fmt.comptimePrint("{d}", .{description_max_bytes}) ++ "}";

pub fn writeSchema(writer: *std.Io.Writer, input_schema: []const u8) Error!void {
    std.debug.assert(document.kind(input_schema) == .object);
    try check(input_schema);
    try writer.writeByte('{');
    var first = true;
    var members = document.Members.init(input_schema);
    while (members.next()) |found| {
        if (document.keyIs(found.key, "properties") or document.keyIs(found.key, "required")) continue;
        try writeMember(writer, &first, found.key, found.value);
    }
    try separate(writer, &first);
    try writer.writeAll("\"properties\":{");
    if (document.member(input_schema, "properties")) |properties| {
        var own = document.Members.init(properties);
        while (own.next()) |found| try writer.print("\"{s}\":{s},", .{ found.key, found.value });
    }
    try writer.writeAll(property_text ++ "}");
    try separate(writer, &first);
    try writer.writeAll("\"required\":[");
    if (document.member(input_schema, "required")) |required| {
        var items = document.Items.init(required);
        while (items.next()) |item| try writer.print("{s},", .{item});
    }
    try writer.writeAll("\"" ++ description_property ++ "\"]}");
}

pub fn check(input_schema: []const u8) Error!void {
    if (document.member(input_schema, "properties")) |properties| {
        if (document.kind(properties) != .object) return error.Malformed;
        var own = document.Members.init(properties);
        while (own.next()) |found| {
            if (document.keyIs(found.key, description_property)) return error.NameTaken;
        }
    }
    if (document.member(input_schema, "required")) |required| {
        if (document.kind(required) != .array) return error.Malformed;
    }
}

fn writeMember(writer: *std.Io.Writer, first: *bool, key: []const u8, value: []const u8) std.Io.Writer.Error!void {
    try separate(writer, first);
    try writer.print("\"{s}\":{s}", .{ key, value });
}

fn separate(writer: *std.Io.Writer, first: *bool) std.Io.Writer.Error!void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
}

fn shaped(buffer: []u8, schema: []const u8) Error![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writeSchema(&writer, schema);
    return writer.buffered();
}

test "a schema gains the description property and requires it" {
    var buffer: [512]u8 = undefined;
    const out = try shaped(&buffer, "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}},\"required\":[\"q\"]}");
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"},\"rui_call_description\":{\"type\":\"string\",\"maxLength\":200}},\"required\":[\"q\",\"rui_call_description\"]}",
        out,
    );
    try document.check(out);
}

test "a schema without properties or required gets both" {
    var buffer: [512]u8 = undefined;
    const out = try shaped(&buffer, "{\"type\":\"object\"}");
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"rui_call_description\":{\"type\":\"string\",\"maxLength\":200}},\"required\":[\"rui_call_description\"]}",
        out,
    );
    try document.check(out);
}

test "other members are copied as written" {
    var buffer: [512]u8 = undefined;
    const out = try shaped(&buffer, "{\"additionalProperties\":false,\"properties\":{},\"title\":\"A\\u00e9\"}");
    try std.testing.expect(std.mem.indexOf(u8, out, "\"additionalProperties\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"title\":\"A\\u00e9\"") != null);
    try document.check(out);
}

test "a schema that already names the property is refused" {
    var buffer: [512]u8 = undefined;
    try std.testing.expectError(error.NameTaken, shaped(&buffer, "{\"properties\":{\"rui_call_description\":{}}}"));
    try std.testing.expectError(error.NameTaken, shaped(&buffer, "{\"properties\":{\"rui_call_\\u0064escription\":{}}}"));
}

test "properties that is not an object, or required that is not an array, is malformed" {
    var buffer: [512]u8 = undefined;
    try std.testing.expectError(error.Malformed, shaped(&buffer, "{\"properties\":[]}"));
    try std.testing.expectError(error.Malformed, shaped(&buffer, "{\"required\":\"q\"}"));
}
