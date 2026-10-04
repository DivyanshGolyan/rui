const std = @import("std");
const TerminalText = @import("TerminalText.zig");
const Renderer = @This();

// A complete bounded fenced block may hide its delimiters. Unclosed or
// oversized blocks fall back to literal output without buffering an answer.
const prefix_limit = 128;
const span_limit = 256;
const fence_limit = 4096;
const Style = packed struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
};
const InlineKind = enum { none, emphasis, strong, code };
const InlineRetention = enum { candidate, literal };

out: *std.Io.Writer,
prefix: [prefix_limit]u8 = undefined,
prefix_len: usize = 0,
span: [span_limit]u8 = undefined,
span_len: usize = 0,
inline_count: u3 = 0,
// These bounded annotations are produced by the same bytewise recognizer that
// finds the outer closer. Formatting consumes them; it does not parse again.
code_bytes: [span_limit / 8]u8 = [_]u8{0} ** (span_limit / 8),
syntax_bytes: [span_limit / 8]u8 = [_]u8{0} ** (span_limit / 8),
inline_kind: InlineKind = .none,
inline_retention: InlineRetention = .candidate,
code_open: bool = false,
code_has_content: bool = false,
code_closer: bool = false,
code_opener: usize = 0,
star_run: u2 = 0,
escape_next: bool = false,
literal_run: ?u8 = null,
fence_pending: bool = false,
fence_literal: bool = false,
fence_bytes: [fence_limit]u8 = undefined,
fence_len: usize = 0,
fence_body_start: usize = 0,
fence_line_start: usize = 0,
fence_closer_possible: bool = true,
fence_closer_indent: u2 = 0,
fence_closer_ticks: u2 = 0,
line_style: bool = false,
active_style: Style = .{},
line_start: bool = true,
literal_line: bool = false,
terminal_text: TerminalText = .{ .mode = .multiline },

pub fn feed(self: *Renderer, bytes: []const u8) !void {
    for (bytes) |byte| {
        if (self.fence_pending and self.fence_body_start != 0) {
            try self.fencedByte(byte);
            continue;
        }
        if (self.line_start) {
            if (byte != '\n' and self.prefix_len < prefix_limit) {
                self.prefix[self.prefix_len] = byte;
                self.prefix_len += 1;
                // The longest accepted ordered marker needs three spaces,
                // five digits, a dot and its following space.
                if (self.prefix_len < 10 or (self.prefix_len < prefix_limit and fenceCandidate(self.prefix[0..self.prefix_len]))) continue;
                if (self.prefix_len == prefix_limit and fenceCandidate(self.prefix[0..self.prefix_len])) self.literal_line = true;
                try self.flushPrefix();
                continue;
            }
            try self.flushPrefix();
        }
        if (byte == '\n') {
            try self.flushSpan();
            self.escape_next = false;
            self.literal_run = null;
            if (self.line_style) try self.transition(.{});
            self.line_style = false;
            if (self.fence_pending) {
                self.fence_bytes[self.fence_len] = byte;
                self.fence_len += 1;
                self.fence_body_start = self.fence_len;
                self.fence_line_start = self.fence_len;
            } else try self.safe(byte);
            self.literal_line = false;
            self.line_start = true;
            continue;
        }
        try self.prose(byte);
    }
}

pub fn finish(self: *Renderer) !void {
    if (self.line_start and self.prefix_len != 0) {
        // A delimiter without its line ending is not a complete block marker.
        if (fenceCandidate(self.prefix[0..self.prefix_len])) self.literal_line = true;
        try self.flushPrefix();
    }
    if (self.fence_pending and !self.fence_literal) {
        if (closingFence(self.fence_bytes[self.fence_line_start..self.fence_len])) {
            try self.literalBlock(self.fence_bytes[self.fence_body_start..self.fence_line_start]);
        } else try self.literalBlock(self.fence_bytes[0..self.fence_len]);
    }
    try self.flushSpan();
    if (self.line_style) try self.transition(.{});
    try self.terminal_text.finish(self.out);
}

fn flushPrefix(self: *Renderer) !void {
    if (!self.line_start) return;
    self.line_start = false;
    const prefix = self.prefix[0..self.prefix_len];
    self.prefix_len = 0;
    var fence_indent: usize = 0;
    while (fence_indent < prefix.len and fence_indent < 3 and prefix[fence_indent] == ' ') : (fence_indent += 1) {}
    if (std.mem.startsWith(u8, prefix[fence_indent..], "```")) {
        if (!self.literal_line and fenceInfo(prefix[fence_indent + 3 ..])) {
            @memcpy(self.fence_bytes[0..prefix.len], prefix);
            self.fence_len = prefix.len;
            self.fence_pending = true;
            return;
        }
        self.literal_line = true;
    }
    if (self.literal_line) return self.safeSlice(prefix);
    var hashes: usize = 0;
    while (hashes < prefix.len and hashes < 6 and prefix[hashes] == '#') : (hashes += 1) {}
    if (hashes != 0 and hashes < prefix.len and prefix[hashes] == ' ') {
        try self.transition(.{ .bold = true });
        self.line_style = true;
        try self.proseSlice(prefix[hashes + 1 ..]);
        return;
    }
    var indent: usize = 0;
    while (indent < prefix.len and indent < 3 and prefix[indent] == ' ') : (indent += 1) {}
    var end = indent;
    if (end < prefix.len and std.mem.indexOfScalar(u8, "-*+", prefix[end]) != null) {
        end += 1;
    } else {
        while (end < prefix.len and end - indent < 5 and std.ascii.isDigit(prefix[end])) : (end += 1) {}
        if (end == indent or end >= prefix.len or prefix[end] != '.') end = indent else end += 1;
    }
    if (end > indent and end < prefix.len and prefix[end] == ' ') {
        try self.safeSlice(prefix[0..indent]);
        try self.transition(.{ .bold = true });
        try self.safeSlice(prefix[indent..end]);
        try self.transition(.{});
        try self.safeSlice(prefix[end .. end + 1]);
        try self.proseSlice(prefix[end + 1 ..]);
        return;
    }
    // Unsupported block syntax has no special interpretation.
    try self.proseSlice(prefix);
}

