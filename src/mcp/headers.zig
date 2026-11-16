const std = @import("std");
const http1 = @import("../http1/request.zig");
const Parser = @import("../http1/Parser.zig");
const document = @import("document.zig");

pub const max_value_bytes = 1024;
pub const max_params = 16;
pub const max_param_name_bytes = 64;
pub const max_path_key_bytes = 64;

pub const sentinel_prefix = "=?base64?";
pub const sentinel_suffix = "?=";

pub const Error = http1.FieldError || std.Io.Writer.Error || error{HeaderValueTooLong};

/// Writes `name: value` with `value` (decoded UTF-8) as the transport's
/// Value Encoding asks: as it is when it is plain header-safe ASCII,
/// otherwise as `=?base64?...?=`.
pub fn writeValue(writer: *std.Io.Writer, name: []const u8, value: []const u8) Error!void {
    if (value.len > max_value_bytes) return error.HeaderValueTooLong;
    if (isPlain(value)) return http1.writeField(writer, .{ .name = name, .value = value });
    const encoder = std.base64.standard.Encoder;
    var encoded: [sentinel_prefix.len + encoder.calcSize(max_value_bytes) + sentinel_suffix.len]u8 = undefined;
    @memcpy(encoded[0..sentinel_prefix.len], sentinel_prefix);
    const body = encoder.encode(encoded[sentinel_prefix.len..], value);
    const end = sentinel_prefix.len + body.len;
    @memcpy(encoded[end..][0..sentinel_suffix.len], sentinel_suffix);
    return http1.writeField(writer, .{ .name = name, .value = encoded[0 .. end + sentinel_suffix.len] });
}

fn isPlain(value: []const u8) bool {
    if (!http1.isFieldValue(value)) return false;
    return !(std.mem.startsWith(u8, value, sentinel_prefix) and std.mem.endsWith(u8, value, sentinel_suffix));
}

pub const Invalid = enum {
    not_statically_reachable,
    not_a_string,
    bad_name,
    duplicate_name,
    not_primitive,
    too_many,
    path_key_too_long,
};

const Primitive = enum { string, integer, boolean };

const Annotation = struct {
    path: []const []const u8,
    name: []const u8,
    primitive: Primitive,
};

pub fn check(input_schema: []const u8) ?Invalid {
    var checker: Checker = .{};
    walk(input_schema, &checker) catch |invalid| return invalidOf(invalid);
    return null;
}

fn invalidOf(err: WalkError) Invalid {
    return std.meta.stringToEnum(Invalid, @errorName(err)).?;
}

const WalkError = error{ not_statically_reachable, not_a_string, bad_name, duplicate_name, not_primitive, too_many, path_key_too_long };

const Checker = struct {
    names: [max_params][max_param_name_bytes]u8 = undefined,
    lengths: [max_params]u8 = undefined,
    count: usize = 0,

    fn annotation(self: *Checker, found: Annotation) WalkError!void {
        if (self.count == max_params) return error.too_many;
        var text: [max_param_name_bytes]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&text);
        document.writeDecoded(&writer, found.name) catch return error.bad_name;
        const name = writer.buffered();
        for (self.names[0..self.count], self.lengths[0..self.count]) |*earlier, length| {
            if (std.ascii.eqlIgnoreCase(earlier[0..length], name)) return error.duplicate_name;
        }
        @memcpy(self.names[self.count][0..name.len], name);
        self.lengths[self.count] = @intCast(name.len);
        self.count += 1;
    }
};

pub fn writeParams(writer: *std.Io.Writer, input_schema: []const u8, arguments: []const u8) Error!void {
    var params: Params = .{ .writer = writer, .arguments = arguments };
    walk(input_schema, &params) catch unreachable;
    if (params.failure) |failure| return failure;
}

const Params = struct {
    writer: *std.Io.Writer,
    arguments: []const u8,
    failure: ?Error = null,

    fn annotation(self: *Params, found: Annotation) WalkError!void {
        if (self.failure != null) return;
        self.write(found) catch |err| {
            self.failure = err;
        };
    }

    fn write(self: *Params, found: Annotation) Error!void {
        var value = self.arguments;
        for (found.path) |key| {
            if (document.kind(value) != .object) return;
            var decoded: [max_path_key_bytes]u8 = undefined;
            var key_writer: std.Io.Writer = .fixed(&decoded);
            document.writeDecoded(&key_writer, key) catch unreachable;
            value = document.member(value, key_writer.buffered()) orelse return;
        }
        var text: [max_value_bytes]u8 = undefined;
        var text_writer: std.Io.Writer = .fixed(&text);
        switch (found.primitive) {
            .string => {
                if (document.kind(value) != .string) return;
                const contents = document.contents(value);
                if (document.decodedLength(contents) > max_value_bytes) return error.HeaderValueTooLong;
                document.writeDecoded(&text_writer, contents) catch unreachable;
            },
            .integer => {
                if (!isSafeInteger(value)) return;
                text_writer.writeAll(value) catch unreachable;
            },
            .boolean => switch (document.kind(value)) {
                .true_value, .false_value => text_writer.writeAll(value) catch unreachable,
                else => return,
            },
        }
        var name: [10 + max_param_name_bytes]u8 = undefined;
        var name_writer: std.Io.Writer = .fixed(&name);
        name_writer.writeAll("Mcp-Param-") catch unreachable;
        document.writeDecoded(&name_writer, found.name) catch unreachable;
        try writeValue(self.writer, name_writer.buffered(), text_writer.buffered());
    }
};

