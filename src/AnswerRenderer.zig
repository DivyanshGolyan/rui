const std = @import("std");
const TerminalText = @import("TerminalText.zig");
const Markdown = @import("markdown_prefix.zig");
const Fence = Markdown.Fence;
const Rows = @import("table_row.zig");
const Blocks = @import("output_blocks.zig");
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
/// A link waiting for its last byte. `[text](address)` shows its text and
/// a bare web address or local path shows itself, each as an OSC 8 link.
/// A candidate never crosses a line, so it shares `held` with fences, which
/// begin and end only at line starts.
const Link = enum { none, text, text_closed, target, bare, local, local_literal };
const Boundary = enum { word, prose, other };

out: *std.Io.Writer,
/// Borrowed process HOME; only a valid absolute path enables `~/` links.
home: []const u8 = "",
prefix: [prefix_limit]u8 = undefined,
prefix_len: usize = 0,
span: [span_limit]u8 = undefined,
span_len: usize = 0,
inline_count: u3 = 0,
// These bounded annotations are produced by the same bytewise recognizer that
// finds the outer closer. Formatting consumes them; it does not parse again.
code_bytes: [span_limit / 8]u8 = @splat(0),
syntax_bytes: [span_limit / 8]u8 = @splat(0),
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
/// A pending fenced block's bytes, or a pending link's.
held: [fence_limit]u8 = undefined,
link: Link = .none,
link_len: usize = 0,
link_depth: u16 = 0,
link_text_end: usize = 0,
link_escape: bool = false,
/// The link text is being shown: no link starts inside it.
in_link: bool = false,
boundary: Boundary = .prose,
fence_len: usize = 0,
fence_body_start: usize = 0,
fence_line_start: usize = 0,
fence_closer: Fence.Closer = .{},
line_style: bool = false,
active_style: Style = .{},
line_start: bool = true,
literal_line: bool = false,
terminal_text: TerminalText = .{ .mode = .multiline },

// Capability is deliberately absent for CLI/inspection/tool callers.
blocks: ?Blocks.Sink = null,
block_context: Markdown.Context = .plain,
block_projection: ?Markdown.Context.Projection = null,
block_head_len: u8 = 0,
block_len: u16 = 0,
block_header: u16 = 0,
block_columns: ?Rows.Columns = null,
block_stream: bool = false,
block_quote: bool = false,

pub fn feed(self: *Renderer, bytes: []const u8) !void {
    if (self.blocks == null) return self.feedLegacy(bytes);
    for (bytes) |byte| try self.blockByte(byte);
}