fn fenceCandidate(prefix: []const u8) bool {
    var indent: usize = 0;
    while (indent < prefix.len and indent < 3 and prefix[indent] == ' ') : (indent += 1) {}
    return std.mem.startsWith(u8, prefix[indent..], "```");
}

fn fenceInfo(info: []const u8) bool {
    for (info) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '+') return false;
    }
    return true;
}

fn closingFence(line: []const u8) bool {
    var indent: usize = 0;
    while (indent < line.len and indent < 3 and line[indent] == ' ') : (indent += 1) {}
    return std.mem.eql(u8, line[indent..], "```");
}

fn fencedByte(self: *Renderer, byte: u8) !void {
    if (!self.fence_literal and self.fence_len == fence_limit) {
        // We cannot promise that a closing fence exists. Emit all retained
        // syntax and keep subsequent bytes literal until this block ends.
        try self.literalBlock(self.fence_bytes[0..self.fence_len]);
        self.fence_literal = true;
        self.fence_closer_possible = true;
        self.fence_closer_indent = 0;
        self.fence_closer_ticks = 0;
        for (self.fence_bytes[self.fence_line_start..self.fence_len]) |line_byte| self.fenceCloserByte(line_byte);
        self.fence_len = 0;
    }
    if (self.fence_literal) {
        try self.literalBlock(&.{byte});
        if (byte == '\n') {
            if (self.fence_closer_possible and self.fence_closer_ticks == 3) {
                self.fence_pending = false;
                self.fence_literal = false;
                self.fence_body_start = 0;
            }
            self.fence_closer_possible = true;
            self.fence_closer_indent = 0;
            self.fence_closer_ticks = 0;
        } else self.fenceCloserByte(byte);
        return;
    }
    self.fence_bytes[self.fence_len] = byte;
    self.fence_len += 1;
    if (byte == '\n') {
        if (closingFence(self.fence_bytes[self.fence_line_start .. self.fence_len - 1])) {
            try self.literalBlock(self.fence_bytes[self.fence_body_start..self.fence_line_start]);
            self.fence_pending = false;
            self.fence_len = 0;
            self.fence_body_start = 0;
        } else self.fence_line_start = self.fence_len;
    }
}

fn fenceCloserByte(self: *Renderer, byte: u8) void {
    if (!self.fence_closer_possible) return;
    if (self.fence_closer_ticks == 0 and self.fence_closer_indent < 3 and byte == ' ') {
        self.fence_closer_indent += 1;
    } else if (byte == '`' and self.fence_closer_ticks < 3) {
        self.fence_closer_ticks += 1;
    } else self.fence_closer_possible = false;
}

fn literalBlock(self: *Renderer, bytes: []const u8) !void {
    for (bytes) |byte| {
        try self.safe(byte);
        self.line_start = byte == '\n';
    }
}

fn proseSlice(self: *Renderer, bytes: []const u8) !void {
    for (bytes) |byte| try self.prose(byte);
}

fn prose(self: *Renderer, byte: u8) !void {
    if (self.literal_line) return self.safe(byte);
    if (self.code_closer and byte != '`') try self.renderInline();
    if (self.star_run != 0 and byte != '*') {
        // Lookahead belongs to the following recognizer, not the closer.
        if (self.star_run == self.starWidth()) try self.renderInline() else self.star_run = 0;
    }
    if (self.literal_run) |marker| {
        if (byte == marker) return self.safe(byte);
        self.literal_run = null;
    }
    if (self.inline_kind == .none and self.escape_next) {
        self.escape_next = false;
        return self.safe(byte);
    }
    if (self.inline_kind == .none and byte == '\\') {
        self.escape_next = true;
        return self.safe(byte);
    }
    if (self.inline_kind == .none) {
        if (byte == '*' or byte == '`') {
            self.inline_kind = if (byte == '*') .emphasis else .code;
            self.inline_retention = .candidate;
            self.span_len = 0;
            self.inline_count = 0;
            try self.retainInline(byte);
        } else try self.safe(byte);
        return;
    }
    try self.inlineByte(byte);
}