/// A JSON integer, without fraction or exponent, within JavaScript's safe
/// range, as the transport requires of a mirrored integer.
fn isSafeInteger(value: []const u8) bool {
    if (document.kind(value) != .number) return false;
    const digits = if (value[0] == '-') value[1..] else value;
    for (digits) |digit| if (!std.ascii.isDigit(digit)) return false;
    if (digits.len > 16) return false;
    const magnitude = std.fmt.parseInt(u64, digits, 10) catch return false;
    return magnitude <= (1 << 53) - 1;
}

const data_keywords = [_][]const u8{ "const", "enum", "default", "examples" };

const max_depth = 64;

fn walk(input_schema: []const u8, visitor: anytype) WalkError!void {
    var path: [max_depth][]const u8 = undefined;
    try walkSchema(input_schema, true, &path, 0, visitor);
}

fn walkSchema(schema: []const u8, reachable: bool, path: *[max_depth][]const u8, depth: usize, visitor: anytype) WalkError!void {
    if (document.kind(schema) != .object) return walkOther(schema, path, depth, visitor);
    var members = document.Members.init(schema);
    while (members.next()) |found| {
        if (document.keyIs(found.key, "x-mcp-header")) {
            if (!reachable or depth == 0) return error.not_statically_reachable;
            try annotate(schema, found.value, path[0..depth], visitor);
        } else if (document.keyIs(found.key, "properties") and document.kind(found.value) == .object) {
            var properties = document.Members.init(found.value);
            while (properties.next()) |property| {
                path[depth] = property.key;
                try walkSchema(property.value, reachable, path, depth + 1, visitor);
            }
        } else if (!isDataKeyword(found.key)) {
            try walkOther(found.value, path, depth, visitor);
        }
    }
}

fn walkOther(value: []const u8, path: *[max_depth][]const u8, depth: usize, visitor: anytype) WalkError!void {
    switch (document.kind(value)) {
        .object => try walkSchema(value, false, path, depth, visitor),
        .array => {
            var items = document.Items.init(value);
            while (items.next()) |item| try walkOther(item, path, depth, visitor);
        },
        else => {},
    }
}

fn isDataKeyword(key: []const u8) bool {
    for (data_keywords) |keyword| if (document.keyIs(key, keyword)) return true;
    return false;
}

fn annotate(schema: []const u8, annotation: []const u8, path: []const []const u8, visitor: anytype) WalkError!void {
    if (document.kind(annotation) != .string) return error.not_a_string;
    const name = document.contents(annotation);
    if (document.decodedLength(name) > max_param_name_bytes) return error.bad_name;
    var text: [max_param_name_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text);
    document.writeDecoded(&writer, name) catch unreachable;
    if (!Parser.isToken(writer.buffered())) return error.bad_name;
    for (path) |key| {
        if (document.decodedLength(key) > max_path_key_bytes) return error.path_key_too_long;
    }
    const type_value = document.member(schema, "type") orelse return error.not_primitive;
    if (document.kind(type_value) != .string) return error.not_primitive;
    const type_name = document.contents(type_value);
    const primitive: Primitive = if (document.keyIs(type_name, "string"))
        .string
    else if (document.keyIs(type_name, "integer"))
        .integer
    else if (document.keyIs(type_name, "boolean"))
        .boolean
    else
        return error.not_primitive;
    try visitor.annotation(.{ .path = path, .name = name, .primitive = primitive });
}

fn expectInvalid(expected: ?Invalid, schema: []const u8) !void {
    var wrapped: [1024]u8 = undefined;
    try document.check(try std.fmt.bufPrint(&wrapped, "{{\"s\":{s}}}", .{schema}));
    try std.testing.expectEqual(expected, check(schema));
}

test "annotations on properties reached only through properties are valid" {
    try expectInvalid(null, "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}}}");
    try expectInvalid(null,
        \\{"type":"object","properties":{
        \\  "region":{"type":"string","x-mcp-header":"Region"},
        \\  "n":{"type":"integer","x-mcp-header":"Count"},
        \\  "nested":{"type":"object","properties":{"flag":{"type":"boolean","x-mcp-header":"Flag"}}},
        \\  "e":{"type":"string","enum":[{"x-mcp-header":"Data"}],"default":{"x-mcp-header":"Data"}}}}
    );
}