fn feedLegacy(self: *Renderer, bytes: []const u8) !void {
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
                if (self.prefix_len < 10 or (self.prefix_len < prefix_limit and Fence.candidate(self.prefix[0..self.prefix_len]))) continue;
                if (self.prefix_len == prefix_limit and Fence.candidate(self.prefix[0..self.prefix_len])) self.literal_line = true;
                try self.flushPrefix();
                continue;
            }
            try self.flushPrefix();
        }
        if (byte == '\n') {
            try self.endLink();
            self.boundary = .prose;
            try self.flushSpan();
            self.escape_next = false;
            self.literal_run = null;
            if (self.line_style) try self.transition(.{});
            self.line_style = false;
            if (self.fence_pending) {
                self.held[self.fence_len] = byte;
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
    if (self.blocks != null) try self.finishBlocks();
    try self.finishLegacy();
}

fn finishPrefix(self: *Renderer) !void {
    if (self.line_start and self.prefix_len != 0) {
        // A delimiter without its line ending is not a complete block marker.
        if (Fence.candidate(self.prefix[0..self.prefix_len])) self.literal_line = true;
        try self.flushPrefix();
    }
}

fn finishLegacy(self: *Renderer) !void {
    try self.finishPrefix();
    if (self.fence_pending and !self.fence_literal) {
        if (Fence.closing(self.held[self.fence_line_start..self.fence_len])) {
            try self.literalBlock(self.held[self.fence_body_start..self.fence_line_start]);
        } else try self.literalBlock(self.held[0..self.fence_len]);
    }
    try self.endLink();
    try self.flushSpan();
    if (self.line_style) try self.transition(.{});
    try self.terminal_text.finish(self.out);
}

/// One pre-inline owner. Context commits once per hard line; table probing
/// shares held with legacy fences/links, never a second whole-row buffer.
fn blockByte(self: *Renderer, byte: u8) !void {
    if (self.block_projection == null) {
        if (byte == '\n') {
            _ = try self.resolveHead(.line_feed);
        } else {
            self.prefix[self.block_head_len] = byte;
            self.block_head_len += 1;
            const ending: Markdown.HeadEnding = if (self.block_head_len == Markdown.head_limit) .limit_cut else .pending;
            if (!try self.resolveHead(ending)) return;
            return;
        }
    }
    if (self.block_stream) {
        try self.feedLegacy(&.{byte});
    } else {
        if (self.block_len == fence_limit) {
            // Combined candidate credit is exhausted. The current line can
            // still be a header after replaying the older candidate.
            if (self.block_header != 0) {
                const header = self.block_header;
                try self.replayHeld(0, header);
                std.mem.copyForwards(u8, self.held[0 .. self.block_len - header], self.held[header..self.block_len]);
                self.block_len -= header;
                self.block_header = 0;
            } else {
                try self.endTable();
                try self.replayHeld(0, self.block_len);
                self.block_len = 0;
                self.block_stream = true;
            }
        }
        if (self.block_stream) try self.feedLegacy(&.{byte}) else {
            self.held[self.block_len] = byte;
            self.block_len += 1;
        }
    }
    if (byte == '\n') {
        if (!self.block_stream) try self.completeRawLine(.line_feed);
        try self.endQuote();
        self.block_projection = null;
        self.block_head_len = 0;
        self.block_stream = false;
    }
}

fn resolveHead(self: *Renderer, ending: Markdown.HeadEnding) !bool {
    const previous = self.block_context;
    const decision = switch (previous.step(self.prefix[0..self.block_head_len], ending)) {
        .need_more => return false,
        .resolved => |value| value,
    };
    self.block_context = decision.next;
    self.block_projection = decision.projection;
    // Replaying a prior header uses legacy prefix too. Keep only this tiny
    // unresolved head on stack across that replay, not another line buffer.
    var head: [prefix_limit]u8 = undefined;
    const length = self.block_head_len;
    @memcpy(head[0..length], self.prefix[0..length]);
    self.block_head_len = 0;
    const stream = decision.projection.mode == .@"opaque" or decision.projection.quote != null or self.fence_pending;
    if (stream) {
        if (self.block_header != 0) {
            try self.replayHeld(0, self.block_header);
            self.block_header = 0;
            self.block_len = 0;
        }
        try self.endTable();
        // Broader opacity closers NEVER broaden legacy stripping or copy-code.
        // If strict legacy effects still own the block, remain ineligible.
        const opening = previous == .plain and decision.next == .fence and Fence.candidate(head[0..length]);
        if (decision.projection.mode == .@"opaque" and !self.fence_pending and (!opening or decision.projection.quote != null)) self.literal_line = true;
        if (!self.fence_pending) if (decision.projection.quote) |quote| {
            self.block_quote = try self.blocks.?.send(.{ .quote = quote });
        };
        self.block_stream = true;
        try self.feedLegacy(head[0..length]);
    } else {
        // A head is <=128 bytes. Replay an older header first if the shared
        // candidate budget cannot retain both; no truncation becomes EOF.
        if (self.block_len + length > fence_limit) {
            try self.replayHeld(0, self.block_header);
            self.block_len = 0;
            self.block_header = 0;
        }
        @memcpy(self.held[self.block_len..][0..length], head[0..length]);
        self.block_len += length;
    }
    return true;
}

fn replayHeld(self: *Renderer, start: usize, end: usize) !void {
    // Legacy link/fence writes are confined to already consumed positions:
    // each written source byte first passed through this value-only cursor.
    // No saved slice is allowed to advance independently of this cursor.
    var at = start;
    while (at < end) : (at += 1) {
        const byte = self.held[at];
        try self.feedLegacy(&.{byte});
    }
}

fn completeRawLine(self: *Renderer, ending: Rows.Ending) !void {
    const total = self.block_len;
    const header = self.block_header;
    const line_end = total - @as(u16, @intFromBool(ending == .line_feed));
    if (self.block_columns) |columns| {
        const parsed = Rows.parse(self.held[0..line_end], ending, columns.count);
        if (parsed == .row and try self.blocks.?.send(.{ .table_row = self.held[0..total] })) {
            self.block_len = 0;
            return;
        }
        try self.endTable();
    }
    if (header != 0) {
        const pair = Rows.header(self.held[0 .. header - 1], self.held[header..line_end], ending);
        if (pair == .columns and try self.blocks.?.send(.{ .begin_table = .{ .header = self.held[0..header], .delimiter = self.held[header..total], .columns = pair.columns } })) {
            self.block_columns = pair.columns;
            self.block_header = 0;
            self.block_len = 0;
            return;
        }
        try self.replayHeld(0, header);
        std.mem.copyForwards(u8, self.held[0 .. total - header], self.held[header..total]);
        self.block_len = total - header;
        self.block_header = 0;
    }
    const end = self.block_len - @as(u16, @intFromBool(ending == .line_feed));
    if (ending == .line_feed and self.block_len < fence_limit and Rows.parse(self.held[0..end], ending, null) == .row) {
        self.block_header = self.block_len;
    } else {
        try self.replayHeld(0, self.block_len);
        self.block_len = 0;
    }
}

fn endTable(self: *Renderer) !void {
    if (self.block_columns != null) {
        _ = try self.blocks.?.send(.end_table);
        self.block_columns = null;
    }
}
fn endQuote(self: *Renderer) !void {
    if (self.block_quote) {
        // The final line may still live in the renderer prefix, not Writer.
        try self.finishPrefix();
        try self.endLink();
        try self.flushSpan();
        try self.terminal_text.finish(self.out);
        _ = try self.blocks.?.send(.{ .quote = null });
        self.block_quote = false;
    }
}
fn finishBlocks(self: *Renderer) !void {
    if (self.block_projection == null and self.block_head_len != 0) _ = try self.resolveHead(.canonical_eof);
    if (!self.block_stream and self.block_len != 0) {
        if (self.block_projection != null) try self.completeRawLine(.canonical_eof);
        if (self.block_header != 0) {
            try self.replayHeld(0, self.block_header);
            self.block_len = 0;
            self.block_header = 0;
        }
    }
    try self.endQuote();
    try self.endTable();
}

fn flushPrefix(self: *Renderer) !void {
    if (!self.line_start) return;
    self.line_start = false;
    const prefix = self.prefix[0..self.prefix_len];
    self.prefix_len = 0;
    if (Fence.candidate(prefix)) {
        if (!self.literal_line and Fence.opening(prefix)) {
            @memcpy(self.held[0..prefix.len], prefix);
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

/// Finds an answer's last complete fenced code block as its bytes pass,
/// by the fence lines that make the renderer show a block as code.
pub const LastCode = struct {
    pub const Range = struct { start: u64, length: u64 };

    // A line this long is never a fence line, as in the renderer.
    line: [prefix_limit]u8 = undefined,
    line_len: usize = 0,
    offset: u64 = 0,
    line_start: u64 = 0,
    body: ?u64 = null,
    last: ?Range = null,

    pub fn feed(self: *LastCode, bytes: []const u8) void {
        for (bytes) |byte| {
            self.offset += 1;
            if (byte != '\n') {
                if (self.line_len < prefix_limit) {
                    self.line[self.line_len] = byte;
                    self.line_len += 1;
                }
                continue;
            }
            self.endLine(true);
            self.line_start = self.offset;
            self.line_len = 0;
        }
    }

    /// The last block's content without its final line ending, or null.
    /// A closing fence may end the answer without one; an opening fence
    /// needs its line ending.
    pub fn finish(self: *LastCode) ?Range {
        self.endLine(false);
        return self.last;
    }

    fn endLine(self: *LastCode, opens: bool) void {
        if (self.line_len >= prefix_limit) return;
        const line = self.line[0..self.line_len];
        if (self.body) |start| {
            if (!Fence.closing(line)) return;
            self.last = .{ .start = start, .length = (self.line_start - start) -| 1 };
            self.body = null;
        } else if (opens and Fence.opening(line)) self.body = self.offset;
    }
};

fn fencedByte(self: *Renderer, byte: u8) !void {
    if (!self.fence_literal and self.fence_len == fence_limit) {
        // We cannot promise that a closing fence exists. Emit all retained
        // syntax and keep subsequent bytes literal until this block ends.
        try self.literalBlock(self.held[0..self.fence_len]);
        self.fence_literal = true;
        self.fence_closer = .{};
        for (self.held[self.fence_line_start..self.fence_len]) |line_byte| self.fence_closer.feed(line_byte);
        self.fence_len = 0;
    }
    if (self.fence_literal) {
        try self.literalBlock(&.{byte});
        if (byte == '\n') {
            if (self.fence_closer.matches()) {
                self.fence_pending = false;
                self.fence_literal = false;
                self.fence_body_start = 0;
            }
            self.fence_closer = .{};
        } else self.fence_closer.feed(byte);
        return;
    }
    self.held[self.fence_len] = byte;
    self.fence_len += 1;
    if (byte == '\n') {
        if (Fence.closing(self.held[self.fence_line_start .. self.fence_len - 1])) {
            try self.literalBlock(self.held[self.fence_body_start..self.fence_line_start]);
            self.fence_pending = false;
            self.fence_len = 0;
            self.fence_body_start = 0;
        } else self.fence_line_start = self.fence_len;
    }
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

fn prose(self: *Renderer, byte: u8) (std.Io.Writer.Error || error{NoSpaceLeft})!void {
    return self.proseWithLocal(byte, true);
}

fn proseWithLocal(self: *Renderer, byte: u8, local: bool) (std.Io.Writer.Error || error{NoSpaceLeft})!void {
    if (self.literal_line) return self.safe(byte);
    if (self.link != .none) return self.linkByte(byte);
    const before = self.boundary;
    self.boundary = boundaryAfter(byte);
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
        } else if (!self.in_link and (byte == '[' or (before != .word and (byte == 'h' or byte == 'H')) or
            (local and before == .prose and (byte == '/' or byte == '~'))))
        {
            self.link = if (byte == '[') .text else if (byte == '/' or byte == '~') .local else .bare;
            self.held[0] = byte;
            self.link_len = 1;
            self.link_depth = 0;
            self.link_escape = false;
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
    const parent = self.base();
    const outer: Style = if (self.inline_kind == .code)
        .{ .bold = parent.bold, .underline = true }
    else
        .{ .bold = parent.bold or self.inline_kind == .strong, .italic = self.inline_kind == .emphasis, .underline = parent.underline };
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

/// The style of plain text here: a heading's bold, a link's underline.
fn base(self: *const Renderer) Style {
    return .{ .bold = self.line_style, .underline = self.in_link };
}

/// Takes one byte into the pending link: it completes the link, stays
/// pending, or shows the held bytes as ordinary prose.
fn linkByte(self: *Renderer, byte: u8) !void {
    switch (self.link) {
        .none => unreachable,
        .bare => {
            const scheme: []const u8 = if (self.link_len > 4 and self.held[4] == ':') "http://" else "https://";
            if (self.link_len == 4) {
                if (byte != ':' and std.ascii.toLower(byte) != 's') return self.dropLink(byte);
            } else if (self.link_len < scheme.len) {
                if (std.ascii.toLower(byte) != scheme[self.link_len]) return self.dropLink(byte);
            } else if (self.link_len == scheme.len and (byte == '/' or addressEnds(byte))) {
                // No host: what the scheme held was never an address.
                return self.dropLink(byte);
            } else if (addressEnds(byte)) {
                try self.showBare();
                return self.prose(byte);
            } else if (self.link_len == TerminalText.max_link_bytes) return self.dropLink(byte);
        },
        .local => {
            if (localEnds(byte)) {
                try self.showLocal();
                return self.prose(byte);
            }
            if ((self.link_len == 1 and ((self.held[0] == '~' and byte != '/') or
                (self.held[0] == '/' and byte == '/'))) or self.link_len == TerminalText.max_link_bytes)
            {
                try self.literalLocal();
                self.link = .local_literal;
                return self.safe(byte);
            }
        },
        .local_literal => {
            if (localEnds(byte)) {
                self.link = .none;
                self.boundary = .other;
                return self.prose(byte);
            }
            return self.safe(byte);
        },
        .text => if (self.link_escape) {
            self.link_escape = false;
        } else switch (byte) {
            '\\' => self.link_escape = true,
            '[' => return self.dropLink(byte),
            ']' => {
                if (self.link_len == 1) return self.dropLink(byte);
                self.link = .text_closed;
                self.link_text_end = self.link_len;
            },
            else => {},
        },
        .text_closed => if (byte == '(') {
            self.link = .target;
        } else return self.dropLink(byte),
        .target => switch (byte) {
            '(' => self.link_depth += 1,
            ')' => if (self.link_depth == 0) {
                // The closing `)` completes the link without being held.
                if (!TerminalText.linkTarget(self.held[self.link_text_end + 2 .. self.link_len])) return self.dropLink(byte);
                return self.showText();
            } else {
                self.link_depth -= 1;
            },
            else => if (byte <= ' ' or byte >= 0x7f or byte == '[') return self.dropLink(byte),
        },
    }
    if (self.link_len == self.held.len) return self.dropLink(byte);
    self.held[self.link_len] = byte;
    self.link_len += 1;
}

/// A line or the answer ends: a bare address ends with it, other links
/// are left incomplete.
fn endLink(self: *Renderer) !void {
    // Dropped text can hold a bare address, which ends here too.
    while (self.link != .none) {
        switch (self.link) {
            .bare => try self.showBare(),
            .local => try self.showLocal(),
            .local_literal => self.link = .none,
            else => try self.dropHeld(),
        }
    }
}

fn dropLink(self: *Renderer, byte: u8) !void {
    try self.dropHeld();
    try self.prose(byte);
}

/// Shows the held bytes as prose that was never a link. Only the first byte
/// started the candidate: a text candidate holds no other `[`, so prose
/// rereading the rest starts at most a bare candidate, whose held bytes
/// are written behind this read.
fn dropHeld(self: *Renderer) !void {
    const length = self.link_len;
    self.link = .none;
    self.link_len = 0;
    try self.safe(self.held[0]);
    self.boundary = boundaryAfter(self.held[0]);
    for (1..length) |index| {
        const byte = self.held[index];
        try self.proseWithLocal(byte, false);
    }
}

/// A bare address ends before trailing punctuation, which reads as the
/// sentence's, and before a `)` it did not open.
fn showBare(self: *Renderer) !void {
    const end = trimmedEnd(self.held[0..self.link_len], "http://".len, ".,:;!?'\"*_~]");
    const address = self.held[0..end];
    if (!TerminalText.linkTarget(address)) return self.dropHeld();
    const length = self.link_len;
    self.link = .none;
    self.link_len = 0;
    try self.openLink(address);
    try self.safeSlice(address);
    try self.closeLink();
    for (self.held[end..length]) |byte| try self.prose(byte);
}

fn trimmedEnd(bytes: []const u8, minimum: usize, punctuation: []const u8) usize {
    var end = bytes.len;
    // Unopened `)`s: a trimmed `)` closes one fewer, a trimmed `(` one more.
    var unopened = @as(isize, @intCast(std.mem.count(u8, bytes, ")"))) - @as(isize, @intCast(std.mem.count(u8, bytes, "(")));
    while (end > minimum) : (end -= 1) {
        const last = bytes[end - 1];
        if (last == ')' and unopened > 0) {
            unopened -= 1;
            continue;
        }
        if (std.mem.indexOfScalar(u8, punctuation, last) == null) break;
    }
    return end;
}

fn literalLocal(self: *Renderer) !void {
    const length = self.link_len;
    self.link = .none;
    self.link_len = 0;
    try self.safeSlice(self.held[0..length]);
    self.boundary = boundaryAfter(self.held[length - 1]);
}

fn showLocal(self: *Renderer) !void {
    const length = self.link_len;
    const end = trimmedEnd(self.held[0..length], 1, ".,:;!?'\"]");
    const path = self.held[0..end];
    const tilde = path[0] == '~';
    if (path.len <= @as(usize, if (tilde) 2 else 1)) return self.literalLocal();
    if (!validPath(path, tilde)) return self.literalLocal();
    var home = if (tilde) self.home else "";
    if (tilde and !validPath(home, false)) return self.literalLocal();
    while (home.len > 0 and home[home.len - 1] == '/') home = home[0 .. home.len - 1];
    const tail = if (tilde) path[1..] else path;
    const home_bytes = encodedSize(home) orelse return self.literalLocal();
    const tail_bytes = encodedSize(tail) orelse return self.literalLocal();
    if ("file://".len + home_bytes + tail_bytes > TerminalText.max_link_bytes) return self.literalLocal();
    self.link = .none;
    self.link_len = 0;
    try self.terminal_text.finish(self.out);
    try self.out.writeAll(TerminalText.link_open ++ "file://");
    try writeEncoded(self.out, home);
    try writeEncoded(self.out, tail);
    try self.out.writeAll(TerminalText.link_end);
    self.in_link = true;
    try self.transition(self.base());
    try self.safeSlice(path);
    try self.closeLink();
    for (self.held[end..length]) |byte| try self.prose(byte);
}

fn validPath(path: []const u8, tilde: bool) bool {
    if (tilde) {
        if (!std.mem.startsWith(u8, path, "~/")) return false;
    } else if (path.len == 0 or path[0] != '/' or std.mem.startsWith(u8, path, "//")) return false;
    const view = std.unicode.Utf8View.init(path) catch return false;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |scalar| if (TerminalText.isControl(scalar)) return false;
    return true;
}

fn uriPlain(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "/-._~", byte) != null;
}

fn encodedSize(bytes: []const u8) ?usize {
    var size: usize = 0;
    for (bytes) |byte| {
        size += if (uriPlain(byte)) @as(usize, 1) else 3;
        if (size > TerminalText.max_link_bytes) return null;
    }
    return size;
}

fn writeEncoded(out: *std.Io.Writer, bytes: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (bytes) |byte| {
        if (uriPlain(byte)) try out.writeByte(byte) else try out.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 15] });
    }
}

fn boundaryAfter(byte: u8) Boundary {
    if (std.ascii.isAlphanumeric(byte) or byte >= 0x80) return .word;
    if (std.ascii.isWhitespace(byte) or std.mem.indexOfScalar(u8, "(<'\"[", byte) != null) return .prose;
    return .other;
}

fn localEnds(byte: u8) bool {
    return byte == ' ' or byte == '\t' or std.mem.indexOfScalar(u8, "<>\"`[", byte) != null;
}

/// Shows `[text](address)`'s text, with its own markup, as the link.
fn showText(self: *Renderer) !void {
    const text_end = self.link_text_end;
    const length = self.link_len;
    self.link = .none;
    self.link_len = 0;
    try self.openLink(self.held[text_end + 2 .. length]);
    for (self.held[1..text_end]) |byte| try self.prose(byte);
    try self.closeLink();
}

fn openLink(self: *Renderer, address: []const u8) !void {
    try self.terminal_text.finish(self.out);
    try self.out.writeAll(TerminalText.link_open);
    try self.out.writeAll(address);
    try self.out.writeAll(TerminalText.link_end);
    self.in_link = true;
    try self.transition(self.base());
}

fn closeLink(self: *Renderer) !void {
    try self.flushSpan();
    self.escape_next = false;
    self.literal_run = null;
    self.in_link = false;
    try self.transition(self.base());
    try self.terminal_text.finish(self.out);
    try self.out.writeAll(TerminalText.link_close);
    self.boundary = .word;
}

/// Where a bare address ends: at a space, a control, non-ASCII text or
/// a byte that delimits an address in prose.
fn addressEnds(byte: u8) bool {
    return byte <= ' ' or byte >= 0x7f or std.mem.indexOfScalar(u8, "<>\"`[", byte) != null;
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
    const expected = "```zig" ++ @as([128]u8, @splat('x')) ++ "\n\x1b[1mheading\x1b[0m\n";
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
    const expected = "```sh\n" ++ @as([fence_limit]u8, @splat('x')) ++ "\n```\n\x1b[1mnext\x1b[0m\n";
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
    const expected = "```sh\n" ++ @as([fence_limit - "```sh\n".len]u8, @splat('x')) ++ "```\n# still code\n```\n\x1b[1mnext\x1b[0m\n";
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
    const chunk = @as([4096]u8, @splat('a'));
    for (0..4096) |_| try renderer.feed(&chunk);
    try renderer.finish();
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024), discard.fullCount());
    try std.testing.expect(@sizeOf(Renderer) < 5 * 1024);
}