fn inlineByte(self: *Renderer, byte: u8) !void {
    // Outer delimiters wait for the complete tick run. Nested ticks retain their
    // context-sensitive empty-pair and close/reopen behavior below.
    if (self.inline_kind == .code and (self.inline_count == 1 or self.code_closer) and byte == '`') {
        try self.flushLiteralSpan();
        self.literal_run = '`';
        return self.safe(byte);
    }
    // Only outer emphasis/strong syntax uses escapes; all code backslashes
    // are content, including those immediately before a closing tick.
    const syntax_escapes = (self.inline_kind == .emphasis or self.inline_kind == .strong) and !self.code_open;
    const escaped = syntax_escapes and self.escape_next;
    self.escape_next = false;
    if (!escaped and syntax_escapes and byte == '\\') self.escape_next = true;
    if (escaped) self.star_run = 0;

    // The second initial star upgrades emphasis to strong. A third initial
    // star makes the whole unsupported run literal.
    if (self.inline_retention == .candidate and self.inline_kind == .emphasis and self.inline_count == 1 and byte == '*') {
        try self.retainInline(byte);
        self.inline_kind = .strong;
        return;
    }
    if (self.inline_retention == .candidate and self.inline_kind == .strong and self.inline_count == 2 and byte == '*') {
        try self.flushSpan();
        self.literal_run = '*';
        return self.safe(byte);
    }

    if (!escaped) switch (self.inline_kind) {
        .none => unreachable,
        .code => self.code_closer = byte == '`' and self.inline_count > 1,
        .emphasis, .strong => {
            if (byte == '`') {
                if (!self.code_open) {
                    self.code_open = true;
                    self.code_has_content = false;
                    self.code_opener = self.span_len;
                } else if (self.code_has_content) {
                    self.code_open = false;
                } else {
                    // Empty nested code is literal, including both ticks.
                    if (self.inline_retention == .candidate) setBit(&self.syntax_bytes, self.code_opener, false);
                    self.code_open = false;
                }
            } else if (self.code_open) {
                self.code_has_content = true;
            } else if (byte == '*') {
                // Delay a supported closer until the complete run is known.
                // A lone star inside strong remains ordinary retained content.
                if (self.star_run < 3) self.star_run += 1;
                if (self.star_run > self.starWidth()) {
                    try self.flushLiteralSpan();
                    self.literal_run = '*';
                    return self.safe(byte);
                }
            }
        },
    };

    const index = self.span_len;
    try self.retainInline(byte);
    if (self.inline_retention == .candidate and (self.inline_kind == .emphasis or self.inline_kind == .strong)) {
        if (!escaped and byte == '`') {
            setBit(&self.syntax_bytes, index, self.code_open or self.code_has_content);
        } else if (self.code_open) setBit(&self.code_bytes, index, true);
    }
}

fn retainInline(self: *Renderer, byte: u8) !void {
    // Only opener and closer thresholds need the count; an unfinished literal
    // candidate can span an arbitrarily long answer.
    if (self.inline_count < 4) self.inline_count += 1;
    if (self.inline_retention == .literal) {
        try self.safe(byte);
        return;
    }
    if (self.span_len == span_limit) {
        try self.safeSlice(self.span[0..self.span_len]);
        self.span_len = 0;
        self.inline_retention = .literal;
        try self.safe(byte);
        return;
    }
    self.span[self.span_len] = byte;
    self.span_len += 1;
}

fn renderInline(self: *Renderer) !void {
    if (self.inline_retention == .literal) return self.resetInline();
    const marker_len: usize = if (self.inline_kind == .strong) 2 else 1;
    const parent: Style = .{ .bold = self.line_style };
    const outer: Style = if (self.inline_kind == .code)
        .{ .bold = parent.bold, .underline = true }
    else
        .{ .bold = parent.bold or self.inline_kind == .strong, .italic = self.inline_kind == .emphasis };
    try self.transition(outer);
    var i = marker_len;
    const end = self.span_len - marker_len;
    while (i < end) : (i += 1) {
        if (bit(&self.syntax_bytes, i)) {
            try self.transition(outer);
            continue;
        }
        const style: Style = .{ .bold = outer.bold, .italic = outer.italic, .underline = outer.underline or bit(&self.code_bytes, i) };
        try self.transition(style);
        try self.safe(self.span[i]);
    }
    try self.transition(parent);
    self.resetInline();
}

fn transition(self: *Renderer, next: Style) !void {
    if (std.meta.eql(self.active_style, next)) return;
    try self.terminal_text.finish(self.out);
    if (!std.meta.eql(self.active_style, Style{})) try self.out.writeAll("\x1b[0m");
    if (next.bold) try self.out.writeAll("\x1b[1m");
    if (next.italic) try self.out.writeAll("\x1b[3m");
    if (next.underline) try self.out.writeAll("\x1b[4m");
    self.active_style = next;
}

fn bit(bits: *const [span_limit / 8]u8, index: usize) bool {
    return bits[index / 8] & (@as(u8, 1) << @intCast(index % 8)) != 0;
}

fn setBit(bits: *[span_limit / 8]u8, index: usize, value: bool) void {
    const mask = @as(u8, 1) << @intCast(index % 8);
    if (value) bits[index / 8] |= mask else bits[index / 8] &= ~mask;
}

fn resetInline(self: *Renderer) void {
    self.span_len = 0;
    self.inline_count = 0;
    self.inline_kind = .none;
    self.inline_retention = .candidate;
    self.code_open = false;
    self.code_has_content = false;
    self.code_closer = false;
    self.star_run = 0;
    self.escape_next = false;
    @memset(&self.code_bytes, 0);
    @memset(&self.syntax_bytes, 0);
}

fn flushSpan(self: *Renderer) !void {
    if (self.code_closer) return self.renderInline();
    if (self.star_run != 0 and self.star_run == self.starWidth()) return self.renderInline();
    try self.flushLiteralSpan();
}

fn starWidth(self: *const Renderer) u2 {
    return if (self.inline_kind == .strong) 2 else 1;
}

fn flushLiteralSpan(self: *Renderer) !void {
    try self.safeSlice(self.span[0..self.span_len]);
    self.resetInline();
}

fn safeSlice(self: *Renderer, bytes: []const u8) !void {
    for (bytes) |byte| try self.safe(byte);
}

// Escape controls at the final output boundary, including sequences split
// across read windows. Stored answer bytes are never rewritten.
fn safe(self: *Renderer, byte: u8) !void {
    try self.terminal_text.feed(self.out, &.{byte});
}

