//! Frontend-only tool references and bounded, terminal-safe output rows.
//! The lifecycle owner retains open intent, never closed output. The existing document's
//! hidden OSC 8 address representation carries these line-level markers.
const std = @import("std");
const Text = @import("TerminalText.zig");
const protocol = @import("protocol.zig");

pub const Reference = struct {
    source: enum { activity, conversation },
    position: u64,
    ordinal: u64,
    content: protocol.ActivityItem.Content,
};
/// A Tool Result has one canonical Conversation identity even when the
/// live Activity feed discovered it. Read transport is not fold identity.
pub fn resultReference(position: u64, ordinal: u64, content: protocol.ActivityItem.Content) Reference {
    return .{ .source = .conversation, .position = position, .ordinal = ordinal, .content = content };
}

pub const prefix = "rui-tool:";
pub const output_uri = "rui-tool-output";
pub const more_uri = "rui-tool-more";
pub const output_marker = Text.link_open ++ output_uri ++ Text.link_end ++ Text.link_close;
pub const more_marker = Text.link_open ++ more_uri ++ Text.link_end ++ Text.link_close;
pub const max_lines = 20;
pub const max_bytes = 8192;

pub fn marker(reference: Reference, sink: anytype) !void {
    var buffer: [192]u8 = undefined;
    const digest = std.fmt.bytesToHex(reference.content.digest, .lower);
    const uri = try std.fmt.bufPrint(&buffer, prefix ++ "{s}:{d}:{d}:{d}:{s}", .{ if (reference.source == .activity) "a" else "c", reference.position, reference.ordinal, reference.content.length, digest });
    try sink.feed(Text.link_open);
    try sink.feed(uri);
    try sink.feed(Text.link_end ++ Text.link_close);
}

pub fn parse(uri: []const u8) ?Reference {
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    var parts = std.mem.splitScalar(u8, uri[prefix.len..], ':');
    const source = parts.next() orelse return null;
    const position = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    const ordinal = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    const length = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    const hex = parts.next() orelse return null;
    if (hex.len != 64 or parts.next() != null) return null;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, hex) catch return null;
    return .{ .source = if (std.mem.eql(u8, source, "a")) .activity else if (std.mem.eql(u8, source, "c")) .conversation else return null, .position = position, .ordinal = ordinal, .content = .{ .length = length, .digest = digest } };
}

/// A minimum retained heading's hidden reference plus its newline. Bounds
/// the possible heading population without retaining display offsets.
pub const minimum_reference_bytes = prefix.len + "a:0:0:0:".len + 64 + 1;

pub fn referenceIndex(references: []const Reference, reference: Reference) ?usize {
    for (references, 0..) |held, index| if (std.meta.eql(held, reference)) return index;
    return null;
}

/// One toggle's bounded display prefix of the authenticated stored result.
/// Every byte is literal input to terminal escaping, including tool envelope
/// headers, labels and pointers. Display policy never changes stored/model text.
/// Two fixed buffers retain raw rows and one incoming/escaped line.
pub const Output = struct {
    raw: [max_bytes]u8 = undefined,
    escaped: [max_bytes]u8 = undefined,
    length: usize = 0,
    line_length: usize = 0,
    line_overflow: bool = false,
    cut: bool = false,
    lines: u64 = 0,

    pub fn feed(self: *Output, bytes: []const u8) !void {
        for (bytes) |byte| self.printByte(byte);
    }

    fn printByte(self: *Output, byte: u8) void {
        if (byte == '\n') {
            self.keep(self.escaped[0..self.line_length], !self.line_overflow);
            self.line_length = 0;
            self.line_overflow = false;
        } else if (self.line_length < self.escaped.len) {
            self.escaped[self.line_length] = byte;
            self.line_length += 1;
        } else self.line_overflow = true;
    }

    fn endLine(self: *Output) void {
        if (self.line_length != 0 or self.line_overflow) self.keep(self.escaped[0..self.line_length], !self.line_overflow);
        self.line_length = 0;
        self.line_overflow = false;
    }

    fn keep(self: *Output, bytes: []const u8, whole: bool) void {
        self.lines += 1;
        if (self.cut) return;
        const count = @min(bytes.len, self.raw.len - self.length);
        @memcpy(self.raw[self.length..][0..count], bytes[0..count]);
        self.length += count;
        self.cut = !whole or count != bytes.len or self.length == self.raw.len;
        if (!self.cut) {
            self.raw[self.length] = '\n';
            self.length += 1;
        }
    }

    pub fn finish(self: *Output, sink: anytype) !void {
        self.endLine();
        if (self.lines == 0) return sink.feed(output_marker ++ "    \n");
        var at: usize = 0;
        var shown: u64 = 0;
        var budget: usize = max_bytes;
        while (at < self.length and shown < max_lines) {
            const end = std.mem.indexOfScalarPos(u8, self.raw[0..self.length], at, '\n') orelse self.length;
            // A byte-bound cut within a line has no complete line to present.
            if (end == self.length and self.cut) break;
            var writer = std.Io.Writer.fixed(self.escaped[0..budget]);
            var text: Text = .{ .mode = .multiline };
            text.feed(&writer, self.raw[at..end]) catch break;
            text.finish(&writer) catch break;
            try sink.feed(output_marker);
            try sink.feed("    ");
            try sink.feed(writer.buffered());
            try sink.feed("\n");
            budget -= writer.buffered().len;
            shown += 1;
            at = end + 1;
        }
        if (self.lines > shown) {
            var buffer: [64]u8 = undefined;
            try sink.feed(more_marker ++ "    ");
            try sink.feed(try std.fmt.bufPrint(&buffer, "… {d} more lines\n", .{self.lines - shown}));
        }
    }
};

