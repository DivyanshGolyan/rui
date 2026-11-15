const std = @import("std");
const document = @import("mcp/document.zig");

pub const Intent = enum { foreground, background };
pub const property = "rui_execution";
pub const property_schema = "\"" ++ property ++ "\":{\"type\":\"string\",\"enum\":[\"foreground\",\"background\"]}";
pub const SchemaError = std.Io.Writer.Error || error{ NameTaken, Malformed };

pub fn writeSchema(writer: *std.Io.Writer, input_schema: []const u8) SchemaError!void {
    if (document.kind(input_schema) != .object) return error.Malformed;
    const properties = document.member(input_schema, "properties");
    if (properties) |found| {
        if (document.kind(found) != .object) return error.Malformed;
        var members = document.Members.init(found);
        while (members.next()) |member| if (document.keyIs(member.key, property)) return error.NameTaken;
    }
    try writer.writeByte('{');
    var first = true;
    var members = document.Members.init(input_schema);
    while (members.next()) |member| {
        if (document.keyIs(member.key, "properties")) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("\"{s}\":{s}", .{ member.key, member.value });
    }
    if (!first) try writer.writeByte(',');
    try writer.writeAll("\"properties\":{");
    if (properties) |found| {
        var fields = document.Members.init(found);
        while (fields.next()) |member| try writer.print("\"{s}\":{s},", .{ member.key, member.value });
    }
    try writer.writeAll(property_schema ++ "}}");
}

pub fn schema(comptime original: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var buffer: [original.len + property_schema.len + 32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writeSchema(&writer, original) catch @compileError("invalid or reserved Host tool schema");
        const result = buffer[0..writer.end].*;
        return &result;
    }
}

pub fn Arguments(comptime Source: type) type {
    return struct {
        source: Source,
        intent: Intent = .foreground,
        present: bool = false,
        state: enum { start, key, value, tail } = .start,
        prefix: [6 * property.len + 3]u8 = undefined,
        prefix_len: usize = 0,
        prefix_at: usize = 0,
        comma: bool = false,
        emitted: bool = false,
        allow_end: bool = true,
        in_string: bool = false,
        escaped: bool = false,
        nesting: u8 = 0,
        lookahead: ?u8 = null,
        has_lookahead: bool = false,

        const Self = @This();

        pub fn peek(self: *Self) !?u8 {
            if (!self.has_lookahead) {
                self.lookahead = try self.next();
                self.has_lookahead = true;
            }
            return self.lookahead;
        }

        pub fn take(self: *Self) !u8 {
            const byte = try self.peek() orelse return error.MalformedArguments;
            self.has_lookahead = false;
            return byte;
        }

        fn next(self: *Self) !?u8 {
            while (true) {
                if (self.comma) {
                    self.comma = false;
                    return ',';
                }
                if (self.prefix_at < self.prefix_len) {
                    defer self.prefix_at += 1;
                    return self.prefix[self.prefix_at];
                }
                switch (self.state) {
                    .start => {
                        const byte = try self.read() orelse return null;
                        if (space(byte)) return byte;
                        self.state = if (byte == '{') .key else .tail;
                        return byte;
                    },
                    .key => try self.key(),
                    .tail => return self.read(),
                    .value => {
                        const byte = try self.read() orelse return null;
                        if (self.in_string) {
                            if (self.escaped) self.escaped = false else if (byte == '\\') self.escaped = true else if (byte == '"') self.in_string = false;
                            return byte;
                        }
                        switch (byte) {
                            '"' => self.in_string = true,
                            '{', '[' => {
                                if (self.nesting == 64) return error.MalformedArguments;
                                self.nesting += 1;
                            },
                            '}', ']' => {
                                if (self.nesting > 0) self.nesting -= 1 else if (byte == '}') self.state = .tail;
                            },
                            ',' => if (self.nesting == 0) {
                                self.state = .key;
                                self.allow_end = false;
                                continue;
                            },
                            else => {},
                        }
                        return byte;
                    },
                }
            }
        }

        fn read(self: *Self) !?u8 {
            if (try self.source.peek() == null) return null;
            return try self.source.take();
        }

        fn nonblank(self: *Self) !u8 {
            while (try self.read()) |byte| if (!space(byte)) return byte;
            return error.MalformedArguments;
        }

        fn key(self: *Self) !void {
            self.prefix_at = 0;
            self.prefix_len = 0;
            const first = try self.nonblank();
            if (first == '}' and self.allow_end) {
                self.prefix[0] = '}';
                self.prefix_len = 1;
                self.state = .tail;
                return;
            }
            if (first != '"') return error.MalformedArguments;
            self.prefix[0] = first;
            self.prefix_len = 1;
            self.in_string = true;
            self.escaped = false;
            while (self.prefix_len < self.prefix.len) {
                const byte = try self.read() orelse return error.MalformedArguments;
                self.prefix[self.prefix_len] = byte;
                self.prefix_len += 1;
                if (self.escaped) self.escaped = false else if (byte == '\\') self.escaped = true else if (byte == '"') {
                    self.in_string = false;
                    break;
                }
            }
            if (!self.in_string) {
                const written = self.prefix[0..self.prefix_len];
                if (!checkedString(written)) return error.MalformedArguments;
                if (document.keyIs(written[1 .. written.len - 1], property)) {
                    self.prefix_len = 0;
                    if (self.present) return error.InvalidExecutionOption;
                    self.present = true;
                    try self.execution();
                    return;
                }
            }
            self.comma = self.emitted;
            self.emitted = true;
            self.state = .value;
        }

        fn reservedNonblank(self: *Self) !u8 {
            return self.nonblank() catch |err| switch (err) {
                error.MalformedArguments => error.InvalidExecutionOption,
                else => return err,
            };
        }

        fn execution(self: *Self) !void {
            if (try self.reservedNonblank() != ':') return error.InvalidExecutionOption;
            if (try self.reservedNonblank() != '"') return error.InvalidExecutionOption;
            var value: [6 * "foreground".len + 2]u8 = undefined;
            value[0] = '"';
            var count: usize = 1;
            var escaped = false;
            while (true) {
                if (count == value.len) return error.InvalidExecutionOption;
                const byte = try self.read() orelse return error.InvalidExecutionOption;
                value[count] = byte;
                count += 1;
                if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') break;
            }
            const written = value[0..count];
            if (!checkedString(written)) return error.InvalidExecutionOption;
            self.intent = for (std.enums.values(Intent)) |intent| {
                if (document.keyIs(written[1 .. written.len - 1], @tagName(intent))) break intent;
            } else return error.InvalidExecutionOption;
            switch (try self.reservedNonblank()) {
                ',' => {
                    self.state = .key;
                    self.allow_end = false;
                },
                '}' => {
                    self.prefix[0] = '}';
                    self.prefix_len = 1;
                    self.state = .tail;
                },
                else => return error.InvalidExecutionOption,
            }
        }
    };
}