test "outer code closer owns its complete run at retained and streaming bounds" {
    inline for (.{ 5, 254, 255 }) |payload| {
        inline for (.{ 1, 2, 17 }) |ticks| {
            inline for (.{ "", "\n", " then `ok`", "\n`ok`" }) |tail| {
                var input: [1 + payload + ticks + tail.len]u8 = undefined;
                input[0] = '`';
                @memset(input[1..][0..payload], 'x');
                @memset(input[1 + payload ..][0..ticks], '`');
                @memcpy(input[1 + payload + ticks ..], tail);
                var expected = std.Io.Writer.Allocating.init(std.testing.allocator);
                defer expected.deinit();
                const styled = payload == 254 or payload == 5;
                if (styled and ticks == 1) {
                    try expected.writer.writeAll("\x1b[4m");
                    try expected.writer.writeAll(input[1..][0..payload]);
                    try expected.writer.writeAll("\x1b[0m");
                } else try expected.writer.writeAll(input[0 .. 1 + payload + ticks]);
                if (comptime std.mem.endsWith(u8, tail, "`ok`")) {
                    try expected.writer.writeAll(tail[0 .. tail.len - 4]);
                    try expected.writer.writeAll("\x1b[4mok\x1b[0m");
                } else try expected.writer.writeAll(tail);
                for (0..input.len + 1) |split| {
                    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
                    defer output.deinit();
                    var renderer: Renderer = .{ .out = &output.writer };
                    try renderer.feed(input[0..split]);
                    for (input[split..]) |byte| try renderer.feed(&.{byte});
                    try renderer.finish();
                    try std.testing.expectEqualStrings(expected.written(), output.written());
                    try std.testing.expect(@sizeOf(Renderer) < 5 * 1024);
                }
            }
        }
    }
}

test "streaming literal outer code owns double closer before independent code" {
    const suffix = "`` then `ok`";
    var input: [1 + 255 + suffix.len]u8 = undefined;
    input[0] = '`';
    @memset(input[1..256], 'x');
    @memcpy(input[256..], suffix);
    const rendered_suffix = "`` then \x1b[4mok\x1b[0m";
    var expected: [256 + rendered_suffix.len]u8 = undefined;
    @memcpy(expected[0..256], input[0..256]);
    @memcpy(expected[256..], rendered_suffix);
    for (0..input.len + 1) |split| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var renderer: Renderer = .{ .out = &output.writer };
        try renderer.feed(input[0..split]);
        try renderer.feed(input[split..]);
        try renderer.finish();
        try std.testing.expectEqualStrings(&expected, output.written());
    }
}

test "single opener with double closer recovers before independent code" {
    const input = "`value`` then `ok`";
    for (0..input.len + 1) |split| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var renderer: Renderer = .{ .out = &output.writer };
        try renderer.feed(input[0..split]);
        try renderer.feed(input[split..]);
        try renderer.finish();
        try std.testing.expectEqualStrings("`value`` then \x1b[4mok\x1b[0m", output.written());
    }
}

test "multi-tick opener recovers locally before independent code" {
    const input = "``value`` then `ok`";
    for (0..input.len + 1) |split| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var renderer: Renderer = .{ .out = &output.writer };
        try renderer.feed(input[0..split]);
        for (input[split..]) |byte| try renderer.feed(&.{byte});
        try renderer.finish();
        try std.testing.expectEqualStrings("``value`` then \x1b[4mok\x1b[0m", output.written());
    }
}

test "overwide star closers stay literal before independent supported spans" {
    inline for (.{
        .{ "**value*** then **ok**", "**value*** then \x1b[1mok\x1b[0m" },
        .{ "*value** then *ok*", "*value** then \x1b[3mok\x1b[0m" },
    }) |case| {
        for (0..case[0].len + 1) |split| {
            var output = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer output.deinit();
            var renderer: Renderer = .{ .out = &output.writer };
            try renderer.feed(case[0][0..split]);
            for (case[0][split..]) |byte| try renderer.feed(&.{byte});
            try renderer.finish();
            try std.testing.expectEqualStrings(case[1], output.written());
        }
    }
}

test "provisional closers finalize at boundaries and leave lookahead to prose" {
    inline for (.{
        .{ "*v*", "\x1b[3mv\x1b[0m" },
        .{ "**v**\n", "\x1b[1mv\x1b[0m\n" },
        .{ "*v**", "*v**" },
        .{ "**v***\n", "**v***\n" },
        .{ "**a*b**", "\x1b[1ma*b\x1b[0m" },
        .{ "*v*`ok`", "\x1b[3mv\x1b[0m\x1b[4mok\x1b[0m" },
        .{ "**v**\\*literal*", "\x1b[1mv\x1b[0m\\*literal*" },
        .{ "**v**\x1b\xe2\x82", "\x1b[1mv\x1b[0m\\x1b\\xe2\\x82" },
        .{ "# **v*** then **ok**\n", "\x1b[1m**v*** then ok\x1b[0m\n" },
        .{ "``\n`ok`", "``\n\x1b[4mok\x1b[0m" },
        .{ "``*ok*", "``\x1b[3mok\x1b[0m" },
        .{ "**a ``**", "\x1b[1ma ``\x1b[0m" },
        .{ "**`a``b`**", "\x1b[1m\x1b[0m\x1b[1m\x1b[4ma\x1b[0m\x1b[1m\x1b[0m\x1b[1m\x1b[4mb\x1b[0m\x1b[1m\x1b[0m" },
        .{ "**`a```**", "\x1b[1m\x1b[0m\x1b[1m\x1b[4ma\x1b[0m\x1b[1m``\x1b[0m" },
        .{ "**a\\***", "\x1b[1ma\\*\x1b[0m" },
    }) |case| {
        for (0..case[0].len + 1) |split| {
            var output = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer output.deinit();
            var renderer: Renderer = .{ .out = &output.writer };
            try renderer.feed(case[0][0..split]);
            for (case[0][split..]) |byte| try renderer.feed(&.{byte});
            try renderer.finish();
            try std.testing.expectEqualStrings(case[1], output.written());
        }
    }
}