test "annotations anywhere else make the tool invalid" {
    try expectInvalid(.not_statically_reachable, "{\"type\":\"string\",\"x-mcp-header\":\"Root\"}");
    try expectInvalid(.not_statically_reachable, "{\"properties\":{\"a\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"x-mcp-header\":\"A\"}}}}");
    try expectInvalid(.not_statically_reachable, "{\"properties\":{\"a\":{\"items\":{\"properties\":{\"b\":{\"type\":\"string\",\"x-mcp-header\":\"B\"}}}}}}");
    try expectInvalid(.not_statically_reachable, "{\"properties\":{\"a\":{\"oneOf\":[{\"type\":\"string\",\"x-mcp-header\":\"A\"}]}}}");
    try expectInvalid(.not_statically_reachable, "{\"$defs\":{\"d\":{\"type\":\"string\",\"x-mcp-header\":\"D\"}}}");
    try expectInvalid(.not_statically_reachable, "{\"if\":{\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"A\"}}}}");
}

test "an annotation must name a unique token on a primitive property" {
    try expectInvalid(.not_a_string, "{\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":1}}}");
    try expectInvalid(.bad_name, "{\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"\"}}}");
    try expectInvalid(.bad_name, "{\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"Two Words\"}}}");
    try expectInvalid(.bad_name, "{\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"Line\\r\\nBreak\"}}}");
    try expectInvalid(.bad_name, "{\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"" ++ @as([max_param_name_bytes + 1]u8, @splat('a')) ++ "\"}}}");
    try expectInvalid(.duplicate_name, "{\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"Same\"},\"b\":{\"type\":\"string\",\"x-mcp-header\":\"sAME\"}}}");
    try expectInvalid(.not_primitive, "{\"properties\":{\"a\":{\"type\":\"number\",\"x-mcp-header\":\"A\"}}}");
    try expectInvalid(.not_primitive, "{\"properties\":{\"a\":{\"x-mcp-header\":\"A\"}}}");
    try expectInvalid(.not_primitive, "{\"properties\":{\"a\":{\"type\":[\"string\",\"null\"],\"x-mcp-header\":\"A\"}}}");
    try expectInvalid(.path_key_too_long, "{\"properties\":{\"" ++ @as([max_path_key_bytes + 1]u8, @splat('k')) ++ "\":{\"type\":\"string\",\"x-mcp-header\":\"A\"}}}");
    var many: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&many);
    try writer.writeAll("{\"properties\":{");
    for (0..max_params + 1) |index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("\"p{d}\":{{\"type\":\"string\",\"x-mcp-header\":\"P{d}\"}}", .{ index, index });
    }
    try writer.writeAll("}}");
    try expectInvalid(.too_many, writer.buffered());
}

test "values are written plain when header-safe, else base64 with the sentinel" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "us-west1", "us-west1" },
        .{ "Hello, \xe4\xb8\x96\xe7\x95\x8c", "=?base64?SGVsbG8sIOS4lueVjA==?=" },
        .{ " padded ", "=?base64?IHBhZGRlZCA=?=" },
        .{ "line1\nline2", "=?base64?bGluZTEKbGluZTI=?=" },
        .{ "=?base64?literal?=", "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=" },
    };
    for (cases) |case| {
        var buffer: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try writeValue(&writer, "Mcp-Param-X", case[0]);
        var expected: [128]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Mcp-Param-X: {s}\r\n", .{case[1]}), writer.buffered());
    }
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const longest: [max_value_bytes]u8 = @splat(0xff);
    try writeValue(&writer, "Mcp-Name", &longest);
    const too_long: [max_value_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.HeaderValueTooLong, writeValue(&writer, "Mcp-Name", &too_long));
}

test "a call mirrors each annotated argument it has, by path" {
    const schema =
        \\{"type":"object","properties":{
        \\  "region":{"type":"string","x-mcp-header":"Region"},
        \\  "n":{"type":"integer","x-mcp-header":"Count"},
        \\  "nested":{"type":"object","properties":{"fl\u0061g":{"type":"boolean","x-mcp-header":"Flag"}}},
        \\  "absent":{"type":"string","x-mcp-header":"Absent"},
        \\  "query":{"type":"string"}}}
    ;
    const cases = [_]struct { []const u8, []const u8 }{
        .{
            "{\"query\":\"select 1\",\"region\":\"us-w\\u0065st1\",\"n\":-7,\"nested\":{\"flag\":true}}",
            "Mcp-Param-Region: us-west1\r\nMcp-Param-Count: -7\r\nMcp-Param-Flag: true\r\n",
        },
        .{ "{\"region\":\"caf\\u00e9\"}", "Mcp-Param-Region: =?base64?Y2Fmw6k=?=\r\n" },
        .{ "{\"region\":5,\"n\":1.5,\"nested\":{\"flag\":\"yes\"}}", "" },
        .{ "{\"n\":9007199254740992}", "" },
        .{ "{\"n\":9007199254740991,\"nested\":[1]}", "Mcp-Param-Count: 9007199254740991\r\n" },
        .{ "{\"n\":1e3}", "" },
    };
    try std.testing.expectEqual(null, check(schema));
    for (cases) |case| {
        try document.check(case[0]);
        var buffer: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try writeParams(&writer, schema, case[0]);
        try std.testing.expectEqualStrings(case[1], writer.buffered());
    }
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const long_argument = "{\"region\":\"" ++ @as([max_value_bytes + 1]u8, @splat('a')) ++ "\"}";
    try std.testing.expectError(error.HeaderValueTooLong, writeParams(&writer, schema, long_argument));
}