test "tool references retain every authority field through the internal marker" {
    const reference: Reference = .{ .source = .conversation, .position = 987654321, .ordinal = 42, .content = .{ .length = 12345, .digest = protocol.contentDigest("saved output") } };
    const Sink = struct {
        writer: *std.Io.Writer,
        pub fn feed(self: @This(), bytes: []const u8) !void {
            try self.writer.writeAll(bytes);
        }
    };
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try marker(reference, Sink{ .writer = &writer });
    const address = writer.buffered()[Text.link_open.len .. writer.end - Text.link_end.len - Text.link_close.len];
    try std.testing.expect(std.meta.eql(reference, parse(address).?));
    try std.testing.expect(parse("rui-tool:bad:1:2:3:abc") == null);
    try std.testing.expect(parse("https://example.com") == null);
}

test "tool display preserves stored envelopes and literal delimiters across every read split" {
    const Sink = struct {
        writer: *std.Io.Writer,
        pub fn feed(self: @This(), bytes: []const u8) !void {
            try self.writer.writeAll(bytes);
        }
    };
    const output = try std.testing.allocator.create(Output);
    defer std.testing.allocator.destroy(output);
    const cases = [_]struct { bytes: []const u8, expected: []const u8 }{
        .{ .bytes = "Bash failed. Exit code: 1.\nstdout tail:\nstderr tail:\n[earlier output omitted]\nFull stdout: literal\nFull stderr: literal\n", .expected = output_marker ++ "    Bash failed. Exit code: 1.\n" ++ output_marker ++ "    stdout tail:\n" ++ output_marker ++ "    stderr tail:\n" ++ output_marker ++ "    [earlier output omitted]\n" ++ output_marker ++ "    Full stdout: literal\n" ++ output_marker ++ "    Full stderr: literal\n" },
        .{ .bytes = "a different tool\nBash succeeded. Exit code: 0.\nstderr tail:\nliteral", .expected = output_marker ++ "    a different tool\n" ++ output_marker ++ "    Bash succeeded. Exit code: 0.\n" ++ output_marker ++ "    stderr tail:\n" ++ output_marker ++ "    literal\n" },
        .{ .bytes = "out\n\nerr\n", .expected = output_marker ++ "    out\n" ++ output_marker ++ "    \n" ++ output_marker ++ "    err\n" },
        .{ .bytes = "", .expected = output_marker ++ "    \n" },
        .{ .bytes = "\x1b[2J", .expected = output_marker ++ "    \\x1b[2J\n" },
    };
    var rendered: [32768]u8 = undefined;
    for (cases) |case| {
        for (0..case.bytes.len + 1) |split| {
            output.* = .{};
            try output.feed(case.bytes[0..split]);
            try output.feed(case.bytes[split..]);
            var writer = std.Io.Writer.fixed(&rendered);
            try output.finish(Sink{ .writer = &writer });
            try std.testing.expectEqualStrings(case.expected, writer.buffered());
        }
        output.* = .{};
        for (case.bytes) |byte| try output.feed(&.{byte});
        var writer = std.Io.Writer.fixed(&rendered);
        try output.finish(Sink{ .writer = &writer });
        try std.testing.expectEqualStrings(case.expected, writer.buffered());
    }
}

test "tool display bounds stored raw escaped and line prefixes without parsing" {
    const Sink = struct {
        writer: *std.Io.Writer,
        pub fn feed(self: @This(), bytes: []const u8) !void {
            try self.writer.writeAll(bytes);
        }
    };
    const output = try std.testing.allocator.create(Output);
    defer std.testing.allocator.destroy(output);
    const lines: [32 * 5]u8 = @bitCast(@as([32][5]u8, @splat("line\n".*)));
    const envelope = "Bash succeeded. Exit code: 0.\nstdout tail:\n" ++ lines;
    const long = @as([max_bytes + 1]u8, @splat('x')) ++ "\nsecond\n";
    const escaped = @as([3000]u8, @splat(0x1b)) ++ "\nsecond\n";
    var rendered: [32768]u8 = undefined;
    for ([_][]const u8{ &lines, envelope, long, escaped }, 0..) |bytes, case_index| {
        for ([_]usize{ 1, 257, 8192 }) |chunk| {
            output.* = .{};
            var at: usize = 0;
            while (at < bytes.len) {
                const end = @min(at + chunk, bytes.len);
                try output.feed(bytes[at..end]);
                at = end;
            }
            var writer = std.Io.Writer.fixed(&rendered);
            try output.finish(Sink{ .writer = &writer });
            if (case_index == 0) {
                try std.testing.expectEqual(@as(usize, max_lines), std.mem.count(u8, writer.buffered(), output_marker ++ "    line\n"));
                try std.testing.expect(std.mem.endsWith(u8, writer.buffered(), more_marker ++ "    … 12 more lines\n"));
            } else if (case_index == 1) {
                try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), output_marker ++ "    Bash succeeded. Exit code: 0.\n" ++ output_marker ++ "    stdout tail:\n"));
                try std.testing.expectEqual(@as(usize, max_lines - 2), std.mem.count(u8, writer.buffered(), output_marker ++ "    line\n"));
                try std.testing.expect(std.mem.endsWith(u8, writer.buffered(), more_marker ++ "    … 14 more lines\n"));
            } else try std.testing.expectEqualStrings(more_marker ++ "    … 2 more lines\n", writer.buffered());
        }
    }
}