test "provisional closer at exact and overflowing bounds owns all run bytes" {
    inline for (.{ "*", "**" }) |marker| {
        inline for (.{ 0, 1 }) |overflow| {
            inline for (.{ 0, 1 }) |extra_star| {
                const payload = span_limit - 2 * marker.len + overflow;
                const tail = marker ++ (if (extra_star == 1) "*" else "") ++ " then `ok`";
                var input: [marker.len + payload + tail.len]u8 = undefined;
                @memcpy(input[0..marker.len], marker);
                @memset(input[marker.len..][0..payload], 'a');
                @memcpy(input[marker.len + payload ..], tail);
                var expected = std.Io.Writer.Allocating.init(std.testing.allocator);
                defer expected.deinit();
                const fits = overflow == 0 and extra_star == 0;
                try expected.writer.writeAll(if (fits) (if (marker.len == 1) "\x1b[3m" else "\x1b[1m") else marker);
                for (0..payload) |_| try expected.writer.writeByte('a');
                try expected.writer.writeAll(if (fits) "\x1b[0m" else marker ++ (if (extra_star == 1) "*" else ""));
                try expected.writer.writeAll(" then \x1b[4mok\x1b[0m");
                for (0..input.len + 1) |split| {
                    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
                    defer output.deinit();
                    var renderer: Renderer = .{ .out = &output.writer };
                    try renderer.feed(input[0..split]);
                    for (input[split..]) |byte| try renderer.feed(&.{byte});
                    try renderer.finish();
                    try std.testing.expectEqualStrings(expected.written(), output.written());
                }
            }
        }
    }
}

test "long unsupported delimiter runs stream literally and recover locally" {
    inline for (.{ '*', '`' }) |marker| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var renderer: Renderer = .{ .out = &output.writer };
        // Keep the tick run away from the independent line-prefix fence owner.
        try renderer.feed("text ");
        for (0..100_000) |_| try renderer.feed(&.{marker});
        try renderer.feed(" then **ok**");
        try renderer.finish();
        try std.testing.expectEqualStrings("text ", output.written()[0..5]);
        for (output.written()[5..100_005]) |byte| try std.testing.expectEqual(marker, byte);
        try std.testing.expectEqualStrings(" then \x1b[1mok\x1b[0m", output.written()[100_005..]);
        try std.testing.expect(@sizeOf(Renderer) < 5 * 1024);
    }
}

test "chunked subset, malformed markup and terminal controls" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    const input = "# Heading\n- *item* and `code`\n**bold**\n```zig\n  x\t= 1\n```\nunfinished *mark\n\\*literal*\n" ++
        "bad \x1b]2;title\x07 \r \x7f \xe2\x80\xae café\n";
    for (input) |byte| try renderer.feed(&.{byte});
    try renderer.finish();
    try std.testing.expectEqualStrings("\x1b[1mHeading\x1b[0m\n\x1b[1m-\x1b[0m \x1b[3mitem\x1b[0m and \x1b[4mcode\x1b[0m\n" ++
        "\x1b[1mbold\x1b[0m\n  x\t= 1\nunfinished *mark\n\\*literal*\n" ++
        "bad \\x1b]2;title\\x07 \\x0d \\x7f \\u202e café\n", output.written());
}

test "ordered markers retain complete bounded prefix across one-byte feeds" {
    for (0..4) |indent| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var renderer: Renderer = .{ .out = &output.writer };
        for (0..indent) |_| try renderer.feed(" ");
        for ("12345. item\n") |byte| try renderer.feed(&.{byte});
        try renderer.finish();
        var expected: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&expected, "{s}\x1b[1m12345.\x1b[0m item\n", .{("   ")[0..indent]});
        try std.testing.expectEqualStrings(line, output.written());
    }
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    for ("   123456. item\n") |byte| try renderer.feed(&.{byte});
    try renderer.finish();
    try std.testing.expectEqualStrings("   123456. item\n", output.written());
}

test "bold candidate overflow preserves the first closing star" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    var input: [2 + 254 + 2 + 1]u8 = undefined;
    @memcpy(input[0..2], "**");
    @memset(input[2 .. 2 + 254], 'a');
    @memcpy(input[2 + 254 ..], "**\n");
    for (input) |byte| try renderer.feed(&.{byte});
    try renderer.finish();
    try std.testing.expectEqualSlices(u8, &input, output.written());
}

test "inline closing delimiter counts toward the 256-byte candidate bound" {
    inline for (.{
        .{ .marker = "*", .payload = 254, .style = "\x1b[3m", .fits = true },
        .{ .marker = "*", .payload = 255, .style = "\x1b[3m", .fits = false },
        .{ .marker = "`", .payload = 254, .style = "\x1b[4m", .fits = true },
        .{ .marker = "`", .payload = 255, .style = "\x1b[4m", .fits = false },
        .{ .marker = "**", .payload = 252, .style = "\x1b[1m", .fits = true },
        .{ .marker = "**", .payload = 253, .style = "\x1b[1m", .fits = false },
    }) |case| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var renderer: Renderer = .{ .out = &output.writer };
        for (case.marker) |byte| try renderer.feed(&.{byte});
        for (0..case.payload) |_| try renderer.feed("a");
        for (case.marker) |byte| try renderer.feed(&.{byte});
        try renderer.finish();

        var expected = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer expected.deinit();
        try expected.writer.writeAll(if (case.fits) case.style else case.marker);
        for (0..case.payload) |_| try expected.writer.writeByte('a');
        try expected.writer.writeAll(if (case.fits) "\x1b[0m" else case.marker);
        try std.testing.expectEqualSlices(u8, expected.written(), output.written());
    }
}

