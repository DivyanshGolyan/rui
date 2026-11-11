//! Frontend-only tool references and bounded, terminal-safe output rows.
//! Closed rows retain an identity, never their output. The existing document's
//! hidden OSC 8 address representation carries these line-level markers.
const std = @import("std");
const Text = @import("TerminalText.zig");
const result_format = @import("bash_result_format.zig");
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
pub const stderr_uri = "rui-tool-stderr";
pub const more_uri = "rui-tool-more";
pub const output_marker = Text.link_open ++ output_uri ++ Text.link_end ++ Text.link_close;
pub const stderr_marker = Text.link_open ++ stderr_uri ++ Text.link_end ++ Text.link_close;
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

/// One toggle's temporary display owner. The reader still authenticates the
/// entire immutable content. Host provenance chooses the decoder; only a
/// supported, exact-length Bash frame supplies stream boundaries. Legacy,
/// malformed and non-Bash content remains literal, never prose-parsed.
/// Two fixed buffers retain the printed prefix and one incoming/escaped line,
/// not the closed outputs or another per-byte document style array.
pub const Output = struct {
    raw: [max_bytes]u8 = undefined,
    escaped: [max_bytes]u8 = undefined,
    length: usize = 0,
    line_length: usize = 0,
    line_overflow: bool = false,
    cut: bool = false,
    lines: u64 = 0,
    mode: enum { plain, header, framed } = .plain,
    header_bytes: [result_format.max_header]u8 = undefined,
    header_length: usize = 0,
    total: u64 = 0,
    spans: result_format.Spans = @splat(0),
    span: usize = 0,
    quiet_from: ?usize = null,
    quiet_stderr: bool = false,

    pub fn begin(self: *Output, kind: result_format.Kind, total: u64) void {
        self.mode = if (kind == .bash) .header else .plain;
        self.total = total;
    }

    pub fn feed(self: *Output, bytes: []const u8) !void {
        for (bytes) |byte| {
            if (self.mode == .header) {
                if (self.header_length == self.header_bytes.len) {
                    self.mode = .plain;
                    for (self.header_bytes[0..self.header_length]) |held| self.printByte(held);
                } else {
                    self.header_bytes[self.header_length] = byte;
                    self.header_length += 1;
                    if (byte != '\n') continue;
                    if (result_format.parse(self.header_bytes[0..self.header_length], self.total)) |spans| {
                        self.spans = spans;
                        self.quiet_stderr = spans[1] != 0;
                        self.mode = .framed;
                    } else {
                        self.mode = .plain;
                        for (self.header_bytes[0..self.header_length]) |held| self.printByte(held);
                    }
                    continue;
                }
            }
            if (self.mode == .plain) {
                self.printByte(byte);
                continue;
            }
            self.advanceSpan();
            if (self.span >= self.spans.len) return error.InvalidBashFrame;
            if (self.span == 1 or self.span == 3) self.printByte(byte);
            self.spans[self.span] -= 1;
        }
    }

    fn advanceSpan(self: *Output) void {
        while (self.span < self.spans.len and self.spans[self.span] == 0) {
            if (self.span == 1) self.endLine();
            self.span += 1;
            if (self.span == 3 and self.quiet_stderr) self.quiet_from = self.length;
        }
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
        if (self.mode == .header) {
            for (self.header_bytes[0..self.header_length]) |held| self.printByte(held);
        }
        if (self.mode == .framed) {
            self.advanceSpan();
            if (self.span != self.spans.len) return error.InvalidBashFrame;
        }
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
            try sink.feed(if (self.quiet_from != null and at >= self.quiet_from.?) stderr_marker else output_marker);
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

test "tool display uses trusted framing and preserves literal stream delimiters" {
    const Sink = struct {
        writer: *std.Io.Writer,
        pub fn feed(self: @This(), bytes: []const u8) !void {
            try self.writer.writeAll(bytes);
        }
    };
    const output = try std.testing.allocator.create(Output);
    defer std.testing.allocator.destroy(output);
    const stdout = "stderr tail:\n[earlier output omitted]\nFull stdout: literal\n";
    const stderr = "RUI-BASH-RESULT/1 0 0 0 0 0\nerror";
    var head_buffer: [result_format.max_header]u8 = undefined;
    const head = try result_format.header(&head_buffer, .{ 4, stdout.len, 3, stderr.len, 4 });
    var body_buffer: [1024]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buffer, "{s}prep{s}sep{s}foot", .{ head, stdout, stderr });
    var rendered: [32768]u8 = undefined;
    for (0..body.len + 1) |split| {
        output.* = .{};
        output.begin(.bash, body.len);
        try output.feed(body[0..split]);
        try output.feed(body[split..]);
        var writer = std.Io.Writer.fixed(&rendered);
        try output.finish(Sink{ .writer = &writer });
        try std.testing.expectEqualStrings(output_marker ++ "    stderr tail:\n" ++ output_marker ++ "    [earlier output omitted]\n" ++ output_marker ++ "    Full stdout: literal\n" ++ stderr_marker ++ "    RUI-BASH-RESULT/1 0 0 0 0 0\n" ++ stderr_marker ++ "    error\n", writer.buffered());
    }
    // Even a syntactically supported frame from a different tool is literal.
    output.* = .{};
    output.begin(.plain, body.len);
    try output.feed(body);
    var writer = std.Io.Writer.fixed(&rendered);
    try output.finish(Sink{ .writer = &writer });
    var expected_buffer: [32768]u8 = undefined;
    var expected = std.Io.Writer.fixed(&expected_buffer);
    try expected.writeAll(output_marker ++ "    ");
    try expected.writeAll(head);
    try expected.writeAll(output_marker ++ "    prepstderr tail:\n" ++ output_marker ++ "    [earlier output omitted]\n" ++ output_marker ++ "    Full stdout: literal\n" ++ output_marker ++ "    sepRUI-BASH-RESULT/1 0 0 0 0 0\n" ++ output_marker ++ "    errorfoot\n");
    try std.testing.expectEqualStrings(expected.buffered(), writer.buffered());
    // Legacy and invalid envelopes are not heuristically unwrapped.
    for ([_][]const u8{ "Bash failed. Exit code: 1.\nstdout tail:\nliteral", "RUI-BASH-RESULT/1 0 9 0 0 0\nshort", "", "RUI-BASH-RESULT/2 0 0 0 0 0\n" }) |plain| {
        output.* = .{};
        output.begin(.bash, plain.len);
        for (plain) |byte| try output.feed(&.{byte});
        writer = .fixed(&rendered);
        try output.finish(Sink{ .writer = &writer });
        if (plain.len != 0) try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), plain[0 .. std.mem.indexOfScalar(u8, plain, '\n') orelse plain.len]) != null);
    }
    output.* = .{};
    try output.feed(&@as([max_bytes + 1]u8, @splat('x')));
    try output.feed("\nsecond\n");
    writer = .fixed(&rendered);
    try output.finish(Sink{ .writer = &writer });
    try std.testing.expectEqualStrings(more_marker ++ "    … 2 more lines\n", writer.buffered());
}

