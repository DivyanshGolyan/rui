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
    // Backslashes inside nested code are content, not outer escapes.
    const escaped = !self.code_open and self.escape_next;
    self.escape_next = false;
    if (!escaped and !self.code_open and byte == '\\') self.escape_next = true;
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