test "strong overflow boundaries retain their closer and resume after every closer split" {
    inline for (.{ 253, 254 }) |payload| {
        var input: [2 + 254 + "** then `ok`\n".len]u8 = undefined;
        @memcpy(input[0..2], "**");
        @memset(input[2 .. 2 + payload], 'a');
        @memcpy(input[2 + payload ..][0.."** then `ok`\n".len], "** then `ok`\n");
        const source = input[0 .. 2 + payload + "** then `ok`\n".len];
        for (2 + payload..2 + payload + 3) |split| {
            var output = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer output.deinit();
            var renderer: Renderer = .{ .out = &output.writer };
            try renderer.feed(source[0..split]);
            try renderer.feed(source[split..]);
            try renderer.finish();

            var expected = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer expected.deinit();
            try expected.writer.writeAll(source[0 .. 2 + payload]);
            try expected.writer.writeAll("** then \x1b[4mok\x1b[0m\n");
            try std.testing.expectEqualSlices(u8, expected.written(), output.written());
        }
    }
}

test "overlong closer stays literal rather than opening markup in the suffix" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    try renderer.feed("*");
    for (0..255) |_| try renderer.feed("a");
    try renderer.feed("*tail*\n");
    try renderer.finish();
    var expected: [1 + 255 + 7]u8 = undefined;
    expected[0] = '*';
    @memset(expected[1..256], 'a');
    @memcpy(expected[256..], "*tail*\n");
    try std.testing.expectEqualSlices(u8, &expected, output.written());
}

test "payload overflow does not turn its closer into an opener" {
    inline for (.{ .{ "*", 255 }, .{ "`", 255 }, .{ "**", 254 } }) |case| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var renderer: Renderer = .{ .out = &output.writer };
        try renderer.feed(case[0]);
        for (0..case[1]) |_| try renderer.feed("a");
        try renderer.feed(case[0]);
        try renderer.feed(" then *ok*\n");
        try renderer.finish();

        var expected = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer expected.deinit();
        try expected.writer.writeAll(case[0]);
        for (0..case[1]) |_| try expected.writer.writeByte('a');
        try expected.writer.writeAll(case[0] ++ " then \x1b[3mok\x1b[0m\n");
        try std.testing.expectEqualSlices(u8, expected.written(), output.written());
    }
}

test "outer code preserves literal backslashes across every feed split and finish" {
    const cases = .{
        .{ "`C:\\`", "\x1b[4mC:\\\x1b[0m" },
        .{ "`C:\\` tail\n", "\x1b[4mC:\\\x1b[0m tail\n" },
        .{ "`C:\\tmp` then *ok*", "\x1b[4mC:\\tmp\x1b[0m then \x1b[3mok\x1b[0m" },
        .{ "`C:\\", "`C:\\" },
    };
    inline for (cases) |case| {
        for (0..case[0].len + 2) |split| {
            var output = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer output.deinit();
            var renderer: Renderer = .{ .out = &output.writer };
            if (split <= case[0].len) {
                try renderer.feed(case[0][0..split]);
                try renderer.feed(case[0][split..]);
            } else {
                for (case[0]) |byte| try renderer.feed(&.{byte});
            }
            try renderer.finish();
            try std.testing.expectEqualStrings(case[1], output.written());
        }
    }
}

test "escaped star cannot close a strong candidate" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    for ("**a\\**\n**a\\***\n") |byte| try renderer.feed(&.{byte});
    try renderer.finish();
    try std.testing.expectEqualStrings("**a\\**\n\x1b[1ma\\*\x1b[0m\n", output.written());
}

test "unsupported consecutive star runs stay literal before later strong markup" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    for ("foo *****\n***value*** then **ok**\nfoo***bar***baz\n") |byte| try renderer.feed(&.{byte});
    try renderer.finish();
    try std.testing.expectEqualStrings("foo *****\n***value*** then \x1b[1mok\x1b[0m\nfoo***bar***baz\n", output.written());
}

test "nested code composes with strong and heading without exposing delimiters" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    for ("- **`README.md`** — after\n# **before `a**b` after** tail\n") |byte| try renderer.feed(&.{byte});
    try renderer.finish();
    try std.testing.expectEqualStrings("\x1b[1m-\x1b[0m \x1b[1m\x1b[0m\x1b[1m\x1b[4mREADME.md\x1b[0m\x1b[1m\x1b[0m — after\n" ++
        "\x1b[1mbefore \x1b[0m\x1b[1m\x1b[4ma**b\x1b[0m\x1b[1m after tail\x1b[0m\n", output.written());
}

test "unsupported asterisk runs preserve bytes and later supported markup" {
    // CommonMark 0.31.2 example 439 keeps the five stars literal; Rui also
    // deliberately keeps triple emphasis literal rather than nesting it.
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    for ("foo *****\n***x*** then **ok**\nfoo***bar***baz\nfoo **\\***\n") |byte| try renderer.feed(&.{byte});
    try renderer.finish();
    try std.testing.expectEqualStrings("foo *****\n***x*** then \x1b[1mok\x1b[0m\n" ++
        "foo***bar***baz\nfoo \x1b[1m\\*\x1b[0m\n", output.written());
}