test "framed output keeps stream boundaries empty streams and trailing literal blanks" {
    const Sink = struct {
        writer: *std.Io.Writer,
        pub fn feed(self: @This(), bytes: []const u8) !void {
            try self.writer.writeAll(bytes);
        }
    };
    const output = try std.testing.allocator.create(Output);
    defer std.testing.allocator.destroy(output);
    const cases = [_]struct { stdout: []const u8, stderr: []const u8, expected: []const u8 }{
        .{ .stdout = "", .stderr = "", .expected = output_marker ++ "    \n" },
        .{ .stdout = "out", .stderr = "err", .expected = output_marker ++ "    out\n" ++ stderr_marker ++ "    err\n" },
        .{ .stdout = "", .stderr = "err\n", .expected = output_marker ++ "    err\n" },
        .{ .stdout = "out\n\n", .stderr = "\n", .expected = output_marker ++ "    out\n" ++ output_marker ++ "    \n" ++ stderr_marker ++ "    \n" },
        .{ .stdout = "\x1b[2J", .stderr = "", .expected = output_marker ++ "    \\x1b[2J\n" },
    };
    var header_buffer: [result_format.max_header]u8 = undefined;
    var body_buffer: [4096]u8 = undefined;
    var rendered: [32768]u8 = undefined;
    for (cases) |case| {
        const preamble = @as([1024]u8, @splat('x'));
        const head = try result_format.header(&header_buffer, .{ preamble.len, case.stdout.len, 3, case.stderr.len, 4 });
        const body = try std.fmt.bufPrint(&body_buffer, "{s}{s}{s}sep{s}foot", .{ head, preamble, case.stdout, case.stderr });
        for ([_]usize{ 1, 2, 7, 128, 4096 }) |chunk| {
            output.* = .{};
            output.begin(.bash, body.len);
            var at: usize = 0;
            while (at < body.len) {
                const end = @min(at + chunk, body.len);
                try output.feed(body[at..end]);
                at = end;
            }
            var writer = std.Io.Writer.fixed(&rendered);
            try output.finish(Sink{ .writer = &writer });
            try std.testing.expectEqualStrings(case.expected, writer.buffered());
        }
    }
}

test "tool display bounds raw escaped and line prefixes independently of framed preambles" {
    const Sink = struct {
        writer: *std.Io.Writer,
        pub fn feed(self: @This(), bytes: []const u8) !void {
            try self.writer.writeAll(bytes);
        }
    };
    const output = try std.testing.allocator.create(Output);
    defer std.testing.allocator.destroy(output);
    const lines: [32 * 5]u8 = @bitCast(@as([32][5]u8, @splat("line\n".*)));
    const long = @as([max_bytes + 1]u8, @splat('x')) ++ "\nsecond\n";
    const escaped = @as([3000]u8, @splat(0x1b)) ++ "\nsecond\n";
    const preamble = @as([max_bytes + 1]u8, @splat('p'));
    var head_buffer: [result_format.max_header]u8 = undefined;
    var rendered: [32768]u8 = undefined;
    for ([_]result_format.Kind{ .plain, .bash }) |kind| {
        for ([_][]const u8{ &lines, long, escaped }, 0..) |bytes, case_index| {
            output.* = .{};
            const head = try result_format.header(&head_buffer, .{ preamble.len, bytes.len, 0, 0, 0 });
            output.begin(kind, bytes.len + if (kind == .bash) head.len + preamble.len else @as(usize, 0));
            if (kind == .bash) {
                try output.feed(head);
                try output.feed(&preamble);
            }
            // Exercise later read windows after each independent budget is hit.
            var at: usize = 0;
            while (at < bytes.len) {
                const end = @min(at + 257, bytes.len);
                try output.feed(bytes[at..end]);
                at = end;
            }
            var writer = std.Io.Writer.fixed(&rendered);
            try output.finish(Sink{ .writer = &writer });
            if (case_index == 0) {
                try std.testing.expectEqual(@as(usize, max_lines), std.mem.count(u8, writer.buffered(), output_marker ++ "    line\n"));
                try std.testing.expect(std.mem.endsWith(u8, writer.buffered(), more_marker ++ "    … 12 more lines\n"));
            } else try std.testing.expectEqualStrings(more_marker ++ "    … 2 more lines\n", writer.buffered());
        }
    }
}