test "the last code block is the last complete fenced block" {
    const long_opener = "```" ++ @as([prefix_limit - 3]u8, @splat('a'));
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "Run:\n```sh\nzig build\n```\nthen\n```\nfirst\nsecond\n```\nDone.\n", "first\nsecond" },
        .{ "No code here.\n", null },
        .{ "```py\nunclosed\n", null },
        .{ "```a\nA\n```\n```b\nunclosed\n", "A" },
        .{ "```\nx\n```", "x" },
        .{ "  ```zig\n  code\n   ```\n", "  code" },
        .{ "```\n```\n", "" },
        .{ "```", null },
        .{ "```sh\r\ncode\r\n```\r\n", null },
        .{ "```\ncode\n```\r\n", null },
        .{ "```\ncode\r\n```", "code\r" },
        .{ "````\nx\n````\n", null },
        .{ "```a b\nx\n```\n", null },
        .{ "```\nx\n```  \ny\n```\n", "x\n```  \ny" },
        .{ long_opener ++ "\nx\n```\n", null },
        .{ long_opener[0 .. prefix_limit - 1] ++ "\nx\n```\n", "x" },
    };
    for (cases) |case| {
        // Every split, then a byte at a time: source windows cannot end a line.
        for (0..case[0].len + 1) |split| {
            var code: LastCode = .{};
            code.feed(case[0][0..split]);
            for (case[0][split..]) |byte| code.feed(&.{byte});
            const found = code.finish();
            if (case[1]) |expected| {
                const range = found.?;
                try std.testing.expectEqualStrings(expected, case[0][@intCast(range.start)..][0..@intCast(range.length)]);
            } else try std.testing.expect(found == null);
        }
    }
}