test "italic code restores parent style and flushes incomplete UTF-8 at transitions" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    for ("*before `x**y` after*\n**bad \xe2\x82`code` good**\n") |byte| try renderer.feed(&.{byte});
    try renderer.finish();
    try std.testing.expectEqualStrings("\x1b[3mbefore \x1b[0m\x1b[3m\x1b[4mx**y\x1b[0m\x1b[3m after\x1b[0m\n" ++
        "\x1b[1mbad \\xe2\\x82\x1b[0m\x1b[1m\x1b[4mcode\x1b[0m\x1b[1m good\x1b[0m\n", output.written());
}

test "unclosed nested code and full candidate retain every original byte" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    try renderer.feed("**before `unclosed**\n");
    try renderer.feed("**");
    for (0..span_limit - 2) |_| try renderer.feed("a");
    try renderer.feed("**\n");
    try renderer.finish();
    try std.testing.expect(std.mem.startsWith(u8, output.written(), "**before `unclosed**\n**"));
    try std.testing.expectEqual(@as(usize, "**before `unclosed**\n".len + span_limit + 2 + 1), output.written().len);
    try std.testing.expect(std.mem.endsWith(u8, output.written(), "aa**\n"));
}

test "overflow closing backtick stays literal and later code resumes after outer closer" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    try renderer.feed("**`");
    for (0..span_limit - 2) |_| try renderer.feed("a");
    try renderer.feed("`** then `ok`\n");
    try renderer.finish();
    var expected: [span_limit + 32]u8 = undefined;
    @memcpy(expected[0..3], "**`");
    @memset(expected[3 .. span_limit + 1], 'a');
    @memcpy(expected[span_limit + 1 ..][0.."`** then \x1b[4mok\x1b[0m\n".len], "`** then \x1b[4mok\x1b[0m\n");
    try std.testing.expectEqualStrings(expected[0 .. span_limit + 1 + "`** then \x1b[4mok\x1b[0m\n".len], output.written());
}

test "overflow before nested opener preserves both abandoned delimiter pairs" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    try renderer.feed("**");
    for (0..span_limit - 2) |_| try renderer.feed("a");
    for ("`x`** then `ok`\n") |byte| try renderer.feed(&.{byte});
    try renderer.finish();

    var expected: [span_limit + "`x`** then ".len + "\x1b[4mok\x1b[0m\n".len]u8 = undefined;
    @memcpy(expected[0..2], "**");
    @memset(expected[2..span_limit], 'a');
    @memcpy(expected[span_limit..][0.."`x`** then ".len], "`x`** then ");
    @memcpy(expected[span_limit + "`x`** then ".len ..], "\x1b[4mok\x1b[0m\n");
    try std.testing.expectEqualStrings(&expected, output.written());
}

test "empty nested backticks remain literal within styled text" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    for ("**a `` b** and *x `` y*\n") |byte| try renderer.feed(&.{byte});
    try renderer.finish();
    try std.testing.expectEqualStrings("\x1b[1ma `` b\x1b[0m and \x1b[3mx `` y\x1b[0m\n", output.written());
}

test "empty nested backticks beside the outer closer stay literal across chunk splits" {
    const input = "**a ``** then *ok*\n";
    const expected = "\x1b[1ma ``\x1b[0m then \x1b[3mok\x1b[0m\n";
    for (0..input.len + 1) |split| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var renderer: Renderer = .{ .out = &output.writer };
        try renderer.feed(input[0..split]);
        try renderer.feed(input[split..]);
        try renderer.finish();
        try std.testing.expectEqualStrings(expected, output.written());
    }
}

test "escaped star interrupts a strong closer and backslash in code does not escape its tick" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    try renderer.feed("**a*\\**\n**`a\\`b**\n");
    try renderer.finish();
    try std.testing.expectEqualStrings("**a*\\**\n\x1b[1m\x1b[0m\x1b[1m\x1b[4ma\\\x1b[0m\x1b[1mb\x1b[0m\n", output.written());
}

test "overflow recovery requires adjacent unescaped strong closer" {
    const suffix = "*\\*** then **ok**";
    var input: [span_limit + suffix.len]u8 = undefined;
    @memcpy(input[0..2], "**");
    @memset(input[2..span_limit], 'a');
    @memcpy(input[span_limit..], suffix);
    const rendered_suffix = "*\\*** then \x1b[1mok\x1b[0m";
    var expected: [span_limit + rendered_suffix.len]u8 = undefined;
    @memcpy(expected[0..span_limit], input[0..span_limit]);
    @memcpy(expected[span_limit..], rendered_suffix);
    for (0..input.len + 1) |split| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var renderer: Renderer = .{ .out = &output.writer };
        try renderer.feed(input[0..split]);
        try renderer.feed(input[split..]);
        try renderer.finish();
        try std.testing.expectEqualStrings(&expected, output.written());
    }
}

test "adjacent nonempty nested code spans close and reopen" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    for ("**`a``b`**\n*`x``y`*\n") |byte| try renderer.feed(&.{byte});
    try renderer.finish();
    try std.testing.expectEqualStrings("\x1b[1m\x1b[0m\x1b[1m\x1b[4ma\x1b[0m\x1b[1m\x1b[0m\x1b[1m\x1b[4mb\x1b[0m\x1b[1m\x1b[0m\n" ++
        "\x1b[3m\x1b[0m\x1b[3m\x1b[4mx\x1b[0m\x1b[3m\x1b[0m\x1b[3m\x1b[4my\x1b[0m\x1b[3m\x1b[0m\n", output.written());
}

