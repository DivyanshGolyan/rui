//! Frontend-only tool references and bounded, terminal-safe output rows.
//! Closed rows retain an identity, never their output. The existing document's
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
/// entire immutable content. Bash stores a model-facing envelope (bash.zig's
/// formatResult); only this display read removes its status, stream labels,
/// warnings and export pointers. Other Tool Results remain literal.
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
    phase: enum { first, plain, preamble, stdout, stderr, tail } = .first,
    pending_blank: bool = false,
    footer: enum { none, marker, blank } = .none,
    quiet_from: ?usize = null,

    pub fn feed(self: *Output, bytes: []const u8) !void {
        for (bytes) |byte| {
            if (byte == '\n') {
                self.line(true);
                self.line_length = 0;
                self.line_overflow = false;
            } else if (self.line_length < self.escaped.len) {
                self.escaped[self.line_length] = byte;
                self.line_length += 1;
            } else self.line_overflow = true;
        }
    }

    fn bashHeader(bytes: []const u8) bool {
        if (!std.mem.startsWith(u8, bytes, "Bash ")) return false;
        const end = std.mem.indexOf(u8, bytes, ". ") orelse return false;
        _ = std.meta.stringToEnum(protocol.ToolPresentation.Code, bytes[5..end]) orelse return false;
        const status = bytes[end + 2 ..];
        inline for (.{ "Exit code: ", "Signal: ", "Unknown process status: " }) |prefix_| {
            if (std.mem.startsWith(u8, status, prefix_) and std.mem.endsWith(u8, status, ".")) {
                const digits = status[prefix_.len .. status.len - 1];
                if (digits.len == 0) return false;
                for (digits) |byte| if (!std.ascii.isDigit(byte)) return false;
                return true;
            }
        }
        return false;
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

    fn flushBlank(self: *Output) void {
        if (self.pending_blank) self.keep("", true);
        self.pending_blank = false;
    }

    fn line(self: *Output, terminated: bool) void {
        const bytes = self.escaped[0..self.line_length];
        if (self.phase == .first) self.phase = if (terminated and !self.line_overflow and bashHeader(bytes)) .preamble else .plain;
        if (self.phase == .plain) return self.keep(bytes, !self.line_overflow);
        if (self.phase == .tail) return;
        if (self.phase == .preamble) {
            if (std.mem.eql(u8, bytes, "stdout tail:")) self.phase = .stdout;
            if (std.mem.eql(u8, bytes, "stderr tail:")) self.phase = .stderr;
            return;
        }
        if (self.footer != .none) {
            if (self.footer == .marker and bytes.len == 0) {
                self.footer = .blank;
                return;
            }
            if (self.footer == .blank and (std.mem.startsWith(u8, bytes, "Full stdout: ") or
                std.mem.startsWith(u8, bytes, "Full stderr: ") or
                std.mem.eql(u8, bytes, "Full output was not retained.")))
            {
                self.pending_blank = false;
                self.footer = .none;
                self.phase = .tail;
                return;
            }
            self.restoreFooter();
        }
        if (self.phase == .stdout and std.mem.eql(u8, bytes, "stderr tail:")) {
            // formatResult inserts a newline before stderr, whether stdout
            // already ended in one or not. It is not a printed blank row.
            self.pending_blank = false;
            self.quiet_from = self.length;
            self.phase = .stderr;
            return;
        }
        if (std.mem.eql(u8, bytes, "[earlier output omitted]")) {
            self.footer = .marker;
            return;
        }
        self.flushBlank();
        if (bytes.len == 0) self.pending_blank = true else self.keep(bytes, !self.line_overflow);
    }

    fn restoreFooter(self: *Output) void {
        if (self.footer == .none) return;
        self.flushBlank();
        self.keep("[earlier output omitted]", true);
        self.pending_blank = self.footer == .blank;
        self.footer = .none;
    }

    pub fn finish(self: *Output, sink: anytype) !void {
        if (self.line_length != 0 or self.line_overflow) self.line(false);
        self.restoreFooter();
        self.flushBlank();
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

test "tool display unwraps Bash envelopes, preserves printed bytes and counts only output" {
    const Sink = struct {
        writer: *std.Io.Writer,
        pub fn feed(self: @This(), bytes: []const u8) !void {
            try self.writer.writeAll(bytes);
        }
    };
    const out = output_marker ++ "    ";
    const err = stderr_marker ++ "    ";
    const cases = .{
        .{ "", out ++ "\n" },
        .{ "Bash succeeded. Exit code: 0.\n", out ++ "\n" },
        .{ "Bash failed. Exit code: 1.\nstderr tail:\nusage: example\nunknown option --help\n", out ++ "usage: example\n" ++ out ++ "unknown option --help\n" },
        .{ "Bash succeeded. Exit code: 0.\nstdout tail:\nREADME.md\nsrc\n", out ++ "README.md\n" ++ out ++ "src\n" },
        .{ "Bash failed. Exit code: 7.\nstdout tail:\nout\nstderr tail:\nerr", out ++ "out\n" ++ err ++ "err\n" },
        .{ "Bash failed. Exit code: 7.\nstdout tail:\nout\n\nstderr tail:\nerr\n", out ++ "out\n" ++ err ++ "err\n" },
        .{ "Bash failed. Exit code: 7.\nstdout tail:\nout\n\n\nstderr tail:\nerr\n", out ++ "out\n" ++ out ++ "\n" ++ err ++ "err\n" },
        .{ "Bash timed_out. Signal: 15.\nExecution timed out after a budget.\nCapture may be incomplete.\nProcess-group signaling reported a failure.\nstdout tail:\nprinted\n\n[earlier output omitted]\n\nFull stdout: /tmp/capture\n", out ++ "printed\n" },
        .{ "Bash failed. Unknown process status: 42.\nCapture failure: read; output may be incomplete.\nstderr tail:\nbad\n[earlier output omitted]\n\nFull output was not retained.\n", out ++ "bad\n" },
        .{ "Bash succeeded. Exit code: 0.\nstdout tail:\nstdout tail:\n[earlier output omitted]\nnot a capture pointer\n", out ++ "stdout tail:\n" ++ out ++ "[earlier output omitted]\n" ++ out ++ "not a capture pointer\n" },
        .{ "Bash succeeded. Exit code: 0.\nstdout tail:\n[earlier output omitted]\n\n", out ++ "[earlier output omitted]\n" ++ out ++ "\n" },
        .{ "Bash failed. Exit code: nope.\nstderr tail:\nprinted", out ++ "Bash failed. Exit code: nope.\n" ++ out ++ "stderr tail:\n" ++ out ++ "printed\n" },
        .{ "stderr tail:\nBash failed. Exit code: 1.\n", out ++ "stderr tail:\n" ++ out ++ "Bash failed. Exit code: 1.\n" },
        .{ "Bash failed. Exit code: 1.\nstderr tail:\n\x1b[2J\n", out ++ "\\x1b[2J\n" },
    };
    const output = try std.testing.allocator.create(Output);
    defer std.testing.allocator.destroy(output);
    var buffer: [32 * 1024]u8 = undefined;
    inline for (cases) |case| {
        for ([_]usize{ 1, 2, 7, max_bytes }) |chunk| {
            output.* = .{};
            var at: usize = 0;
            while (at < case[0].len) {
                const end = @min(at + chunk, case[0].len);
                try output.feed(case[0][at..end]);
                at = end;
            }
            var writer = std.Io.Writer.fixed(&buffer);
            try output.finish(Sink{ .writer = &writer });
            try std.testing.expectEqualStrings(case[1], writer.buffered());
        }
    }
    output.* = .{};
    try output.feed("Bash succeeded. Exit code: 0.\nstdout tail:\n");
    for (0..32) |_| try output.feed("line\n");
    var writer = std.Io.Writer.fixed(&buffer);
    try output.finish(Sink{ .writer = &writer });
    try std.testing.expectEqual(@as(usize, max_lines), std.mem.count(u8, writer.buffered(), out ++ "line\n"));
    try std.testing.expect(std.mem.endsWith(u8, writer.buffered(), more_marker ++ "    … 12 more lines\n"));
    // Even a long ignored envelope line does not consume the output budget.
    output.* = .{};
    try output.feed("Bash failed. Exit code: 1.\nCapture failure: ");
    try output.feed(&@as([max_bytes + 1]u8, @splat('x')));
    try output.feed("\nstderr tail:\nprinted\n");
    writer = .fixed(&buffer);
    try output.finish(Sink{ .writer = &writer });
    try std.testing.expectEqualStrings(out ++ "printed\n", writer.buffered());
    // The raw and escaped byte bounds still count a cut logical line once.
    output.* = .{};
    try output.feed(&@as([max_bytes + 1]u8, @splat('x')));
    try output.feed("\nsecond\n");
    writer = .fixed(&buffer);
    try output.finish(Sink{ .writer = &writer });
    try std.testing.expectEqualStrings(more_marker ++ "    … 2 more lines\n", writer.buffered());
    output.* = .{};
    try output.feed("Bash succeeded. Exit code: 0.\nstdout tail:\n");
    try output.feed(&@as([3000]u8, @splat(0x1b)));
    try output.feed("\nsecond\n");
    writer = .fixed(&buffer);
    try output.finish(Sink{ .writer = &writer });
    try std.testing.expectEqualStrings(more_marker ++ "    … 2 more lines\n", writer.buffered());
}