fn expectRendered(input: []const u8, expected: []const u8) !void {
    try expectRenderedHome(input, expected, "");
}

fn expectRenderedHome(input: []const u8, expected: []const u8, home: []const u8) !void {
    for (0..input.len + 1) |split| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var renderer: Renderer = .{ .out = &output.writer, .home = home };
        try renderer.feed(input[0..split]);
        for (input[split..]) |byte| try renderer.feed(&.{byte});
        try renderer.finish();
        try std.testing.expectEqualStrings(expected, output.written());
    }
}

fn linked(comptime address: []const u8, comptime text: []const u8) []const u8 {
    return TerminalText.link_open ++ address ++ TerminalText.link_end ++ "\x1b[4m" ++ text ++ "\x1b[0m" ++ TerminalText.link_close;
}

test "a Markdown link shows its text as an OSC 8 link and hides its address" {
    try expectRendered("See [github.com](https://github.com/a/b).", "See " ++ comptime linked("https://github.com/a/b", "github.com") ++ ".");
    // How answers cite sources: the parentheses around the link stay.
    try expectRendered("Zig 0.17 ([ziglang.org](https://ziglang.org/download/))\n", "Zig 0.17 (" ++ comptime linked("https://ziglang.org/download/", "ziglang.org") ++ ")\n");
    try expectRendered("[`main.zig`](https://x.dev/m) and [*a* b](http://y.dev/(1))", comptime linked("https://x.dev/m", "main.zig") ++ " and " ++
        TerminalText.link_open ++ "http://y.dev/(1)" ++ TerminalText.link_end ++ "\x1b[4m\x1b[0m\x1b[3m\x1b[4ma\x1b[0m\x1b[4m b\x1b[0m" ++ TerminalText.link_close);
    try expectRendered("# [Rui](https://r.dev)\n", "\x1b[1m" ++ TerminalText.link_open ++ "https://r.dev" ++ TerminalText.link_end ++ "\x1b[0m\x1b[1m\x1b[4mRui\x1b[0m\x1b[1m" ++ TerminalText.link_close ++ "\x1b[0m\n");
}