test "empty pair after nonempty nested code stays in the outer style" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    for ("**`a```**\n*`b```*\n") |byte| try renderer.feed(&.{byte});
    try renderer.finish();
    try std.testing.expectEqualStrings("\x1b[1m\x1b[0m\x1b[1m\x1b[4ma\x1b[0m\x1b[1m``\x1b[0m\n" ++
        "\x1b[3m\x1b[0m\x1b[3m\x1b[4mb\x1b[0m\x1b[3m``\x1b[0m\n", output.written());
}

test "indented fences render code without marker lines or reverse video" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    for ("   ```sh\n  echo `hello`\n   ```\n`inline`\n") |byte| try renderer.feed(&.{byte});
    try renderer.finish();
    try std.testing.expectEqualStrings("  echo `hello`\n\x1b[4minline\x1b[0m\n", output.written());
}

test "closing fence at end of answer needs no final newline" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    for ("   ```sh\n  echo hi\n   ```") |byte| try renderer.feed(&.{byte});
    try renderer.finish();
    try std.testing.expectEqualStrings("  echo hi\n", output.written());
}

test "rendered content and unsupported fence syntax stay visible without a gutter" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    for ("# Title\n```zig\n  call\n```\n```bad info\ntrailing `open\n") |byte| try renderer.feed(&.{byte});
    try renderer.finish();
    try std.testing.expectEqualStrings("\x1b[1mTitle\x1b[0m\n  call\n```bad info\ntrailing `open\n", output.written());
}

test "oversized fence candidate is literal and does not enter code state" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    try renderer.feed("```zig");
    for (0..128) |_| try renderer.feed("x");
    try renderer.feed("\n# heading\n");
    try renderer.finish();
    const expected = "```zig" ++ ("x" ** 128) ++ "\n\x1b[1mheading\x1b[0m\n";
    try std.testing.expectEqualStrings(expected, output.written());
}

test "empty assistant content and empty fence add no text" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    try renderer.finish();
    try std.testing.expectEqualStrings("", output.written());
    var fenced = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer fenced.deinit();
    var empty_fence: Renderer = .{ .out = &fenced.writer };
    try empty_fence.feed("```\n```\n");
    try empty_fence.finish();
    try std.testing.expectEqualStrings("", fenced.written());
}

test "unclosed and oversized fences remain literal and later headings still render" {
    var unclosed = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer unclosed.deinit();
    var first: Renderer = .{ .out = &unclosed.writer };
    for ("```sh\n  echo hi\n") |byte| try first.feed(&.{byte});
    try first.finish();
    try std.testing.expectEqualStrings("```sh\n  echo hi\n", unclosed.written());

    var overflow = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer overflow.deinit();
    var second: Renderer = .{ .out = &overflow.writer };
    try second.feed("```sh\n");
    for (0..fence_limit) |_| try second.feed("x");
    try second.feed("\n```\n# next\n");
    try second.finish();
    const expected = "```sh\n" ++ ("x" ** fence_limit) ++ "\n```\n\x1b[1mnext\x1b[0m\n";
    try std.testing.expectEqualStrings(expected, overflow.written());
}

test "fence overflow mid-line cannot reinterpret a suffix as the closing line" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    try renderer.feed("```sh\n");
    for (0..fence_limit - "```sh\n".len) |_| try renderer.feed("x");
    try renderer.feed("```\n# still code\n```\n# next\n");
    try renderer.finish();
    const expected = "```sh\n" ++ ("x" ** (fence_limit - "```sh\n".len)) ++ "```\n# still code\n```\n\x1b[1mnext\x1b[0m\n";
    try std.testing.expectEqualStrings(expected, output.written());
}

test "fence overflow immediately after a closing marker resumes markup" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    const opener = "```sh\n";
    const body_len = fence_limit - opener.len - "\n```".len;
    try renderer.feed(opener);
    for (0..body_len) |_| try renderer.feed("x");
    try renderer.feed("\n```\n# next\n");
    try renderer.finish();

    const tail = "\n```\n\x1b[1mnext\x1b[0m\n";
    var expected: [opener.len + body_len + tail.len]u8 = undefined;
    @memcpy(expected[0..opener.len], opener);
    @memset(expected[opener.len .. opener.len + body_len], 'x');
    @memcpy(expected[opener.len + body_len ..], tail);
    try std.testing.expectEqualStrings(&expected, output.written());
}

test "overflow and long lines continue without retaining history" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    try renderer.feed("`open");
    for (0..100_000) |_| try renderer.feed("x");
    try renderer.feed("\nend");
    try renderer.finish();
    var expected: [100_009]u8 = undefined;
    @memcpy(expected[0..5], "`open");
    @memset(expected[5..100_005], 'x');
    @memcpy(expected[100_005..], "\nend");
    try std.testing.expectEqualSlices(u8, &expected, output.written());
    try std.testing.expect(@sizeOf(Renderer) < 5 * 1024);
}

test "sixteen MiB answer uses fixed parser and output storage" {
    var buffer: [4096]u8 = undefined;
    var discard = std.Io.Writer.Discarding.init(&buffer);
    var renderer: Renderer = .{ .out = &discard.writer };
    const chunk = [_]u8{'a'} ** 4096;
    for (0..4096) |_| try renderer.feed(&chunk);
    try renderer.finish();
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024), discard.fullCount());
    try std.testing.expect(@sizeOf(Renderer) < 5 * 1024);
}
