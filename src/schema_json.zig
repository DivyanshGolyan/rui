const std = @import("std");
const max_depth = @import("json_limits.zig").max_depth;

/// The JSON value a captured document must be: a schema is an object, an app tools declaration an array.
pub const Root = enum { object, array };

/// The token run the encoder is inside: a string or a number split across input bytes, or neither.
/// `next` is the one decision table for it; the encoder reads `fragment` and moves it only through `next`.
pub const Fragment = enum {
    none,
    string,
    number,

    pub const Event = enum { text, string_end, number_part, number_end };

    pub fn next(self: Fragment, event: Event) Fragment {
        return switch (event) {
            .text => if (self == .number) .number else .string,
            .string_end => .none,
            .number_part => .number,
            .number_end => .none,
        };
    }
};

pub const Encoder = struct {
    scanner: std.json.Scanner,
    containers: [max_depth]Container = undefined,
    depth: usize = 0,
    fragment: Fragment = .none,
    done: bool = false,
    root: Root = .object,

    const Container = struct { object: bool, key: bool = true, empty: bool = true };

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return initRoot(allocator, .object);
    }

    pub fn initRoot(allocator: std.mem.Allocator, root: Root) Encoder {
        return .{ .scanner = std.json.Scanner.initStreaming(allocator), .root = root };
    }

    pub fn deinit(self: *Encoder) void {
        self.scanner.deinit();
    }

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
                    const opens_root = if (self.root == .object) token == .object_begin else token == .array_begin;
                    if (self.depth == 0 and !opens_root) return error.InvalidJsonShape;
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
                        self.fragment = self.fragment.next(.string_end);
                    }
                },
                .partial_string_escaped_1 => |bytes| try self.string(&bytes, sink),
                .partial_string_escaped_2 => |bytes| try self.string(&bytes, sink),
                .partial_string_escaped_3 => |bytes| try self.string(&bytes, sink),
                .partial_string_escaped_4 => |bytes| try self.string(&bytes, sink),
                .partial_number, .number => |bytes| {
                    if (self.fragment == .none) try self.prefix(sink);
                    try sink.write(bytes);
                    self.fragment = self.fragment.next(if (token == .number) .number_end else .number_part);
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
        }
        self.fragment = self.fragment.next(.text);
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

test "app tool arrays normalize incrementally like DOM serialization" {
    const input = "[{ \"name\" : \"a\", \"input_schema\": {\"enum\":[null,1.5,\"x\\n\"]}}, {}]";
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const Sink = struct {
        writer: *std.Io.Writer,
        pub fn write(self: @This(), bytes: []const u8) !void {
            try self.writer.writeAll(bytes);
        }
    };
    var encoder = Encoder.initRoot(std.testing.allocator, .array);
    defer encoder.deinit();
    for (input, 0..) |byte, index| try std.testing.expectEqual(index == input.len - 1, try encoder.feed(byte, Sink{ .writer = &output.writer }));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, input, .{ .parse_numbers = false });
    defer parsed.deinit();
    const expected = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, output.written());
}

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

test "CM-75 the encoder's fragment moves only through its table over every state and event" {
    const Cell = struct { from: Fragment, event: Fragment.Event, next: Fragment };
    const cells = [_]Cell{
        .{ .from = .none, .event = .text, .next = .string },
        .{ .from = .string, .event = .text, .next = .string },
        .{ .from = .number, .event = .text, .next = .number },
        .{ .from = .none, .event = .string_end, .next = .none },
        .{ .from = .string, .event = .string_end, .next = .none },
        .{ .from = .number, .event = .string_end, .next = .none },
        .{ .from = .none, .event = .number_part, .next = .number },
        .{ .from = .string, .event = .number_part, .next = .number },
        .{ .from = .number, .event = .number_part, .next = .number },
        .{ .from = .none, .event = .number_end, .next = .none },
        .{ .from = .string, .event = .number_end, .next = .none },
        .{ .from = .number, .event = .number_end, .next = .none },
    };
    // Each (state, event) pair is listed exactly once.
    var listed = std.mem.zeroes([std.enums.values(Fragment).len][std.enums.values(Fragment.Event).len]u8);
    for (cells) |cell| {
        try std.testing.expectEqual(cell.next, cell.from.next(cell.event));
        listed[@backingInt(cell.from)][@backingInt(cell.event)] += 1;
    }
    for (listed) |row| for (row) |count| try std.testing.expectEqual(@as(u8, 1), count);
}