test "a bare address is its own OSC 8 link without the sentence's punctuation" {
    try expectRendered("Docs: https://ziglang.org/doc/, then", "Docs: " ++ comptime linked("https://ziglang.org/doc/", "https://ziglang.org/doc/") ++ ", then");
    try expectRendered("(see https://en.wikipedia.org/wiki/Zig_(language)).", "(see " ++ comptime linked("https://en.wikipedia.org/wiki/Zig_(language)", "https://en.wikipedia.org/wiki/Zig_(language)") ++ ").");
    try expectRendered("- HTTP://A.dev\nhttp://b.dev", "\x1b[1m-\x1b[0m " ++ comptime linked("HTTP://A.dev", "HTTP://A.dev") ++ "\n" ++ linked("http://b.dev", "http://b.dev"));
}

/// The text a terminal shows for rendered output: without SGR and OSC 8.
fn visible(output: []const u8, shown: *std.Io.Writer) !void {
    var index: usize = 0;
    while (index < output.len) {
        if (std.mem.startsWith(u8, output[index..], "\x1b[")) {
            index = std.mem.indexOfScalarPos(u8, output, index, 'm').? + 1;
        } else if (std.mem.startsWith(u8, output[index..], TerminalText.link_open)) {
            index = std.mem.indexOfPos(u8, output, index, TerminalText.link_end).? + TerminalText.link_end.len;
        } else {
            try shown.writeByte(output[index]);
            index += 1;
        }
    }
}

test "text that is not a complete web link shows every byte as written" {
    inline for (.{
        .{ "[a](src/a.zig)", false },        .{ "[a](ftp://x)", false },           .{ "[a](javascript:alert(1))", false },
        .{ "xhttps://y.dev", false },        .{ "http:/x https:// httpx", false }, .{ "[a] (https://x)", true },
        .{ "[](https://x)", true },          .{ "[a](https://x y)", true },        .{ "[a](https://x\nnext", true },
        .{ "[a\n](https://x)", true },       .{ "[[a]](https://x)", true },        .{ "\\[a](https://x)", true },
        .{ "https:/// https://. x", false },
    }) |case| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var renderer: Renderer = .{ .out = &output.writer };
        try renderer.feed(case[0]);
        try renderer.finish();
        errdefer std.debug.print("input={s} output={f}\n", .{ case[0], std.zig.fmtString(output.written()) });
        var shown = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer shown.deinit();
        try visible(output.written(), &shown.writer);
        try std.testing.expectEqualStrings(case[0], shown.written());
        // A web address left in broken link syntax is still a bare link.
        try std.testing.expectEqual(case[1], std.mem.indexOf(u8, output.written(), TerminalText.link_open) != null);
    }
    try expectRendered("[a](./b) [c](https://d.dev)", "[a](./b) " ++ comptime linked("https://d.dev", "c"));
    // A control ends an address and stays visible.
    try expectRendered("[a](https://x\x1b)", "[a](" ++ comptime linked("https://x", "https://x") ++ "\\x1b)");
    // Code is never a link.
    try expectRendered("`https://x.dev` ok", "\x1b[4mhttps://x.dev\x1b[0m ok");
    // A bare address ends with its line.
    try expectRendered("[a](https://x\nnext", "[a](" ++ comptime linked("https://x", "https://x") ++ "\nnext");
}

test "a bare address longer than a link may carry stays plain text" {
    const long = "https://" ++ @as([TerminalText.max_link_bytes]u8, @splat('a'));
    try expectRendered(long ++ " ok", long ++ " ok");
    // A link whose `)` arrives with the held bytes full still completes.
    const text = @as([fence_limit - "[](https://x)".len + 1]u8, @splat('a'));
    try expectRendered("[" ++ text ++ "](https://x)", comptime linked("https://x", &text));
    try expectRendered("[" ++ text ++ "a](https://x)", "[" ++ text ++ "a](" ++ comptime linked("https://x", "https://x") ++ ")");
    // Each `)` past the host is trimmed in constant time.
    const closers = "https://a" ++ @as([2000]u8, @splat(')'));
    try expectRendered(closers ++ " ", comptime linked("https://a", "https://a") ++ @as([2000]u8, @splat(')')) ++ " ");
}

test "a bare local path excludes the sentence semicolon from its OSC 8 link" {
    try expectRendered("The report is at /tmp/report.md;", "The report is at " ++ comptime linked("file:///tmp/report.md", "/tmp/report.md") ++ ";");
}

test "bare local paths expand borrowed HOME without linking sentence punctuation" {
    try expectRenderedHome("The report is at ~/code/personal/rui-implicit-state-machines.md;", "The report is at " ++ comptime linked("file:///Users/test/code/personal/rui-implicit-state-machines.md", "~/code/personal/rui-implicit-state-machines.md") ++ ";", "/Users/test");
    try expectRendered("(/tmp/a;b(c)). /tmp/x?y#z%q;", "(" ++ comptime linked("file:///tmp/a%3Bb%28c%29", "/tmp/a;b(c)") ++ "). " ++ linked("file:///tmp/x%3Fy%23z%25q", "/tmp/x?y#z%q") ++ ";");
    try expectRenderedHome("~/é🙂;", comptime linked("file:///home/a%20b%25%23%3F/%C3%A9%F0%9F%99%82", "~/é🙂") ++ ";", "/home/a b%#?/");
    try expectRenderedHome("~/x", comptime linked("file:///x", "~/x"), "/");
    try expectRenderedHome("~/x", comptime linked("file:///home/%C3%A9/x", "~/x"), "/home/é///");
}

test "bare local paths require valid HOME only for tilde paths" {
    inline for (.{ "", "relative", "//host/home", "/bad\xff", "/bad\x1b", "/bad\u{202e}" }) |home| {
        try expectRenderedHome("~/a; /tmp/a;", "~/a; " ++ comptime linked("file:///tmp/a", "/tmp/a") ++ ";", home);
    }
}

test "bare local paths are prose tokens not relative paths or Markdown targets" {
    inline for (.{
        "a/b x/tmp/a x~/a ./a ../a ~user/a //host/a ///tmp/a ftp://x/a httpx:/x file:///tmp/a",
        "[label](/tmp/a) [label](~/a) [label](file:///tmp/a)",
        "\\/tmp/a \\~/a",
    }) |input| try expectRenderedHome(input, input, "/home/test");
    try expectRenderedHome("~user/a;/tmp/b //host/~/b /tmp/ok;", "~user/a;/tmp/b //host/~/b " ++ comptime linked("file:///tmp/ok", "/tmp/ok") ++ ";", "/home/test");
    try expectRenderedHome("`~/a` *~/b* **/tmp/c**\n```\n/tmp/d ~/e\n```\n", "\x1b[4m~/a\x1b[0m \x1b[3m~/b\x1b[0m \x1b[1m/tmp/c\x1b[0m\n/tmp/d ~/e\n", "/home/test");
    try expectRendered("[a](https://x y)", "[a](" ++ comptime linked("https://x", "https://x") ++ " y)");
}

