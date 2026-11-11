//! Streaming object JSON normalization for spec output schemas. Member order
//! and number spelling are preserved, as with std.json.Value serialization;
//! whitespace and string escapes have one compact representation. No schema
//! body or complete token is retained in memory.
const std = @import("std");
const max_depth = @import("json_limits.zig").max_depth;

pub const Encoder = struct {
    scanner: std.json.Scanner,
    containers: [max_depth]Container = undefined,
    depth: usize = 0,
    fragment: enum { none, string, number } = .none,
    done: bool = false,

    const Container = struct { object: bool, key: bool = true, empty: bool = true };

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .scanner = std.json.Scanner.initStreaming(allocator) };
    }

    pub fn deinit(self: *Encoder) void {
        self.scanner.deinit();
    }

    /// Consumes one byte, emitting canonical bytes to sink.write. True consumes
    /// the root object's closing brace, never any subsequent request syntax.
    pub fn feed(self: *Encoder, byte: u8, sink: anytype) !bool {
        std.debug.assert(!self.done);
        self.scanner.feedInput(&.{byte});
        while (true) {
            const token = self.scanner.next() catch |err| switch (err) {
                error.BufferUnderrun => return self.done,
                else => return err,
            };
            switch (token) {
                .object_begin, .array_begin => {
                    if (self.depth == 0 and token != .object_begin) return error.InvalidJsonShape;
                    if (self.depth == self.containers.len) return error.JsonTooDeep;
                    try self.prefix(sink);
                    const object = token == .object_begin;
                    try sink.write(if (object) "{" else "[");
                    self.containers[self.depth] = .{ .object = object };
                    self.depth += 1;
                },
                .object_end, .array_end => {
                    self.depth -= 1;
                    try sink.write(if (token == .object_end) "}" else "]");
                    if (self.depth == 0) self.done = true;
                },
                .partial_string, .string => |bytes| {
                    try self.string(bytes, sink);
                    if (token == .string) {
                        try sink.write("\"");
                        self.fragment = .none;
                    }
                },
                .partial_string_escaped_1 => |bytes| try self.string(&bytes, sink),
                .partial_string_escaped_2 => |bytes| try self.string(&bytes, sink),
                .partial_string_escaped_3 => |bytes| try self.string(&bytes, sink),
                .partial_string_escaped_4 => |bytes| try self.string(&bytes, sink),
                .partial_number, .number => |bytes| {
                    if (self.fragment == .none) try self.prefix(sink);
                    try sink.write(bytes);
                    self.fragment = if (token == .number) .none else .number;
                },
                .true, .false, .null => {
                    try self.prefix(sink);
                    try sink.write(@tagName(token));
                },
                else => unreachable,
            }
        }
    }

    fn prefix(self: *Encoder, sink: anytype) !void {
        if (self.depth == 0) return;
        const parent = &self.containers[self.depth - 1];
        if (parent.object) {
            if (!parent.key) try sink.write(":") else if (!parent.empty) try sink.write(",");
            parent.key = !parent.key;
        } else if (!parent.empty) try sink.write(",");
        parent.empty = false;
    }

    fn string(self: *Encoder, bytes: []const u8, sink: anytype) !void {
        if (self.fragment == .none) {
            try self.prefix(sink);
            try sink.write("\"");
            self.fragment = .string;
        }
        for (bytes) |byte| switch (byte) {
            '"' => try sink.write("\\\""),
            '\\' => try sink.write("\\\\"),
            '\n' => try sink.write("\\n"),
            '\r' => try sink.write("\\r"),
            '\t' => try sink.write("\\t"),
            0...0x07, 0x0b, 0x0e...0x1f => {
                const hex = "0123456789abcdef";
                try sink.write(&.{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 15] });
            },
            0x08 => try sink.write("\\b"),
            0x0c => try sink.write("\\f"),
            else => try sink.write(&.{byte}),
        };
    }
};

test "schema objects normalize incrementally like DOM serialization" {
    const inputs = [_][]const u8{
        "{}",
        "{ \"type\" : \"object\", \"properties\": {\"a\": {\"enum\":[null,true,false,1,-2.0,1e20,\"x\\u00e9\\n\\b\\f\\/\\\\\\\"\"]}}}",
        "{\"bytes\":\"0\",\"sha256\":\"not a reference\",\"value\":{},\"state\":\"value\"}",
    };
    for (inputs) |input| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        const Sink = struct {
            writer: *std.Io.Writer,
            pub fn write(self: @This(), bytes: []const u8) !void {
                try self.writer.writeAll(bytes);
            }
        };
        var encoder = Encoder.init(std.testing.allocator);
        defer encoder.deinit();
        for (input, 0..) |byte, index| try std.testing.expectEqual(index == input.len - 1, try encoder.feed(byte, Sink{ .writer = &output.writer }));
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, input, .{ .parse_numbers = false });
        defer parsed.deinit();
        const expected = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, output.written());
    }
}