fn checkedString(written: []const u8) bool {
    var buffer: [6 * property.len + 9]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.writeAll("{\"v\":") catch return false;
    writer.writeAll(written) catch return false;
    writer.writeByte('}') catch return false;
    document.check(writer.buffered()) catch return false;
    return true;
}

fn space(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

const Slice = struct {
    bytes: []const u8,
    at: usize = 0,
    pub fn peek(self: *@This()) !?u8 {
        return if (self.at < self.bytes.len) self.bytes[self.at] else null;
    }
    pub fn take(self: *@This()) !u8 {
        const byte = try self.peek() orelse return error.InvalidExecutionOption;
        self.at += 1;
        return byte;
    }
};

fn filtered(input: []const u8, writer: *std.Io.Writer) !Intent {
    var source: Slice = .{ .bytes = input };
    var arguments: Arguments(*Slice) = .{ .source = &source };
    while (try arguments.peek()) |_| try writer.writeByte(try arguments.take());
    return arguments.intent;
}

test "execution metadata strips only the root field and preserves named arguments" {
    const Case = struct { input: []const u8, output: []const u8, intent: Intent };
    const cases = [_]Case{
        .{ .input = "{}", .output = "{}", .intent = .foreground },
        .{ .input = "{\"rui_execution\":\"background\"}", .output = "{}", .intent = .background },
        .{ .input = "{\"rui_execution\":\"foreground\",\"q\":1}", .output = "{\"q\":1}", .intent = .foreground },
        .{ .input = "{\"q\":1,\"rui_execution\":\"background\"}", .output = "{\"q\":1}", .intent = .background },
        .{ .input = "{\"q\":1,\"rui_execution\":\"background\",\"n\":[1,{\"k\":\",}\"}]}", .output = "{\"q\":1,\"n\":[1,{\"k\":\",}\"}]}", .intent = .background },
        .{ .input = "{\"rui_\\u0065xecution\":\"back\\u0067round\"}", .output = "{}", .intent = .background },
        .{ .input = "{\"\\u0072\\u0075\\u0069\\u005f\\u0065\\u0078\\u0065\\u0063\\u0075\\u0074\\u0069\\u006f\\u006e\":\"\\u0062\\u0061\\u0063\\u006b\\u0067\\u0072\\u006f\\u0075\\u006e\\u0064\"}", .output = "{}", .intent = .background },
        .{ .input = "{\"nested\":{\"rui_execution\":\"background\"}}", .output = "{\"nested\":{\"rui_execution\":\"background\"}}", .intent = .foreground },
        .{ .input = "{\"" ++ @as([100]u8, @splat('x')) ++ "\":0}", .output = "{\"" ++ @as([100]u8, @splat('x')) ++ "\":0}", .intent = .foreground },
    };
    for (cases) |case| {
        var buffer: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try std.testing.expectEqual(case.intent, try filtered(case.input, &writer));
        try std.testing.expectEqualStrings(case.output, writer.buffered());
        try document.check(writer.buffered());
    }
}

test "execution metadata rejects invalid duplicate and malformed reserved values" {
    for ([_][]const u8{
        "{\"rui_execution\":null}",
        "{\"rui_execution\":false}",
        "{\"rui_execution\":\"running\"}",
        "{\"rui_execution\":\"back\\ud800ground\"}",
        "{\"rui_execution\":\"background\",\"rui_execution\":\"foreground\"}",
        "{\"rui_execution\":\"background\" \"q\":1}",
    }) |input| {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try std.testing.expectError(error.InvalidExecutionOption, filtered(input, &writer));
    }
    for ([_][]const u8{ "{\"q\":1,}", "{\"rui_execution\":\"background\",}", "{not-json" }) |input| {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try std.testing.expectError(error.MalformedArguments, filtered(input, &writer));
    }
}

test "execution schema detects escaped reserved collisions and preserves required fields" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeSchema(&writer, "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}},\"required\":[\"q\"]}");
    try document.check(writer.buffered());
    try std.testing.expectEqualStrings("[\"q\"]", document.member(writer.buffered(), "required").?);
    writer.end = 0;
    try std.testing.expectError(error.NameTaken, writeSchema(&writer, "{\"properties\":{\"rui_\\u0065xecution\":{}}}"));
    try std.testing.expectEqualStrings("{\"type\":\"object\",\"properties\":{" ++ property_schema ++ "}}", comptime schema("{\"type\":\"object\"}"));
}