test "bare local paths reject unsafe complete filenames instead of linking an ASCII prefix" {
    inline for (.{
        .{ "/tmp/a\xff;", "/tmp/a\\xff;" },
        .{ "/tmp/a\xc3;", "/tmp/a\\xc3;" },
        .{ "/tmp/a\x1b\\b;", "/tmp/a\\x1b\\b;" },
        .{ "/tmp/a\x7f;", "/tmp/a\\x7f;" },
        .{ "/tmp/a\u{0085};", "/tmp/a\\u0085;" },
        .{ "/tmp/a\u{202e};", "/tmp/a\\u202e;" },
        .{ "/tmp/a\u{2066};", "/tmp/a\\u2066;" },
    }) |case| try expectRendered(case[0] ++ " /tmp/ok;", case[1] ++ " " ++ comptime linked("file:///tmp/ok", "/tmp/ok") ++ ";");
}

test "bare local paths bound the complete encoded URI after HOME expansion" {
    const prefix = "file:///home/a%20%C3%A9/";
    const body = @as([TerminalText.max_link_bytes - prefix.len]u8, @splat('a'));
    try expectRenderedHome("~/" ++ body ++ ";", comptime linked(prefix ++ body, "~/" ++ body) ++ ";", "/home/a é");
    try expectRenderedHome("~/" ++ body ++ "a; /tmp/ok", "~/" ++ body ++ "a; " ++ comptime linked("file:///tmp/ok", "/tmp/ok"), "/home/a é");
    const absolute = "/" ++ @as([TerminalText.max_link_bytes - "file:///".len]u8, @splat('a'));
    try expectRendered(absolute ++ ";", comptime linked("file://" ++ absolute, absolute) ++ ";");
    try expectRendered(absolute ++ "a;", absolute ++ "a;");
}

test "bare local paths overflow literally through the token and resume after a delimiter" {
    const long = "/" ++ @as([TerminalText.max_link_bytes]u8, @splat('a')) ++ "/tmp/no;~/no";
    try expectRenderedHome(long ++ " /tmp/ok;", long ++ " " ++ comptime linked("file:///tmp/ok", "/tmp/ok") ++ ";", "/home/test");
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var renderer: Renderer = .{ .out = &output.writer };
    try renderer.feed("/");
    const chunk = @as([4096]u8, @splat('a'));
    for (0..32) |_| try renderer.feed(&chunk);
    try renderer.feed("/tmp/no /tmp/ok;");
    try renderer.finish();
    try std.testing.expectEqual(@as(u8, '/'), output.written()[0]);
    for (output.written()[1..][0 .. 32 * chunk.len]) |byte| try std.testing.expectEqual(@as(u8, 'a'), byte);
    try std.testing.expectEqualStrings("/tmp/no " ++ comptime linked("file:///tmp/ok", "/tmp/ok") ++ ";", output.written()[1 + 32 * chunk.len ..]);
}

test "local path filename suffixes survive trimming the sentence semicolon" {
    try expectRendered("/tmp/report_;", comptime linked("file:///tmp/report_", "/tmp/report_") ++ ";");
    try expectRendered("/tmp/backup~;", comptime linked("file:///tmp/backup~", "/tmp/backup~") ++ ";");
    try expectRendered("/tmp/name*;", comptime linked("file:///tmp/name%2A", "/tmp/name*") ++ ";");
}

test "a lone slash or tilde slash is not a local path link" {
    try expectRenderedHome("/ ~/ /; ~/;", "/ ~/ /; ~/;", "/home/test");
}

test "fence lexical delegation preserves rendered bytes and LastCode at every split" {
    const cases = [_]struct { raw: []const u8, rendered: []const u8, code: ?[]const u8 }{
        .{ .raw = "```sh\n*x*\n```\n", .rendered = "*x*\n", .code = "*x*" },
        .{ .raw = "   ```c++\n  code\n   ```", .rendered = "  code\n", .code = "  code" },
        .{ .raw = "```\n```\n", .rendered = "", .code = "" },
        .{ .raw = "```sh\nunclosed\n", .rendered = "```sh\nunclosed\n", .code = null },
        .{ .raw = "```bad info\nplain\n", .rendered = "```bad info\nplain\n", .code = null },
        .{ .raw = "```\nx\n``` \ny\n```\n", .rendered = "x\n``` \ny\n", .code = "x\n``` \ny" },
    };
    for (cases) |case| {
        try expectRendered(case.raw, case.rendered);
        for (0..case.raw.len + 1) |split| {
            var storage: [1024]u8 = undefined;
            var out = std.Io.Writer.fixed(&storage);
            var record: BlockRecorder = .{ .out = &out };
            var renderer: Renderer = .{ .out = &out, .blocks = record.sink() };
            try renderer.feed(case.raw[0..split]);
            for (case.raw[split..]) |byte| try renderer.feed(&.{byte});
            try renderer.finish();
            try std.testing.expectEqualStrings(case.rendered, out.buffered());
            try std.testing.expectEqual(@as(u6, 0), record.marks.count);
            var code: LastCode = .{};
            code.feed(case.raw[0..split]);
            code.feed(case.raw[split..]);
            if (case.code) |expected| {
                const found = code.finish().?;
                try std.testing.expectEqualStrings(expected, case.raw[@intCast(found.start)..][0..@intCast(found.length)]);
            } else try std.testing.expect(code.finish() == null);
        }
    }
}

const BlockRecorder = struct {
    out: *std.Io.Writer,
    marks: Blocks.Capture = .{},
    active: ?u5 = null,

    fn sink(self: *BlockRecorder) Blocks.Sink {
        return .{ .context = self, .event = event };
    }
    fn event(raw: *anyopaque, request: Blocks.Request) anyerror!bool {
        const self: *BlockRecorder = @ptrCast(@alignCast(raw));
        switch (request) {
            .begin_table => |table| {
                std.debug.assert(self.active == null);
                if (!self.marks.reserve(.{ .start = self.out.end, .end = self.out.end, .data = .{ .table = table.columns } })) return false;
                self.active = @intCast(self.marks.count - 1);
                try self.out.writeAll(table.header);
                self.marks.items[self.active.?].header_end = self.out.end;
                try self.out.writeAll(table.delimiter);
                self.marks.items[self.active.?].delimiter_end = self.out.end;
                self.marks.items[self.active.?].complete_end = self.out.end;
                self.marks.items[self.active.?].end = self.out.end;
            },
            .table_row => |row| {
                try self.out.writeAll(row);
                self.marks.items[self.active.?].end = self.out.end;
                self.marks.items[self.active.?].complete_end = self.out.end;
            },
            .end_table => self.active = null,
            .quote => |quote| if (quote) |value| {
                if (!self.marks.reserve(.{ .start = self.out.end, .end = self.out.end, .data = .{ .quote = value } })) return false;
                self.active = @intCast(self.marks.count - 1);
            } else {
                self.marks.items[self.active.?].end = self.out.end;
                self.active = null;
            },
        }
        return true;
    }
};

test "typed pre-inline table custody is exact at every feed split and real EOF" {
    const table = "head|other\n:---|---:\na|\x1b[31m\xff\nfinal|row";
    for (0..table.len + 1) |split| {
        var storage: [8192]u8 = undefined;
        var out = std.Io.Writer.fixed(&storage);
        var record: BlockRecorder = .{ .out = &out };
        var renderer: Renderer = .{ .out = &out, .blocks = record.sink() };
        try renderer.feed(table[0..split]);
        try renderer.feed(table[split..]);
        try renderer.finish();
        try std.testing.expectEqualStrings(table, out.buffered());
        try std.testing.expectEqual(@as(u6, 1), record.marks.count);
        const block = record.marks.items[0];
        try std.testing.expect(block.data == .table);
        try std.testing.expectEqual(@as(u64, table.len), block.complete_end);
        try std.testing.expectEqual(@as(u64, "head|other\n".len), block.header_end);
        try std.testing.expectEqual(@as(u64, "head|other\n:---|---:\n".len), block.delimiter_end);
    }
}

test "typed pre-inline rejected candidates preserve legacy inline replay and strict fences" {
    const cases = [_][]const u8{
        "plain paragraph\nnot a delimiter\n",
        "# heading\n**bold** and *emphasis*\n",
        "[label](https://example.test) **after**\nplain\n",
        "https://example.test/path *after*\nnext line\n",
        "```zig\n> code\n```\n",
        "````\n> **literal**\n````\n",
        "one column\n---\n",
    };
    for (cases[0 .. cases.len - 2]) |input| {
        var expected_storage: [8192]u8 = undefined;
        var expected = std.Io.Writer.fixed(&expected_storage);
        var legacy: Renderer = .{ .out = &expected };
        try legacy.feed(input);
        try legacy.finish();
        for (0..input.len + 1) |split| {
            var storage: [8192]u8 = undefined;
            var out = std.Io.Writer.fixed(&storage);
            var record: BlockRecorder = .{ .out = &out };
            var renderer: Renderer = .{ .out = &out, .blocks = record.sink() };
            try renderer.feed(input[0..split]);
            try renderer.feed(input[split..]);
            try renderer.finish();
            try std.testing.expectEqualStrings(expected.buffered(), out.buffered());
            try std.testing.expectEqual(@as(u6, 0), record.marks.count);
        }
    }
    try std.testing.expect(@sizeOf(Renderer) <= 5 * 1024);
    std.debug.print("typed Renderer={d} bytes; context={d} bytes\n", .{ @sizeOf(Renderer), @sizeOf(Markdown.Context) });
}

test "typed pre-inline shared opacity prevents false tables and greedy quoted code depth" {
    const input = "~~~~\nhead|other\n---|---\n> code\n~~~~\n> quote\n";
    for (0..input.len + 1) |split| {
        var storage: [8192]u8 = undefined;
        var out = std.Io.Writer.fixed(&storage);
        var record: BlockRecorder = .{ .out = &out };
        var renderer: Renderer = .{ .out = &out, .blocks = record.sink() };
        try renderer.feed(input[0..split]);
        try renderer.feed(input[split..]);
        try renderer.finish();
        try std.testing.expectEqualStrings(input, out.buffered());
        try std.testing.expectEqual(@as(u6, 1), record.marks.count);
        try std.testing.expectEqual(@as(u4, 1), record.marks.items[0].data.quote.depth);
    }
}

test "typed pre-inline tiny-row traversal cost is bounded at retained capacity" {
    var source: [240 * 1024]u8 = undefined;
    var raw = std.Io.Writer.fixed(&source);
    try raw.writeAll("h|x\n---|---\n");
    while (raw.buffer.len - raw.end >= 4) try raw.writeAll("a|b\n");
    var storage: [source.len]u8 = undefined;
    const before = std.Io.Clock.awake.now(std.testing.io);
    for (0..3) |_| {
        var out = std.Io.Writer.fixed(&storage);
        var legacy: Renderer = .{ .out = &out };
        try legacy.feed(raw.buffered());
        try legacy.finish();
        try std.testing.expectEqualStrings(raw.buffered(), out.buffered());
    }
    const middle = std.Io.Clock.awake.now(std.testing.io);
    for (0..3) |_| {
        var out = std.Io.Writer.fixed(&storage);
        var record: BlockRecorder = .{ .out = &out };
        var renderer: Renderer = .{ .out = &out, .blocks = record.sink() };
        try renderer.feed(raw.buffered());
        try renderer.finish();
        try std.testing.expectEqualStrings(raw.buffered(), out.buffered());
        try std.testing.expectEqual(@as(u6, 1), record.marks.count);
        try std.testing.expectEqual(@as(u64, raw.end), record.marks.items[0].complete_end);
    }
    const after = std.Io.Clock.awake.now(std.testing.io);
    std.debug.print("typed capture tiny-row 240KiB legacy={d}ns typed={d}ns /3; one block, {d} source bytes\n", .{ middle.nanoseconds - before.nanoseconds, after.nanoseconds - middle.nanoseconds, raw.end });
}

test "typed pre-inline deterministic fence cap and conservative container closure" {
    const cases = [_]struct { input: []const u8, quotes: u6 }{
        .{ .input = @as([128]u8, @splat('`')) ++ "\n> hidden\n```\n> still hidden\n", .quotes = 0 },
        .{ .input = @as([127]u8, @splat('`')) ++ "\n> hidden\n" ++ @as([127]u8, @splat('`')) ++ "\n> shown\n", .quotes = 1 },
        .{ .input = "> ~~~~\n> > code\nmissing outer\n> ~~~~\n>> shown\n", .quotes = 4 },
        .{ .input = "~~~~\n> hidden\n~~~~ \t\r\n> shown\n", .quotes = 1 },
        .{ .input = "~~~~\n> hidden\n~~~~\r", .quotes = 0 },
    };
    for (cases) |case| for (0..case.input.len + 1) |split| {
        var storage: [8192]u8 = undefined;
        var out = std.Io.Writer.fixed(&storage);
        var record: BlockRecorder = .{ .out = &out };
        var renderer: Renderer = .{ .out = &out, .blocks = record.sink() };
        try renderer.feed(case.input[0..split]);
        try renderer.feed(case.input[split..]);
        try renderer.finish();
        try std.testing.expectEqual(case.quotes, record.marks.count);
        for (record.marks.slice()) |mark| try std.testing.expect(mark.data == .quote);
        if (case.quotes == 4) {
            try std.testing.expectEqual(@as(u4, 1), record.marks.items[1].data.quote.depth);
            try std.testing.expectEqual(@as(u4, 2), record.marks.items[3].data.quote.depth);
        }
    };
}

test "typed candidate overflow replays aliased link source without an extra held buffer" {
    var source: [2 * fence_limit + 256]u8 = undefined;
    var text = std.Io.Writer.fixed(&source);
    try text.writeAll("[label](https://example.test) ");
    while (text.end < fence_limit - 4) try text.writeByte('x');
    try text.writeAll("\n[second](https://other.test) ");
    while (text.end < 2 * fence_limit + 10) try text.writeByte('y');
    try text.writeAll("\n```zig\ncode\n```\n");
    var expected_storage: [source.len + 512]u8 = undefined;
    var expected = std.Io.Writer.fixed(&expected_storage);
    var legacy: Renderer = .{ .out = &expected };
    try legacy.feed(text.buffered());
    try legacy.finish();
    for ([_]usize{ 0, 1, 127, fence_limit - 1, fence_limit, fence_limit + 1, text.end }) |split| {
        var storage: [source.len + 512]u8 = undefined;
        var out = std.Io.Writer.fixed(&storage);
        var record: BlockRecorder = .{ .out = &out };
        var renderer: Renderer = .{ .out = &out, .blocks = record.sink() };
        try renderer.feed(text.buffered()[0..split]);
        try renderer.feed(text.buffered()[split..]);
        try renderer.finish();
        try std.testing.expectEqualStrings(expected.buffered(), out.buffered());
        try std.testing.expectEqual(@as(u6, 0), record.marks.count);
    }
}

test "typed table admission shares row grammar for CRLF escaped pipes code and explicit one-column EOF" {
    const cases = [_]struct { source: []const u8, columns: u4 }{
        .{ .source = "| h | x |\r\n| :--- | ---: |\r\n| `a|b` | c\\|d |\r\n", .columns = 2 },
        .{ .source = "heading\n| --- |", .columns = 1 },
        .{ .source = "a|b|c|d|e|f|g|h\n---|---|---|---|---|---|---|---\n1|2|3|4|5|6|7|8", .columns = 8 },
    };
    for (cases) |case| for (0..case.source.len + 1) |split| {
        var storage: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&storage);
        var record: BlockRecorder = .{ .out = &out };
        var renderer: Renderer = .{ .out = &out, .blocks = record.sink() };
        try renderer.feed(case.source[0..split]);
        try renderer.feed(case.source[split..]);
        try renderer.finish();
        try std.testing.expectEqualStrings(case.source, out.buffered());
        try std.testing.expectEqual(@as(u6, 1), record.marks.count);
        try std.testing.expectEqual(case.columns, record.marks.items[0].data.table.count);
        try std.testing.expectEqual(@as(u64, case.source.len), record.marks.items[0].complete_end);
    };
}

test "typed quote scope contains pending EOF prefix inline links and terminal escapes" {
    const cases = [_][]const u8{ ">", "> ", "> x", "> **x**", "> *x*", "> `x`", "> [x](https://example.test)", "> https://example.test", "> > **x**", "> \x1b[31m", "> \xc3" };
    for (cases) |source| for ([_][]const u8{ "", "\n" }) |ending| {
        var input: [256]u8 = undefined;
        @memcpy(input[0..source.len], source);
        @memcpy(input[source.len..][0..ending.len], ending);
        const raw = input[0 .. source.len + ending.len];
        var expected_storage: [1024]u8 = undefined;
        var expected = std.Io.Writer.fixed(&expected_storage);
        var legacy: Renderer = .{ .out = &expected };
        try legacy.feed(raw);
        try legacy.finish();
        for (0..raw.len + 1) |split| {
            var storage: [1024]u8 = undefined;
            var out = std.Io.Writer.fixed(&storage);
            var record: BlockRecorder = .{ .out = &out };
            var renderer: Renderer = .{ .out = &out, .blocks = record.sink() };
            try renderer.feed(raw[0..split]);
            for (raw[split..]) |byte| try renderer.feed(&.{byte});
            try renderer.finish();
            try std.testing.expectEqualStrings(expected.buffered(), out.buffered());
            try std.testing.expectEqual(@as(u6, 1), record.marks.count);
            try std.testing.expectEqual(@as(u64, 0), record.marks.items[0].start);
            try std.testing.expectEqual(@as(u64, out.end), record.marks.items[0].end);
            try std.testing.expect(record.active == null);
        }
    };
}

test "typed opacity-only opener info remains safe literal at every split and ending" {
    const cases = [_][]const u8{ "~~~ **x**", "~~~~ [x](https://example.test)", "~~~ \x1b[31m\xff", "~~~ `x`", "~~~ \xe2\x80\xae", "~~~", "  ~~~ **x**", "```` **x**", "``` [x](https://example.test)", "```` \x1b[31m" };
    for (cases) |source| for ([_][]const u8{ "", "\n> code\n~~~\n" }) |ending| {
        var input: [256]u8 = undefined;
        @memcpy(input[0..source.len], source);
        @memcpy(input[source.len..][0..ending.len], ending);
        const raw = input[0 .. source.len + ending.len];
        var expected_storage: [1024]u8 = undefined;
        var expected = std.Io.Writer.fixed(&expected_storage);
        var safe_text: TerminalText = .{ .mode = .multiline };
        try safe_text.feed(&expected, raw);
        try safe_text.finish(&expected);
        for (0..raw.len + 1) |split| {
            var storage: [1024]u8 = undefined;
            var out = std.Io.Writer.fixed(&storage);
            var record: BlockRecorder = .{ .out = &out };
            var renderer: Renderer = .{ .out = &out, .blocks = record.sink() };
            try renderer.feed(raw[0..split]);
            for (raw[split..]) |byte| try renderer.feed(&.{byte});
            try renderer.finish();
            try std.testing.expectEqualStrings(expected.buffered(), out.buffered());
            try std.testing.expectEqual(@as(u6, 0), record.marks.count);
        }
    };
}

test "typed quoted fence EOF scopes keep exact outer depth and literal source" {
    for ([_][]const u8{ "", "\n" }) |ending| {
        const source = "> > ```zig\n> > **literal**\n> > ```";
        var input: [128]u8 = undefined;
        @memcpy(input[0..source.len], source);
        @memcpy(input[source.len..][0..ending.len], ending);
        const raw = input[0 .. source.len + ending.len];
        for (0..raw.len + 1) |split| {
            var storage: [1024]u8 = undefined;
            var out = std.Io.Writer.fixed(&storage);
            var record: BlockRecorder = .{ .out = &out };
            var renderer: Renderer = .{ .out = &out, .blocks = record.sink() };
            try renderer.feed(raw[0..split]);
            try renderer.feed(raw[split..]);
            try renderer.finish();
            try std.testing.expectEqualStrings(raw, out.buffered());
            try std.testing.expectEqual(@as(u6, 3), record.marks.count);
            var start: u64 = 0;
            for (record.marks.slice()) |mark| {
                try std.testing.expectEqual(start, mark.start);
                try std.testing.expectEqual(@as(u4, 2), mark.data.quote.depth);
                start = mark.end;
            }
            try std.testing.expectEqual(@as(u64, out.end), start);
        }
    }
}

test "null capability retains legacy tilde info formatting" {
    try expectRendered("~~~ **x**\n> code\n~~~\n", "~~~ \x1b[1mx\x1b[0m\n> code\n~~~\n");
    try expectRendered("~~~ [x](https://example.test)", comptime "~~~ " ++ linked("https://example.test", "x"));
}
