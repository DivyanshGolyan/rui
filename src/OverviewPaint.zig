//! Direct overview cells in the invocation RenderBackend; no retained projection or ANSI encoder.
const view = @import("overview_view.zig");
const vaxis = @import("vaxis");
const std = @import("std");
const session_line = @import("session_line.zig");
const attention = @import("attention.zig");
const shortPath = @import("home_path.zig").shortPath;
const draft_layout = @import("draft_layout.zig");
const model_picker = @import("model_picker.zig");
const slash_commands = @import("slash_commands.zig");
pub const commands = slash_commands.overview;
const TerminalText = @import("TerminalText.zig");
const work_line = @import("work_line.zig");
const unicode = @import("terminal_unicode");
const gwidth = @import("terminal_width");

const Allocator = std.mem.Allocator;
const Reference = view.Reference;

const Action = view.Action;
const Band = view.Band;
const Caps = view.Caps;
const Colour = view.Colour;
const Draft = view.Draft;
const Group = view.Group;
const Host = view.Host;
const Line = view.Line;
const ListLines = view.ListLines;
const Panel = view.Panel;
const Picker = view.Picker;
const Provider = view.Provider;
const Row = view.Row;
const Rule = view.Rule;
const State = view.State;
const Style = view.Style;
const ago = view.Test.ago;
const band = view.band;
const choose = view.Test.choose;
const conversation = view.conversation;
const grouped = view.grouped;
const groups = view.groups;
const hintRows = view.hintRows;
const indexed = view.indexed;
const layout = view.layout;
const marks = view.marks;
const max_label_bytes = view.max_label_bytes;
const nextCommands = view.nextCommands;
const palettes = view.palettes;
const pickerFit = view.pickerFit;
const pickerItems = view.pickerItems;
const pickerNote = view.pickerNote;
const position = view.position;
const rules = view.rules;
const shownKind = view.shownKind;
const spinner = view.spinner;
const step = view.step;
const stop_prompt = view.stop_prompt;
const stoppable = view.stoppable;
const title = view.title;
const topRows = view.topRows;
const workLine = view.workLine;
const writeSettings = view.writeSettings;

const Glyphs = struct { prompt: []const u8, dot: []const u8, rule: []const u8, ellipsis: []const u8, arrows: []const u8, sides: []const u8, up: []const u8, down: []const u8, newline: []const u8 };
const unicode_glyphs: Glyphs = .{ .prompt = "›", .dot = work_line.glyphs.get(.unicode).dot, .rule = "─", .ellipsis = work_line.glyphs.get(.unicode).ellipsis, .arrows = "↑↓", .sides = "←→", .up = "↑", .down = "↓", .newline = "↵" };
const ascii_glyphs: Glyphs = .{ .prompt = ">", .dot = work_line.glyphs.get(.ascii).dot, .rule = "-", .ellipsis = work_line.glyphs.get(.ascii).ellipsis, .arrows = "^v", .sides = "<>", .up = "^", .down = "v", .newline = "|" };

/// Facts the shell adopts for its next input, with no retained screen payload.
pub const Drawn = struct {
    draft_anchor: usize = 0,
    commands: ?slash_commands.Shown = null,
    spins: bool = false,
};

/// Paint directly into the invocation backend's current grid. No I/O, output
/// receipts, selection offset, second screen, or diff cache lives here.
pub fn draw(window: vaxis.Window, scratch: Allocator, state: *const State, draft: Draft, caps: Caps, frame: u64) error{OutOfMemory}!Drawn {
    const width = state.size.width;
    const height = state.size.height;
    std.debug.assert(width <= window.width and height <= window.height);
    var result: Drawn = .{};
    window.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = cellStyle(caps, .{}) });
    window.hideCursor();
    if (height == 0 or width == 0) return result;
    var painter: RowPaint = .{ .arena = scratch, .caps = caps, .glyphs = if (caps.unicode) unicode_glyphs else ascii_glyphs, .window = window, .width = width, .frame = frame };
    painter.at(0);
    try header(&painter, state);
    var count: u16 = 1;
    var buffer: [16]u8 = undefined;
    if (state.unreachable_since_ms) |since| {
        if (count < height) {
            painter.at(count);
            try bandLine(&painter, try std.fmt.allocPrint(scratch, "Host stopped {s} ago. Run rui host start.", .{spanText(&buffer, (state.now_ms -| since) / 1000)}));
        }
        count += 1;
    }
    if (band(state.rows.items, state.now_ms, state.login_at)) |trouble| {
        if (count < height) {
            painter.at(count);
            try providerBand(&painter, trouble, state.now_ms);
        }
        count += 1;
    }
    if (count == 1) {
        if (count < height) {
            painter.at(count);
            try headline(&painter, state);
        }
        count += 1;
    }
    if (count < height) {
        painter.at(count);
        try healthLine(&painter, state);
    }
    count += 1;
    std.debug.assert(count == topRows(state));
    var input: ComposerLayout = undefined;
    const fits = height >= 6 and width >= 6;
    if (fits) input.plan(&painter, draft, height);
    std.debug.assert(state.picker == null or draft.bytes.len == 0);
    result.commands = nextCommands(state, draft);
    const at = layout(state, if (fits) @intCast(input.view.rows) else 0, if (result.commands) |shown| shown.rows() else 0);
    if (result.commands) |*shown| shown.drew(at.commands.len() != 0);
    if (fits) {
        painter.at(at.input);
        try ruleLine(&painter, input.view);
        if (at.commands.len() != 0) try commandLines(&painter, &result.commands.?, at.commands);
        const hinted = height - hintRows(state);
        try composer(&painter, state, draft, &input, .{ .start = at.commands.end, .end = hinted });
        painter.at(hinted);
        try hints(&painter, state, draft, at.commands.len() != 0);
        if (hinted + 1 < height) {
            const notice = &state.notice.?;
            var rest = std.mem.splitScalar(u8, notice.text(), '\n');
            _ = rest.next();
            for (hinted + 1..height) |row| {
                painter.at(@intCast(row));
                painter.begin(false);
                _ = try painter.put(1, rest.next().?, width -| 2, .{ .colour = notice.colour });
                try painter.finish();
            }
        }
        result.draft_anchor = input.lines[0].start;
        if (state.inputMode() == .compose) window.showCursor(@intCast(@min(width - 1, 3 + input.shape.caret_column)), @intCast(at.commands.end + input.shape.caret_line - input.view.first));
    }
    if (at.picker.len() != 0) try pickerLines(&painter, state, &state.picker.?, at.picker);
    if (at.list.len() != 0) {
        if (state.panel) |*panel| try panelLines(&painter, panel, at.list) else try list(&painter, state, at.list);
    }
    result.spins = painter.spun;
    return result;
}

/// The domain owns the skin and indexed palette; the backend only enforces
/// the chosen colour depth. NO_COLOR keeps this overview's own emphasis.
fn cellStyle(caps: Caps, wanted: Style) vaxis.Style {
    const palette = view.palettes.get(caps.skin());
    return .{
        .fg = switch (caps.depth) {
            .none => .default,
            .indexed => .{ .index = view.indexed.get(caps.skin()).colours.get(wanted.colour) },
            .direct => .{ .rgb = palette.colours.get(wanted.colour) },
        },
        .bg = switch (caps.depth) {
            .none => .default,
            .indexed => .{ .index = view.indexed.get(caps.skin()).backgrounds.get(wanted.background) },
            .direct => .{ .rgb = palette.backgrounds.get(wanted.background) },
        },
        .bold = wanted.bold,
        .reverse = wanted.reverse,
    };
}

/// One row per entry, as a conversation lists them: its text, then its
/// description, quiet, at one column, the highlighted row on the selection
/// ground. When more match than rows fit, the last row counts the rest and
/// the rows follow the highlight.
fn commandLines(painter: *RowPaint, drawn: *const slash_commands.Shown, lines: view.Layout.Rows) error{OutOfMemory}!void {
    const listed = &drawn.list;
    const highlight = drawn.highlight;
    const shown = slash_commands.named(listed.count, lines.len());
    const first = listed.firstShown(highlight, lines.len());
    const room = painter.width -| 2;
    const column = listed.descriptionColumn();
    for (listed.shown()[first..][0..shown], first.., lines.start..) |entry, index, row| {
        painter.at(@intCast(row));
        painter.begin(index == highlight);
        _ = try painter.put(1, entry.shown, room, .{ .colour = .strong });
        if (entry.description.len != 0 and room > column) _ = try painter.put(1 + column, entry.description, room - column, .{ .colour = .quiet });
        try painter.finish();
    }
    if (shown == lines.len()) return;
    painter.at(@intCast(lines.start + shown));
    painter.begin(false);
    _ = try painter.put(1, try std.fmt.allocPrint(painter.arena, slash_commands.more, .{listed.count - shown}), room, .{ .colour = .quiet });
    try painter.finish();
}
/// A single direct row in the borrowed vaxis window. Source bytes are cleaned
/// into charged frame scratch and stay alive through backend.encode().
const RowPaint = struct {
    arena: Allocator,
    caps: Caps,
    glyphs: Glyphs,
    window: vaxis.Window,
    width: u16,
    row: u16 = 0,
    frame: u64,
    spun: bool = false,
    column: usize = 0,
    selected: bool = false,

    fn script(self: *const RowPaint) work_line.Script {
        return if (self.caps.unicode) .unicode else .ascii;
    }
    fn at(self: *RowPaint, row: u16) void {
        self.row = row;
    }
    fn begin(self: *RowPaint, selected: bool) void {
        self.column = 0;
        self.selected = selected;
    }
    fn finish(self: *RowPaint) error{OutOfMemory}!void {
        if (self.selected) try self.pad(self.width -| self.inset(), .{});
    }
    fn inset(self: *const RowPaint) usize {
        return @intFromBool(self.caps.depth != .none);
    }
    fn style(self: *const RowPaint, wanted: Style) Style {
        var result = wanted;
        if (self.selected) result.background = .selection;
        if (self.caps.depth == .none) return .{
            .bold = result.bold or result.background == .band,
            .reverse = result.background == .band or result.background == .selection,
        };
        return result;
    }
    fn pad(self: *RowPaint, column: usize, wanted: Style) error{OutOfMemory}!void {
        const to = @min(column, self.width);
        if (to <= self.column) return;
        const drawn = self.style(wanted);
        if (self.selected and self.column == 0) self.column = self.inset();
        if (to > self.column and (drawn.reverse or drawn.background != .ground)) {
            const blank = try self.arena.alloc(u8, to - self.column);
            @memset(blank, ' ');
            self.push(blank, to - self.column, wanted);
        }
        self.column = to;
    }
    fn push(self: *RowPaint, bytes: []const u8, cells: usize, wanted: Style) void {
        if (cells == 0) return;
        const row = self.window.child(.{ .y_off = self.row, .height = 1 });
        _ = row.printSegment(.{ .text = bytes, .style = cellStyle(self.caps, self.style(wanted)) }, .{ .col_offset = @intCast(self.column), .wrap = .none });
        self.column += cells;
    }
    /// Puts `bytes` at `column` within `limit` cells, ending in an ellipsis
    /// when cut. Returns the cells it took.
    fn put(self: *RowPaint, column: usize, bytes: []const u8, limit: usize, wanted: Style) error{OutOfMemory}!usize {
        try self.pad(column, wanted);
        const room = @min(limit, self.width -| self.column);
        if (room == 0) return 0;
        const shown = try self.clean(bytes, room, .head);
        self.push(shown.bytes, shown.cells, wanted);
        return shown.cells;
    }

    /// Like `put`, keeping the end of `bytes` when it is cut.
    fn putTail(self: *RowPaint, column: usize, bytes: []const u8, limit: usize, wanted: Style) error{OutOfMemory}!usize {
        try self.pad(column, wanted);
        const room = @min(limit, self.width -| self.column);
        if (room == 0) return 0;
        const shown = try self.clean(bytes, room, .tail);
        self.push(shown.bytes, shown.cells, wanted);
        return shown.cells;
    }

    /// Puts `bytes` so they end at `end`.
    fn putRight(self: *RowPaint, end: usize, bytes: []const u8, wanted: Style) error{OutOfMemory}!void {
        const cells = self.measure(bytes);
        if (cells > end or end - cells < self.column) return;
        _ = try self.put(end - cells, bytes, cells, wanted);
    }

    /// Terminal-safe text clipped to `room` cells, as `Pieces` shows it.
    fn clean(self: *RowPaint, bytes: []const u8, room: usize, keep: enum { head, tail }) error{OutOfMemory}!Piece {
        const total = self.measure(bytes);
        const ellipsis = self.glyphs.ellipsis;
        const budget = if (total <= room) total else room - 1;
        var out = try self.arena.alloc(u8, bytes.len * 3 + ellipsis.len);
        var used: usize = 0;
        var cells: usize = 0;
        if (keep == .tail and total > room) {
            @memcpy(out[0..ellipsis.len], ellipsis);
            used = ellipsis.len;
        }
        var skip = if (keep == .tail) total - budget else 0;
        var pieces: Pieces = .{ .bytes = bytes, .painter = self };
        while (pieces.next()) |piece| {
            if (skip > 0) {
                skip -|= piece.cells;
                continue;
            }
            if (cells + piece.cells > budget) break;
            @memcpy(out[used..][0..piece.bytes.len], piece.bytes);
            used += piece.bytes.len;
            cells += piece.cells;
        }
        if (keep == .head and total > room) {
            @memcpy(out[used..][0..ellipsis.len], ellipsis);
            used += ellipsis.len;
        }
        return .{ .bytes = out[0..used], .cells = cells + @intFromBool(total > room) };
    }

    fn measure(self: *const RowPaint, bytes: []const u8) usize {
        var total: usize = 0;
        var pieces: Pieces = .{ .bytes = bytes, .painter = self };
        while (pieces.next()) |piece| total += piece.cells;
        return total;
    }

    /// The glyph shown for a code point that cannot reach the terminal: a
    /// control character or an invalid byte, or without Unicode anything
    /// past ASCII.
    fn standIn(self: *const RowPaint, codepoint: u21) ?[]const u8 {
        if (codepoint == '\n') return self.glyphs.newline;
        // A tab shows as one space, as in a conversation.
        if (codepoint == '\t') return " ";
        if (TerminalText.isControl(codepoint) or codepoint == replacement) return "?";
        if (!self.caps.unicode and codepoint > 0x7e) return "?";
        return null;
    }
};

const Piece = struct { bytes: []const u8, cells: usize };

/// Text as the terminal draws it: whole grapheme clusters, measured as the
/// terminal measures them, with a one-cell stand-in for each code point
/// that cannot reach it.
const Pieces = struct {
    bytes: []const u8,
    painter: *const RowPaint,
    at: usize = 0,

    fn next(self: *Pieces) ?Piece {
        if (self.at == self.bytes.len) return null;
        const rest = self.bytes[self.at..];
        const first = decode(rest);
        if (self.painter.standIn(first.codepoint)) |glyph| {
            self.at += first.len;
            return .{ .bytes = glyph, .cells = 1 };
        }
        // Printable ASCII before ASCII or the end is a whole cluster of one
        // cell under every method; this keeps long ASCII text cheap.
        if (!self.painter.caps.unicode or (first.codepoint < 0x80 and (rest.len == 1 or rest[1] < 0x80))) {
            self.at += 1;
            return .{ .bytes = rest[0..1], .cells = 1 };
        }
        var clusters = unicode.graphemeIterator(rest);
        const cluster = clusters.next().?.len;
        var end = first.len;
        while (end < cluster) {
            const decoded = decode(rest[end..]);
            if (self.painter.standIn(decoded.codepoint) != null) break;
            end += decoded.len;
        }
        self.at += end;
        return .{ .bytes = rest[0..end], .cells = gwidth.gwidth(rest[0..end], self.painter.caps.width) };
    }
};

const replacement = 0xfffd;

/// One UTF-8 code point; an invalid byte decodes alone as U+FFFD.
fn decode(bytes: []const u8) struct { codepoint: u21, len: usize } {
    const first = bytes[0];
    const len: usize = switch (first) {
        0x00...0x7f => return .{ .codepoint = first, .len = 1 },
        0xc2...0xdf => 2,
        0xe0...0xef => 3,
        0xf0...0xf4 => 4,
        else => return .{ .codepoint = replacement, .len = 1 },
    };
    if (bytes.len < len or !std.unicode.utf8ValidateSlice(bytes[0..len])) return .{ .codepoint = replacement, .len = 1 };
    var codepoint: u21 = first & (@as(u8, 0x7f) >> @intCast(len));
    for (bytes[1..len]) |byte| codepoint = codepoint << 6 | (byte & 0x3f);
    return .{ .codepoint = codepoint, .len = len };
}

fn header(painter: *RowPaint, state: *const State) error{OutOfMemory}!void {
    painter.begin(false);
    const bar: Style = .{ .colour = .strong, .background = .bar, .bold = true };
    var column: usize = 1;
    // रुई beside rui, as on a station board; ASCII has rui alone.
    if (painter.caps.unicode) column += try painter.put(column, "रुई", painter.width, bar) + 1;
    column += try painter.put(column, "rui", 3, bar) + 2;
    const path = shortPath(state.home, state.workspaces.items[state.cwd]);
    const joined = try std.mem.concat(painter.arena, u8, &.{ path.prefix, path.rest });
    _ = try painter.putTail(column, joined, painter.width -| column -| 1, .{ .background = .bar });
    try painter.pad(painter.width, .{ .background = .bar });
    return painter.finish();
}

/// One sentence under the title: whether anything works, and what needs
/// the person.
fn headline(painter: *RowPaint, state: *const State) error{OutOfMemory}!void {
    painter.begin(false);
    if (state.listed_at_ms == null) {
        _ = try painter.put(1, try std.fmt.allocPrint(painter.arena, "Loading{s}", .{painter.glyphs.ellipsis}), painter.width -| 2, .{ .colour = .quiet });
        return painter.finish();
    }
    if (state.rows.items.len == 0) {
        _ = try painter.put(1, "No Sessions yet. Type a task below.", painter.width -| 2, .{ .colour = .quiet });
        return painter.finish();
    }
    var span: [16]u8 = undefined;
    var number: [32]u8 = undefined;
    const summary = state.summary;
    const failed = state.summary.failed;
    const yours = state.runs.get(.yours).len;
    const sessions = state.rows.items.len;
    // Failures are counted. Waits for approval are not named, but they
    // keep the sentence from claiming calm; they count as working.
    const opening = if (summary.working) "Running." else try std.fmt.allocPrint(painter.arena, "Quiet for {s}.", .{spanText(&span, (state.now_ms / 1000) -| summary.latest)});
    const rest = if (summary.working)
        try std.fmt.allocPrint(painter.arena, "{s} Session{s}.{s}", .{ grouped(&number, sessions), if (sessions == 1) "" else "s", if (failed != 0 or summary.approvals != 0) "" else " Nothing needs you." })
    else if (failed != 0)
        ""
    else if (yours == 1 and summary.answered)
        "Your conversation has answered."
    else if (yours != 0 and summary.answered)
        try std.fmt.allocPrint(painter.arena, "All {s} of your conversations have answered.", .{grouped(&number, yours)})
    else
        "Nothing is working or waiting.";
    var failures: [32]u8 = undefined;
    const tail = if (failed == 0) rest else try std.fmt.allocPrint(painter.arena, "{s}{s}{s} failed.", .{ rest, if (rest.len == 0) "" else " ", grouped(&failures, failed) });
    const used = try painter.put(1, opening, painter.width -| 2, .{ .colour = .strong, .bold = true });
    _ = try painter.put(2 + used, tail, painter.width -| used -| 3, .{});
    return painter.finish();
}

fn healthLine(painter: *RowPaint, state: *const State) error{OutOfMemory}!void {
    painter.begin(false);
    var span: [16]u8 = undefined;
    var column: usize = 1;
    if (state.unreachable_since_ms != null) {
        const text = if (state.listed_at_ms) |at|
            try std.fmt.allocPrint(painter.arena, "Host not responding. Last update {s} ago.", .{spanText(&span, (state.now_ms -| at) / 1000)})
        else
            "Host not responding.";
        column += try painter.put(column, text, painter.width -| column -| 1, .{ .colour = .failure }) + 3;
    } else if (state.host) |host| {
        const text = try std.fmt.allocPrint(painter.arena, "Host up {s}", .{spanText(&span, (state.now_ms / 1000) -| host.started_at)});
        column += try painter.put(column, text, painter.width -| column -| 1, .{}) + 3;
    }
    if (state.host) |host| {
        const text = try std.fmt.allocPrint(painter.arena, "slots {d}/{d}", .{ host.slots_in_use, host.slots });
        _ = try painter.put(column, text, painter.width -| column -| 1, .{ .colour = if (host.slots_in_use >= host.slots) .ink else .normal });
    }
    return painter.finish();
}

/// A full-width alarm line, dark on yellow.
fn bandLine(painter: *RowPaint, text: []const u8) error{OutOfMemory}!void {
    painter.begin(false);
    const style: Style = .{ .colour = .on_band, .background = .band, .bold = true };
    try painter.pad(1, style);
    _ = try painter.put(1, text, painter.width -| 2, style);
    try painter.pad(painter.width, style);
    return painter.finish();
}

fn providerBand(painter: *RowPaint, trouble: Band, now_ms: u64) error{OutOfMemory}!void {
    var buffer: [8]u8 = undefined;
    return bandLine(painter, switch (trouble.trouble) {
        // A row does not carry its provider, so each names the one provider
        // with that kind of credential.
        .sign_in => "Sign-in expired. Run " ++ comptime Provider.onlyWith(.sign_in).login() ++ ".",
        .api_key => comptime Provider.onlyWith(.api_key).shown() ++ " API key rejected. Run " ++ Provider.onlyWith(.api_key).login() ++ ", then rui host pause.",
        .quota => if (trouble.resets_at) |at|
            try std.fmt.allocPrint(painter.arena, "Quota used up. Resets in {s}.", .{ageText(&buffer, at -| now_ms / 1000)})
        else
            "Quota used up.",
        .rate_limit => try std.fmt.allocPrint(painter.arena, "Rate limited. {d} Session{s} will retry.", .{ trouble.sessions, if (trouble.sessions == 1) "" else "s" }),
    });
}

/// A duration on the top lines: 42s, 7m, 2h05m, 3d04h.
fn spanText(buffer: *[16]u8, seconds: u64) []const u8 {
    if (seconds < 60) return std.fmt.bufPrint(buffer, "{d}s", .{seconds}) catch unreachable;
    if (seconds < 3600) return std.fmt.bufPrint(buffer, "{d}m", .{seconds / 60}) catch unreachable;
    if (seconds < 86400) return std.fmt.bufPrint(buffer, "{d}h{d:0>2}m", .{ seconds / 3600, seconds % 3600 / 60 }) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d}d{d:0>2}h", .{ @min(seconds / 86400, 99999), seconds % 86400 / 3600 }) catch unreachable;
}

/// The rule above the composer. It names the draft lines hidden above or
/// below the composer when there are any.
fn ruleLine(painter: *RowPaint, viewport: draft_layout.View) error{OutOfMemory}!void {
    painter.begin(false);
    const cells = painter.width -| 2;
    var buffer: [64]u8 = undefined;
    const label = draft_layout.label(&buffer, viewport, .{ .up = painter.glyphs.up, .down = painter.glyphs.down, .dot = painter.glyphs.dot });
    const label_cells = painter.measure(label);
    try painter.pad(1, .{});
    const left = draft_layout.labelColumn(label_cells, cells) orelse {
        try ruleRun(painter, cells);
        return painter.finish();
    };
    try ruleRun(painter, left);
    _ = try painter.put(1 + left, label, label_cells, .{ .colour = .quiet });
    try ruleRun(painter, cells - left - label_cells);
    return painter.finish();
}

fn ruleRun(painter: *RowPaint, cells: usize) error{OutOfMemory}!void {
    if (cells == 0) return;
    const text = try painter.arena.alloc(u8, cells * painter.glyphs.rule.len);
    for (0..cells) |at| @memcpy(text[at * painter.glyphs.rule.len ..][0..painter.glyphs.rule.len], painter.glyphs.rule);
    painter.push(text, cells, .{ .colour = .rule });
}

/// The composer's lines as `draft_layout` breaks them, at three cells in.
const ComposerLayout = struct {
    shape: draft_layout.Shape,
    view: draft_layout.View,
    lines: [draft_layout.max_rows]draft_layout.Line,

    fn plan(self: *ComposerLayout, painter: *const RowPaint, draft: Draft, height: u16) void {
        const width = painter.width - 4;
        const pieces: DraftPieces = .{ .pieces = .{ .bytes = draft.bytes, .painter = painter }, .width = width };
        self.shape = draft_layout.shape(pieces, width, draft.cursor, draft.anchor);
        self.view = draft_layout.fit(pieces, width, draft.cursor, self.shape, draft_layout.cap(height), &self.lines);
    }
};

/// The draft as the composer draws it, for `draft_layout`: a newline breaks
/// the line, and every other piece is what `Pieces` draws. A cluster wider
/// than the line counts as filling it, which `put` shortens it to.
const DraftPieces = struct {
    pieces: Pieces,
    width: u16,

    pub fn next(self: *DraftPieces) ?draft_layout.Piece {
        const before = self.pieces.at;
        if (before < self.pieces.bytes.len and self.pieces.bytes[before] == '\n') {
            self.pieces.at += 1;
            return .{ .len = 1, .cells = 0, .kind = .newline };
        }
        const piece = self.pieces.next() orelse return null;
        return .{ .len = self.pieces.at - before, .cells = @intCast(@min(piece.cells, self.width)), .kind = draft_layout.kindOf(piece.bytes) };
    }
};

/// The draft's shown lines, one per row of `rows`, the prompt on its first.
fn composer(painter: *RowPaint, state: *const State, draft: Draft, input: *const ComposerLayout, rows: view.Layout.Rows) error{OutOfMemory}!void {
    std.debug.assert(rows.len() == input.view.rows);
    const room = painter.width -| 4;
    painter.at(rows.start);
    if (state.inputMode() == .choice) {
        try signInChoice(painter, state.menu.entries[state.highlighted().?].providers, state.picker.?.step.sign_in);
        return;
    }
    if (draft.bytes.len == 0) {
        painter.begin(false);
        _ = try painter.put(1, painter.glyphs.prompt, 1, .{});
        _ = try painter.put(3, "Type a task to start a Session", room, .{ .colour = .quiet });
        try painter.finish();
        return;
    }
    const style: Style = .{ .colour = if (state.starting()) .quiet else .strong };
    for (input.lines[0..rows.len()], 0..) |line, index| {
        painter.at(@intCast(rows.start + index));
        painter.begin(false);
        if (input.view.first + index == 0) _ = try painter.put(1, painter.glyphs.prompt, 1, .{});
        _ = try painter.put(3, draft.bytes[line.start..line.end], room, style);
        try painter.finish();
    }
}
/// The line under the input. `listed`: this frame shows the command list.
fn hints(painter: *RowPaint, state: *const State, draft: Draft, listed: bool) error{OutOfMemory}!void {
    painter.begin(false);
    const room = painter.width -| 2;
    const dot = painter.glyphs.dot;
    // What Esc does here, as `compose` reads it: a list or a panel closes
    // before the draft and the held settings clear.
    const esc_does: ?[]const u8 = if (listed or state.panel != null) "esc close" else if (draft.bytes.len != 0 or !state.settings.empty()) "esc clear" else null;
    if (state.prompt) |prompt| {
        const text = try std.fmt.allocPrint(painter.arena, stop_prompt, .{ &prompt.stop, dot });
        _ = try painter.put(1, text, room, .{ .colour = .attention });
    } else if (state.shownPicker()) |picker| {
        // A notice shares the row, so the picker's keys stay in view.
        const used = if (state.notice) |*notice| try painter.put(1, notice.firstLine(), room, .{ .colour = notice.colour }) + 1 else 0;
        const text = if (picker.step == .sign_in)
            try std.fmt.allocPrint(painter.arena, "{s}{s} choose {s} enter pick {s} esc models", .{ if (used != 0) " " else "", painter.glyphs.sides, dot, dot })
        else
            try std.fmt.allocPrint(painter.arena, "{s}{s} choose {s} enter pick {s} esc close", .{ if (used != 0) " " else "", painter.glyphs.arrows, dot, dot });
        _ = try painter.put(used, text, room -| used, .{ .colour = .quiet });
    } else if (state.notice) |*notice| {
        _ = try painter.put(1, notice.firstLine(), room, .{ .colour = notice.colour });
    } else if (state.starting()) {
        _ = try painter.put(1, try std.fmt.allocPrint(painter.arena, "Starting{s}", .{painter.glyphs.ellipsis}), room, .{ .colour = .quiet });
    } else if (!state.settings.empty()) {
        var text: std.Io.Writer.Allocating = .init(painter.arena);
        text.writer.writeAll("start settings:") catch return error.OutOfMemory;
        writeSettings(&state.settings, &text.writer) catch return error.OutOfMemory;
        // Long settings are cut so the way out stays on screen.
        const suffix = try std.fmt.allocPrint(painter.arena, " {s} {s}", .{ dot, esc_does.? });
        const used = try painter.put(1, text.written(), room -| painter.measure(suffix), .{ .colour = .quiet });
        _ = try painter.put(1 + used, suffix, room -| used, .{ .colour = .quiet });
    } else if (draft.bytes.len != 0) {
        // What Enter and Esc do to this draft, as `enter` and `compose` read it.
        const slashed = draft.bytes[0] == '/' and !std.mem.startsWith(u8, draft.bytes, "//");
        const enter_does: []const u8 = if (!slashed) "enter start " else if (commands.parse(draft.bytes) == .command) "enter run " else "";
        const text = try std.fmt.allocPrint(painter.arena, "{s}{s}{s}", .{ enter_does, if (enter_does.len != 0) try std.fmt.allocPrint(painter.arena, "{s} ", .{dot}) else "", esc_does.? });
        _ = try painter.put(1, text, room, .{ .colour = .quiet });
    } else if (state.selectedRow()) |row| {
        const stop = if (stoppable(state, row.reference, row.state.asOf(state.now_ms))) try std.fmt.allocPrint(painter.arena, " {s} " ++ session_line.stop_hint, .{dot}) else "";
        const close = if (esc_does) |does| try std.fmt.allocPrint(painter.arena, " {s} {s}", .{ dot, does }) else "";
        const text = try std.fmt.allocPrint(painter.arena, "{s} select {s} enter open{s}{s}", .{ painter.glyphs.arrows, dot, stop, close });
        _ = try painter.put(1, text, room, .{ .colour = .quiet });
    } else if (esc_does) |does| {
        _ = try painter.put(1, does, room, .{ .colour = .quiet });
    }
    return painter.finish();
}

/// Fills `lines`, the rows `layout` gave the picker, as `pickerFit` says.
fn pickerLines(painter: *RowPaint, state: *const State, picker: *const Picker, lines: view.Layout.Rows) error{OutOfMemory}!void {
    const menu = &state.menu;
    const fit = pickerFit(state, lines.len());
    std.debug.assert(fit.used() == lines.len());
    if (picker.step == .sign_in) {
        painter.at(lines.start);
        painter.begin(false);
        _ = try painter.put(4, picker.highlight.slice(), painter.width -| 5, .{ .colour = .strong });
        try painter.finish();
        return;
    }
    const kept = menu.entries.len != 0 or for (menu.sources.values) |source| {
        if (source != null) break true;
    } else false;
    var line: usize = 0;
    if (fit.above) {
        painter.at(@intCast(lines.start + line));
        try quietLine(painter, switch (state.menu_read) {
            .read => unreachable,
            .unread => try std.fmt.allocPrint(painter.arena, "Loading models{s}", .{painter.glyphs.ellipsis}),
            .unanswered => if (kept) "The Host did not answer; this is the last list" else "Models unavailable: the Host did not answer",
            .invalid => if (kept) "The Host's model list was not valid; this is the last list" else "Models unavailable: the Host's list was not valid",
        });
        line += 1;
    }
    const shown_menu = state.shownMenu();
    const others = shown_menu.others();
    const items = pickerItems(state);
    const row = if (state.highlighted()) |at| shown_menu.row(at) else 0;
    const highlighted = row + @intFromBool(row >= others);
    const first = @min((highlighted + 1) -| fit.shown, items - fit.shown);
    const tag_column = 8 + @as(usize, @min(menu.widest, 24));
    var listed: usize = 0;
    for (first..first + fit.shown) |item| {
        if (item == others) {
            painter.at(@intCast(lines.start + line));
            painter.begin(false);
            _ = try painter.put(2, "Other models", painter.width -| 3, .{ .colour = .ink, .bold = true });
            try painter.finish();
        } else {
            painter.at(@intCast(lines.start + line));
            try modelLine(painter, state, shown_menu.entry(item - @intFromBool(item > others)), tag_column);
            listed += 1;
        }
        line += 1;
    }
    if (fit.more) {
        painter.at(@intCast(lines.start + line));
        try quietLine(painter, try std.fmt.allocPrint(painter.arena, "{d} more", .{menu.entries.len - listed}));
        line += 1;
    }
    var noted: usize = 0;
    for (std.enums.values(Provider)) |provider| {
        if (noted == fit.notes) break;
        const note = pickerNote(state, provider) orelse continue;
        const name = provider.signIn();
        painter.at(@intCast(lines.start + line));
        try quietLine(painter, switch (note) {
            .pending => try std.fmt.allocPrint(painter.arena, "{s}: loading its models{s}", .{ name, painter.glyphs.ellipsis }),
            .fallback => try std.fmt.allocPrint(painter.arena, "{s}: its live list is unavailable", .{name}),
            .login => try std.fmt.allocPrint(painter.arena, "{s}: run {s} in your shell", .{ name, provider.login() }),
        });
        line += 1;
        noted += 1;
    }
    std.debug.assert(line == lines.len());
}

/// One of the picker's dim lines, under its models.
fn quietLine(painter: *RowPaint, text: []const u8) error{OutOfMemory}!void {
    painter.begin(false);
    _ = try painter.put(4, text, painter.width -| 5, .{ .colour = .quiet });
    return painter.finish();
}

fn modelLine(painter: *RowPaint, state: *const State, entry: model_picker.Entry, tag_column: usize) error{OutOfMemory}!void {
    const highlighted = state.picker.?.highlight.eql(entry.id);
    painter.begin(highlighted);
    if (highlighted) _ = try painter.put(2, painter.glyphs.prompt, 1, .{ .colour = .strong });
    const is_default = if (state.nextBinding().model) |model| std.mem.eql(u8, model, entry.id) else false;
    const tag: []const u8 = if (!entry.known)
        (if (is_default) try std.fmt.allocPrint(painter.arena, "default {s} default limits", .{painter.glyphs.dot}) else "default limits")
    else if (is_default) "default" else "";
    const tag_cells = painter.measure(tag);
    const fits = tag.len != 0 and tag_column + tag_cells + 1 <= painter.width;
    const id_room = (if (fits) tag_column -| 2 else painter.width -| 1) -| 4;
    _ = try painter.put(4, entry.id, id_room, .{ .colour = if (highlighted) .strong else if (entry.known) .ink else .normal });
    if (fits) _ = try painter.put(tag_column, tag, tag_cells, .{ .colour = .quiet });
    return painter.finish();
}

/// The input row at the sign-in choice: `Use`, then each sign-in that
/// offers the model, the highlighted one marked and on the selection
/// ground, as an Action's Allow once / Deny choice is drawn.
fn signInChoice(painter: *RowPaint, providers: model_picker.Providers, highlight: Provider) error{OutOfMemory}!void {
    painter.begin(false);
    _ = try painter.put(3, "Use", 3, .{ .colour = .quiet });
    var column: usize = 8;
    for (std.enums.values(Provider)) |provider| if (providers.contains(provider)) {
        const chosen = provider == highlight;
        const text = if (chosen) try std.fmt.allocPrint(painter.arena, "{s} {s} ", .{ painter.glyphs.prompt, provider.signIn() }) else try std.fmt.allocPrint(painter.arena, "  {s} ", .{provider.signIn()});
        column += try painter.put(column, text, painter.width -| column -| 1, .{ .colour = if (chosen) .strong else .normal, .background = if (chosen) .selection else .ground }) + 2;
    };
    return painter.finish();
}

/// The list region: group headings, rows and "more" lines, scrolled so the
/// selection shows.
fn list(painter: *RowPaint, state: *const State, lines: view.Layout.Rows) error{OutOfMemory}!void {
    if (state.rows.items.len == 0) return;
    const lines_of = ListLines.of(state);
    const selected_line = if (state.selected) |ref| if (position(state, ref)) |at| lines_of.lineOf(state, at) else null else null;
    const offset = if (selected_line) |line| (line + 1) -| lines.len() else 0;
    const columns = Columns.of(painter.width);
    for (lines.start..lines.end, offset..) |row, number| {
        const item = lines_of.item(state, number) orelse break;
        painter.at(@intCast(row));
        switch (item) {
            .gap => {},
            .heading => |group| try heading(painter, group, state.runs.get(group).len),
            .row => |at| try rowLine(painter, state, at, columns),
            .more => |more| try moreLine(painter, more),
        }
    }
}
/// The panel in the Sessions' rows: its heading, with the way back at the
/// right, then its lines. When more lines come than rows, the last row
/// counts the rest.
fn panelLines(painter: *RowPaint, panel: *const Panel, lines: view.Layout.Rows) error{OutOfMemory}!void {
    painter.at(lines.start);
    painter.begin(false);
    const name = switch (panel.*) {
        .help => "Help",
        .output => |output| try std.fmt.allocPrint(painter.arena, "/{s}", .{@tagName(output.name)}),
    };
    _ = try painter.put(1, name, painter.width -| 2, .{ .colour = .ink, .bold = true });
    try painter.putRight(painter.width -| 1, "Esc returns", .{ .colour = .quiet });
    try painter.finish();
    const total = panel.rows() - 1;
    const room = lines.len() - 1;
    const shown = if (total <= room) total else room -| 1;
    var texts = std.mem.splitScalar(u8, panel.text(), '\n');
    for (0..shown) |index| {
        painter.at(@intCast(lines.start + 1 + index));
        painter.begin(false);
        _ = try painter.put(1, texts.next().?, painter.width -| 2, .{});
        try painter.finish();
    }
    if (shown == total or room == 0) return;
    painter.at(@intCast(lines.start + 1 + shown));
    painter.begin(false);
    _ = try painter.put(1, try std.fmt.allocPrint(painter.arena, "+{d} more lines", .{total - shown}), painter.width -| 2, .{ .colour = .quiet });
    try painter.finish();
}
/// A group's heading: its title and how many Sessions it holds, folded
/// ones included.
fn heading(painter: *RowPaint, group: Group, count: usize) error{OutOfMemory}!void {
    painter.begin(false);
    const info = groups.get(group);
    var column = 1 + try painter.put(1, info.title, painter.width -| 2, .{ .colour = .ink, .bold = true });
    var buffer: [32]u8 = undefined;
    const counted = try std.fmt.allocPrint(painter.arena, " {s} {s}", .{ painter.glyphs.dot, grouped(&buffer, count) });
    column += try painter.put(column, counted, painter.width -| column -| 1, .{ .colour = .quiet });
    if (info.help.len != 0) _ = try painter.put(column + 2, info.help, painter.width -| column -| 3, .{ .colour = .quiet });
    return painter.finish();
}

fn moreLine(painter: *RowPaint, hidden: usize) error{OutOfMemory}!void {
    painter.begin(false);
    const text = try std.fmt.allocPrint(painter.arena, "{d} more", .{hidden});
    _ = try painter.put(3, text, painter.width -| 4, .{ .colour = .quiet });
    return painter.finish();
}

/// Row columns, as the Khadi mock sets them: the mark at 2, the title at 4,
/// the word 26 cells from the right edge (50 on a screen of 100 or more),
/// the age ending at the edge. A row outside the working directory puts its
/// Workspace at the end of its title's room. A narrow screen drops the word.
const Columns = struct {
    word: usize,
    workspace: usize,
    end: usize,

    const title = 4;
    const age_cells = 4;

    /// A Workspace column narrower than this names nothing, so it is left out.
    const min_workspace = 8;
    /// The cells a title keeps when a long word takes from its room.
    const min_title = 16;

    fn of(width: usize) Columns {
        const end = width -| 1;
        const room = width -| 2;
        if (room < 40) return .{ .word = end, .workspace = 0, .end = end };
        const status = end - @as(usize, if (room >= 100) 50 else 26);
        // The Workspace never takes more cells than the title keeps: half
        // of what lies between them, after the two-cell gap.
        const workspace = @min(@as(usize, if (room >= 100) 32 else 12), (status -| 2 -| Columns.title -| 2) / 2);
        return .{ .word = status, .workspace = if (workspace < min_workspace) 0 else workspace, .end = end };
    }
};

fn rowLine(painter: *RowPaint, state: *const State, at: usize, columns: Columns) error{OutOfMemory}!void {
    const row = &state.rows.items[state.order.items[at]];
    const selected = if (state.selected) |*ref| std.mem.eql(u8, ref, &row.reference) else false;
    painter.begin(selected);
    const kind = shownKind(state, row);
    const rule = rules.get(kind);
    var words: [work_line.max_words_bytes]u8 = undefined;
    const line = workLine(&words, state, row);
    const faded = state.unreachable_since_ms != null;
    const mark = marks.get(rule.mark);
    // Your own Session at work turns the spinner, every one in step; any
    // other mark holds still. Only Unicode in colour spins, and a faded
    // row's state is stale, so it holds still.
    const spins = !faded and painter.caps.unicode and painter.caps.depth != .none and rule.spins and row.group() == .yours;
    painter.spun = painter.spun or spins;
    const glyph = if (spins) spinner[painter.frame % spinner.len] else if (painter.caps.unicode) mark.unicode else mark.ascii;
    _ = try painter.put(2, glyph, 1, .{ .colour = if (faded) .quiet else if (line) |shown| toneColour(shown.tone, rule.colour) else rule.colour });

    // Yours in the brightest ink, then named work; unnamed and ended grey.
    const yours = row.group() == .yours;
    const ended = rule.group == .finished or rule.group == .ended;
    const named = title(state, row);
    const title_colour: Colour = if (faded) .quiet else if (yours) .strong else if (named.hint or ended) .quiet else .ink;
    // Only a row outside the working directory names its Workspace, at the
    // end of its title's room.
    const workspace: []const u8 = if (columns.workspace != 0 and row.workspace != state.cwd) workspace: {
        const path = shortPath(state.home, state.workspaces.items[row.workspace]);
        break :workspace try std.mem.concat(painter.arena, u8, &.{ path.prefix, path.rest });
    } else "";
    // A word longer than its column, such as a retry's countdown, starts
    // early and takes from the title's room, down to `min_title` cells.
    var word_bytes: [max_word_bytes]u8 = undefined;
    const text = if (columns.word != columns.end) word(&word_bytes, state, row, rule, line, painter.script()) else "";
    const word_end = columns.end -| Columns.age_cells -| 1;
    const overflow = painter.measure(text) -| (word_end -| columns.word);
    const word_column = @max(columns.word -| overflow, @min(columns.word, Columns.title + Columns.min_title + 2));
    const workspace_cells = if (word_column < columns.word) 0 else @min(painter.measure(workspace), columns.workspace);
    const title_end = (word_column -| 2) -| (if (workspace_cells == 0) 0 else workspace_cells + 2);
    _ = try painter.put(Columns.title, named.text, title_end -| Columns.title, .{ .colour = title_colour, .bold = yours and !faded });
    _ = try painter.putTail(title_end + 2, workspace, workspace_cells, .{ .colour = if (faded) .quiet else .normal });

    if (columns.word != columns.end) {
        // Colour only for what needs the person, or quiet as the work asks.
        const settled: Colour = if (rule.colour == .failure) .failure else .normal;
        const tone = if (faded) .quiet else if (line) |shown| toneColour(shown.tone, .normal) else settled;
        _ = try painter.put(word_column, text, word_end -| word_column, .{ .colour = tone });
    }
    var buffer: [8]u8 = undefined;
    try painter.putRight(columns.end, ageText(&buffer, (state.now_ms / 1000) -| row.state.since()), .{ .colour = .quiet });
    return painter.finish();
}

/// The colour a work line's tone asks for, else `neutral`.
fn toneColour(tone: work_line.Tone, neutral: Colour) Colour {
    return switch (tone) {
        .normal => neutral,
        .quiet => .quiet,
        .attention => .attention,
    };
}

/// Bytes the row's word takes at most: work's words and its clock, or an
/// ended state's word naming its starter by quoted Label or reference.
const max_word_bytes = max: {
    var said = 0;
    for (rules.values) |rule| if (rule.word) |text| {
        said = @max(said, text.len);
    };
    const starter = said + " ".len + work_line.max_dot_bytes + " for ".len + @max("\"\"".len + max_label_bytes, @sizeOf(Reference));
    break :max @max(work_line.max_words_bytes + work_line.max_clock_bytes, starter);
};

/// What the row says beside its title, only where the mark and the group
/// leave something out: work that needs the person or explains a wait, in
/// the conversation's words, or the Session that started a failed or
/// stopped one. Otherwise nothing.
fn word(buffer: *[max_word_bytes]u8, state: *const State, row: *const Row, rule: Rule, line: ?work_line.Line, script: work_line.Script) []const u8 {
    if (line) |shown| {
        if (!rule.says) return "";
        var clock: [work_line.max_clock_bytes]u8 = undefined;
        return std.fmt.bufPrint(buffer, "{s}{s}", .{ shown.words, work_line.clockText(&clock, shown.clock, .row, script) }) catch unreachable;
    }
    if (!rule.starter) return "";
    const said = rule.word.?;
    const dot = work_line.glyphs.get(script).dot;
    const sender = (row.first orelse return "").sender orelse return "";
    if (state.find(sender)) |starter| if (starter.label) |*text| return std.fmt.bufPrint(buffer, "{s} {s} for \"{s}\"", .{ said, dot, text.slice() }) catch unreachable;
    return std.fmt.bufPrint(buffer, "{s} {s} for {s}", .{ said, dot, &sender }) catch unreachable;
}

/// Compact age: 42s, 7m, 3h, 12d.
fn ageText(buffer: *[8]u8, seconds: u64) []const u8 {
    const units = [_]struct { u64, u8 }{ .{ 86400, 'd' }, .{ 3600, 'h' }, .{ 60, 'm' } };
    for (units) |unit| if (seconds >= unit[0]) return std.fmt.bufPrint(buffer, "{d}{c}", .{ @min(seconds / unit[0], 999), unit[1] }) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d}s", .{seconds}) catch unreachable;
}

/// Renders `state` at `width` by `height`, which the shell steps before it
/// draws.

// UI-only fixtures share the pure core's value fixtures, not a renderer.
const Backend = @import("RenderBackend.zig");
const keymap = @import("keymap.zig");
const model_capability = @import("model_capability.zig");
const session_work = @import("session_work.zig");
const Kind = view.Kind;
const WorkState = view.WorkState;
const Background = view.Background;
const Conversed = view.Conversed;
const Default = view.Default;
const Listed = view.Listed;
const ModelsRead = view.ModelsRead;
const Prompt = view.Prompt;
const Ran = view.Ran;
const Reads = view.Reads;
const Rgb = view.Rgb;
const Saved = view.Saved;
const StartSettings = view.StartSettings;
const answerModels = view.Test.answerModels;
const both = view.Test.both;
const bounded = view.Test.bounded;
const chatgpt = view.Test.chatgpt;
const configure_usage = view.Test.configure_usage;
const drawWithRoom = view.Test.drawWithRoom;
const expectEffects = view.Test.expectEffects;
const expectLines = view.Test.expectLines;
const expectSaid = view.Test.expectSaid;
const expectSelected = view.Test.expectSelected;
const failedRow = view.Test.failedRow;
const highlightModel = view.Test.highlightModel;
const list_interval_ms = view.list_interval_ms;
const markOf = view.Test.markOf;
const max_picker_rows = view.max_picker_rows;
const max_prompt_bytes = view.max_prompt_bytes;
const max_requests = view.max_requests;
const mixed = view.Test.mixed;
const openPicker = view.Test.openPicker;
const opened = view.Test.opened;
const pickerMore = view.Test.pickerMore;
const pickerState = view.Test.pickerState;
const press = view.Test.press;
const ranWith = view.Test.ranWith;
const refresh = view.Test.refresh;
const repeated = view.Test.repeated;
const respond = view.Test.respond;
const retryRow = view.Test.retryRow;
const saveEnded = view.Test.saveEnded;
const session = view.Test.session;
const shownRow = view.Test.shownRow;
const spinning = view.Test.spinning;
const startOption = view.Test.startOption;
const start_options = view.start_options;
const submit = view.Test.submit;
const testState = view.Test.testState;
const testToken = view.Test.testToken;
const test_now_s = view.Test.test_now_s;
const typeText = view.Test.typeText;
const writeDeparture = view.writeDeparture;

const Rendered = struct {
    backend: *Backend,
    width: u16,
    height: u16,
    caps: Caps,
    draft_anchor: usize,
    commands: ?slash_commands.Shown,
    spins: bool,
    cursor: ?Cursor,
    const Cursor = struct { row: u16, column: u16 };

    fn deinit(self: *Rendered) void {
        self.backend.end();
        self.backend.deinit();
        std.testing.allocator.destroy(self.backend);
    }
    fn cell(self: *const Rendered, column: usize, row: usize) vaxis.Cell {
        return self.backend.storage.?.vx.screen.readCell(@intCast(column), @intCast(row)).?;
    }
    fn styleAt(self: *const Rendered, row: usize, column: usize) ?vaxis.Style {
        if (row >= self.height or column >= self.width) return null;
        const current = self.cell(column, row);
        if (std.mem.eql(u8, current.char.grapheme, " ") and std.meta.eql(current.style, cellStyle(self.caps, .{}))) return null;
        return current.style;
    }
    fn write(self: *const Rendered, writer: *std.Io.Writer) !void {
        for (0..self.height) |row| {
            var end: usize = self.width;
            while (end > 0 and std.mem.eql(u8, self.cell(end - 1, row).char.grapheme, " ")) end -= 1;
            var col: usize = 0;
            while (col < end) {
                const current = self.cell(col, row);
                try writer.writeAll(current.char.grapheme);
                col += @max(current.char.width, 1);
            }
            try writer.writeByte('\n');
        }
    }
};

fn testBackend(caps: Caps) !*Backend {
    const backend = try std.testing.allocator.create(Backend);
    errdefer std.testing.allocator.destroy(backend);
    backend.* = .{};
    errdefer backend.deinit();
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    try backend.init(std.testing.io, &env, .{ .width = caps.width, .depth = switch (caps.depth) {
        .none => .none,
        .indexed => .indexed,
        .direct => .direct,
    } });
    return backend;
}

fn sizedRender(state: *State, draft: Draft, width: u16, height: u16, caps: Caps, frame: u64) !Rendered {
    try expectEffects(&.{}, try step(state, .{ .resized = .{ .width = width, .height = height } }));
    const backend = try testBackend(caps);
    errdefer {
        backend.deinit();
        std.testing.allocator.destroy(backend);
    }
    try backend.begin(.{ .cols = @max(width, 8), .rows = @max(height, 2), .x_pixel = 0, .y_pixel = 0 });
    const window = backend.window().child(.{ .width = width, .height = height });
    const facts = try draw(window, backend.scratch(), state, draft, caps, frame);
    const vx = &backend.storage.?.vx;
    return .{ .backend = backend, .width = width, .height = height, .caps = caps, .draft_anchor = facts.draft_anchor, .commands = facts.commands, .spins = facts.spins, .cursor = if (vx.screen.cursor_vis) .{ .row = vx.screen.cursor.row, .column = vx.screen.cursor.col } else null };
}

fn expectNotice(state: *State, expected: ?[]const u8) !void {
    return expectNoticeAt(state, expected, true);
}

/// A notice whose data (a Host's code, the list of start settings) may be
/// cut at the edge of a narrow overview; its wording is not.
fn expectNoticeWithData(state: *State, expected: []const u8) !void {
    return expectNoticeAt(state, expected, false);
}

fn expectNoticeAt(state: *State, expected: ?[]const u8, whole_at_40: bool) !void {
    if (expected) |text| {
        const notice = state.notice orelse return error.TestExpectedNotice;
        try std.testing.expectEqualStrings(text, notice.text());
        if (whole_at_40 and state.prompt == null) {
            const screen = try screenText(state, 40, 24, .{});
            defer std.testing.allocator.free(screen);
            var lines = std.mem.splitScalar(u8, screen, '\n');
            for (0..24 - (1 + std.mem.count(u8, text, "\n"))) |_| _ = lines.next();
            var said = std.mem.splitScalar(u8, text, '\n');
            while (said.next()) |line| try std.testing.expectEqualStrings(line, std.mem.trim(u8, lines.next().?, " "));
        }
    } else if (state.notice) |*notice| try std.testing.expectEqualStrings("", notice.text());
}

fn screenText(state: *State, width: u16, height: u16, caps: Caps) ![]u8 {
    return frameText(state, width, height, caps, 0);
}

fn frameText(state: *State, width: u16, height: u16, caps: Caps, frame: u64) ![]u8 {
    var screen = try sizedRender(state, .{}, width, height, caps, frame);
    defer screen.deinit();
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer text.deinit();
    try screen.write(&text.writer);
    return text.toOwnedSlice();
}

fn expectScreen(state: *State, width: u16, height: u16, caps: Caps, expected: []const u8) !void {
    const actual = try screenText(state, width, height, caps);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

/// One row of each kind, its group heading and its row in Unicode and ASCII.
const kind_cases = [_]struct { state: WorkState, heading: []const u8, unicode: []const u8, ascii: []const u8, colour: Colour, stoppable: bool }{
    .{ .state = .{ .idle = ago(7200) }, .heading = " Idle", .unicode = "  ○ Write the notes                                                          2h", .ascii = "  o Write the notes                                                          2h", .colour = .normal, .stoppable = false },
    .{ .state = .{ .pending = ago(5) }, .heading = " Queued", .unicode = "  ◌ Write the notes                                                          5s", .ascii = "  : Write the notes                                                          5s", .colour = .normal, .stoppable = true },
    .{ .state = .{ .working = ago(40) }, .heading = " Active", .unicode = "  ● Write the notes                                                         40s", .ascii = "  * Write the notes                                                         40s", .colour = .ink, .stoppable = true },
    .{ .state = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = test_now_s * 1000 + 11_500, .cause = bounded(session_work.max_code_bytes, "provider_temporary_error"), .attempt = 2 } }, .heading = " Active", .unicode = "  ● Write the notes                        Provider error · retry 2 in 12s  30s", .ascii = "  * Write the notes                        Provider error - retry 2 in 12s  30s", .colour = .attention, .stoppable = true },
    .{ .state = .{ .bash = .{ .since = test_now_s - 75, .call = 0, .description = bounded(max_label_bytes, "Run the logic tests"), .running = 1, .approvals = 0 } }, .heading = " Active", .unicode = "  ● Write the notes                                  Run the logic tests     1m", .ascii = "  * Write the notes                                  Run the logic tests     1m", .colour = .ink, .stoppable = true },
    .{ .state = .{ .approval = ago(3 * 60) }, .heading = " Active", .unicode = "  ○ Write the notes                                  Needs approval          3m", .ascii = "  o Write the notes                                  Needs approval          3m", .colour = .attention, .stoppable = true },
    .{ .state = .{ .stopping = ago(8) }, .heading = " Active", .unicode = "  ● Write the notes                                  Stopping…               8s", .ascii = "  * Write the notes                                  Stopping.               8s", .colour = .quiet, .stoppable = false },
    .{ .state = .{ .finished = ago(12 * 60) }, .heading = " Finished", .unicode = "  ✓ Write the notes                                                         12m", .ascii = "  + Write the notes                                                         12m", .colour = .mark, .stoppable = false },
    .{ .state = .{ .failed = .{ .since = test_now_s - 3 * 3600, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .heading = " Stopped or failed", .unicode = "  × Write the notes                                                          3h", .ascii = "  x Write the notes                                                          3h", .colour = .failure, .stoppable = false },
    .{ .state = .{ .stopped = .{ .since = test_now_s - 2 * 86400, .cause = .interruption } }, .heading = " Stopped or failed", .unicode = "  ■ Write the notes                                                          2d", .ascii = "  # Write the notes                                                          2d", .colour = .normal, .stoppable = false },
};

test "every work state follows the rules table, in Unicode and ASCII" {
    comptime std.debug.assert(kind_cases.len == std.enums.values(Kind).len);
    for (kind_cases, std.enums.values(Kind)) |case, kind| {
        try std.testing.expectEqual(kind, std.meta.activeTag(case.state));
        var state = try opened(&.{session("k7m2qx", case.state, .{ .label = "Write the notes" })});
        defer state.deinit();
        const rule = rules.get(kind);
        try std.testing.expectEqual(case.stoppable, rule.stoppable);
        // Only work under way has a work line, and only idle or ended work
        // a word of its own.
        try std.testing.expectEqual(case.state.progress() == null, rule.word != null);
        for ([_]Caps{ .{}, .{ .unicode = false } }, [_][]const u8{ case.unicode, case.ascii }) |caps, expected| {
            const text = try screenText(&state, 80, 24, caps);
            defer std.testing.allocator.free(text);
            var lines = std.mem.splitScalar(u8, text, '\n');
            for (0..4) |_| _ = lines.next();
            // The heading counts the one Session.
            const counted = try std.fmt.allocPrint(std.testing.allocator, "{s} {s} 1", .{ case.heading, if (caps.unicode) unicode_glyphs.dot else ascii_glyphs.dot });
            defer std.testing.allocator.free(counted);
            try std.testing.expectEqualStrings(counted, lines.next().?);
            try std.testing.expectEqualStrings(expected, lines.next().?);
        }
        // The mark takes its colour, and the word one only when it needs
        // the person or is quiet.
        var screen = try sizedRender(&state, .{}, 80, 24, .{}, 0);
        defer screen.deinit();
        try std.testing.expectEqual(cellStyle(screen.caps, .{ .background = .selection }).bg, screen.styleAt(5, 1).?.bg);
        state.selected = null;
        var unselected = try sizedRender(&state, .{}, 80, 24, .{}, 0);
        defer unselected.deinit();
        try std.testing.expectEqual(cellStyle(unselected.caps, Style{ .colour = case.colour }), unselected.styleAt(5, 2).?);
        const tone: Colour = switch (case.colour) {
            .attention, .failure, .quiet => case.colour,
            else => .normal,
        };
        if (unselected.styleAt(5, 53)) |style| try std.testing.expectEqual(cellStyle(unselected.caps, .{ .colour = tone }), style);
    }
}

test "a description's controls read escaped in its row's words, as its call row shows them" {
    const bash: WorkState = .{ .bash = .{ .since = test_now_s - 75, .call = 0, .description = bounded(max_label_bytes, "Run\t\x1b[2J\u{202e}tests"), .running = 1, .approvals = 0 } };
    var state = try opened(&.{session("k7m2qx", bash, .{ .label = "Write the notes" })});
    defer state.deinit();
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    for (0..5) |_| _ = lines.next();
    try std.testing.expectEqualStrings("  ● Write the notes                                Run\\t\\x1b[2J\\u202etests   1m", lines.next().?);
}

test "a retry that has fallen due reads as queued in its group, mark and colour" {
    const due: WorkState = .{ .retrying = .{ .since = test_now_s - 30, .due_at_ms = test_now_s * 1000 - 2_000, .cause = bounded(session_work.max_code_bytes, "provider_temporary_http_429"), .attempt = 2 } };
    var state = try opened(&.{session("k7m2qx", due, .{ .label = "Write the notes" })});
    defer state.deinit();
    state.selected = null;
    const text = try screenText(&state, 80, 24, .{ .depth = .none });
    defer std.testing.allocator.free(text);
    const at = std.mem.indexOf(u8, text, "Write the notes").?;
    const start = std.mem.lastIndexOfScalar(u8, text[0..at], '\n').? + 1;
    const end = std.mem.indexOfScalarPos(u8, text, at, '\n').?;
    try std.testing.expectEqualStrings("  ◌ Write the notes                                                          2s", text[start..end]);
    try std.testing.expect(std.mem.indexOf(u8, text, " Queued · 1\n") != null);
    var screen = try sizedRender(&state, .{}, 80, 24, .{ .depth = .none }, 0);
    defer screen.deinit();
    try std.testing.expectEqual(cellStyle(screen.caps, Style{ .colour = .normal }), screen.styleAt(5, 2).?);
}

test "each heading counts its group, and Yours takes a Session from the group it would join" {
    var state = try opened(&.{
        session("k7m2qx", .{ .working = ago(40) }, .{ .label = "Thinking" }),
        session("h8q2mz", .{ .approval = ago(5) }, .{ .label = "Asking" }),
        session("d4e5f6", .{ .pending = ago(5) }, .{ .label = "Waiting for a slot" }),
        session("e5f6g7", .{ .pending = ago(9) }, .{ .label = "Mine, waiting", .yours = true }),
        session("m1n2p3", .{ .finished = ago(60) }, .{ .label = "Done" }),
    });
    defer state.deinit();
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    inline for (.{ " Yours · 1\n", " Active · 2\n", " Queued · 1\n", " Finished · 1\n" }) |heading_line| {
        try std.testing.expect(std.mem.indexOf(u8, text, heading_line) != null);
    }
    // A queued row shows its own mark, under Yours too, and no word.
    try std.testing.expect(std.mem.indexOf(u8, text, "  ◌ Mine, waiting                                                            9s\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Waiting for a slot                                                       5s\n") != null);
}

test "your Sessions at work turn the spinner in step, and every other mark holds still" {
    var state = try opened(&spinning);
    defer state.deinit();
    state.selected = null;
    for (0..spinner.len + 1) |frame| {
        const text = try frameText(&state, 80, 24, .{}, frame);
        defer std.testing.allocator.free(text);
        const turn = spinner[frame % spinner.len];
        try std.testing.expectEqualStrings(turn, markOf(text, "Mine, thinking"));
        try std.testing.expectEqualStrings(turn, markOf(text, "Mine, running"));
        try std.testing.expectEqualStrings("○", markOf(text, "Mine, asking"));
        try std.testing.expectEqualStrings("◌", markOf(text, "Mine, queued"));
        try std.testing.expectEqualStrings("●", markOf(text, "Mine, retrying"));
        try std.testing.expectEqualStrings("●", markOf(text, "Mine, stopping"));
        try std.testing.expectEqualStrings("●", markOf(text, "Theirs, thinking"));
        try std.testing.expectEqualStrings("✓", markOf(text, "Theirs, finished"));
        var screen = try sizedRender(&state, .{}, 80, 24, .{}, frame);
        defer screen.deinit();
        try std.testing.expect(screen.spins);
        // The spinner keeps its rule's colour.
        const mine = std.mem.count(u8, text[0..std.mem.indexOf(u8, text, "Mine, thinking").?], "\n");
        try std.testing.expectEqual(cellStyle(screen.caps, Style{ .colour = .ink }), screen.styleAt(mine, 2).?);
    }
    // A stop the person asked for holds the mark still before the Host
    // reports it.
    state.selected = "y0urs1".*;
    _ = try press(&state, .{}, .stop);
    _ = try press(&state, .{}, .stop);
    try std.testing.expect(state.openStop("y0urs1".*) != null);
    const asked = try frameText(&state, 80, 24, .{}, 1);
    defer std.testing.allocator.free(asked);
    try std.testing.expectEqualStrings("●", markOf(asked, "Mine, thinking"));
    // ASCII, NO_COLOR and a faded screen hold still on every frame.
    for ([_]Caps{ .{ .unicode = false }, .{ .depth = .none }, .{ .unicode = false, .depth = .none }, .{} }, 0..) |caps, at| {
        if (at == 3) state.unreachable_since_ms = state.now_ms;
        const first = try screenText(&state, 80, 24, caps);
        defer std.testing.allocator.free(first);
        for (1..spinner.len + 1) |frame| {
            const text = try frameText(&state, 80, 24, caps, frame);
            defer std.testing.allocator.free(text);
            try std.testing.expectEqualStrings(first, text);
            var screen = try sizedRender(&state, .{}, 80, 24, caps, frame);
            defer screen.deinit();
            try std.testing.expect(!screen.spins);
        }
    }
}

test "the screen asks for frames only while a spinner shows" {
    var rows: [31]Listed = undefined;
    rows[0] = session("w0rk00", .{ .working = ago(0) }, .{ .label = "Write the notes", .yours = true });
    for (rows[1..], 1..) |*row, at| {
        var ref: [6]u8 = "idle00".*;
        _ = std.fmt.bufPrint(ref[4..], "{d:0>2}", .{at}) catch unreachable;
        row.* = session(&ref, .{ .idle = ago(7200 + at) }, .{ .label = "Wait for a reply" });
    }
    const Spins = struct {
        fn at(from: *State, height: u16) !bool {
            var screen = try sizedRender(from, .{}, 80, height, .{}, 1);
            defer screen.deinit();
            return screen.spins;
        }
    };
    {
        var state = try opened(&rows);
        defer state.deinit();
        try std.testing.expect(try Spins.at(&state, 24));
        // Scrolled out of sight, the spinning row needs no frames.
        _ = try press(&state, .{}, .last);
        try std.testing.expect(!try Spins.at(&state, 24));
        try std.testing.expect(try Spins.at(&state, 60));
        // Its work ending stops the frames.
        _ = try refresh(&state, .changed, testToken(2), &.{session("w0rk00", .{ .finished = ago(0) }, .{ .label = "Write the notes", .yours = true })});
        try std.testing.expect(!try Spins.at(&state, 60));
    }
    // Others' work holds still, so it needs no frames.
    rows[0] = session("w0rk00", .{ .working = ago(0) }, .{ .label = "Write the notes" });
    var state = try opened(&rows);
    defer state.deinit();
    try std.testing.expect(!try Spins.at(&state, 60));
}

fn encoded(backend: *Backend, state: *State, draft: Draft, caps: Caps, frame: u64) ![]u8 {
    try backend.begin(.{ .cols = state.size.width, .rows = state.size.height, .x_pixel = 0, .y_pixel = 0 });
    defer backend.end();
    errdefer backend.poison();
    _ = try draw(backend.window(), backend.scratch(), state, draft, caps, frame);
    return std.testing.allocator.dupe(u8, try backend.encode());
}

test "the invocation backend alone diffs overview, spinner, draft and size changes" {
    var rows = mixed;
    rows[1].state = .{ .working = ago(0) };
    for ([_]Caps{ .{ .depth = .none }, .{} }) |caps| {
        var state = try opened(&rows);
        defer state.deinit();
        state.selected = null;
        _ = try step(&state, .{ .resized = .{ .width = 80, .height = 24 } });
        const backend = try testBackend(caps);
        defer {
            backend.deinit();
            std.testing.allocator.destroy(backend);
        }
        const first = try encoded(backend, &state, .{}, caps, 0);
        defer std.testing.allocator.free(first);
        try std.testing.expect(first.len != 0);
        const unchanged = try encoded(backend, &state, .{}, caps, 0);
        defer std.testing.allocator.free(unchanged);
        try std.testing.expectEqual(@as(usize, 0), unchanged.len);
        const spun = try encoded(backend, &state, .{}, caps, 1);
        defer std.testing.allocator.free(spun);
        try std.testing.expectEqual(caps.depth != .none, spun.len != 0);
        if (spun.len != 0) {
            try std.testing.expect(spun.len < first.len);
            try std.testing.expect(std.mem.indexOf(u8, spun, "Type a task") == null);
        }
        const typed = try encoded(backend, &state, try typeText(&state, "hi"), caps, 1);
        defer std.testing.allocator.free(typed);
        try std.testing.expect(typed.len != 0 and typed.len < first.len);
        _ = try step(&state, .{ .resized = .{ .width = 81, .height = 24 } });
        const resized = try encoded(backend, &state, .{}, caps, 1);
        defer std.testing.allocator.free(resized);
        try std.testing.expect(resized.len != 0);
    }
}

test "ctrl-x asks to stop only a row its rule lets it stop, and a second ctrl-x stops it" {
    for (kind_cases) |case| {
        var state = try opened(&.{session("k7m2qx", case.state, .{ .label = "Write the notes" })});
        defer state.deinit();
        try expectEffects(&.{}, try press(&state, .{}, .stop));
        if (!case.stoppable) {
            try std.testing.expectEqual(@as(?Prompt, null), state.prompt);
            var buffer: [64]u8 = undefined;
            const expected = if (rules.get(case.state).word) |said| try std.fmt.bufPrint(&buffer, "k7m2qx is already {s}.", .{said}) else "k7m2qx: Stopping";
            try expectNotice(&state, expected);
            continue;
        }
        try std.testing.expectEqualStrings("k7m2qx", &state.prompt.?.stop);
        try expectNotice(&state, null);
        try expectEffects(&.{.{ .stop = "k7m2qx".* }}, try press(&state, .{}, .stop));
        try std.testing.expectEqual(@as(?Prompt, null), state.prompt);
        // Until its result arrives the row says it is stopping, and a third
        // ctrl-x finds nothing to stop.
        const text = try screenText(&state, 80, 24, .{});
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "● Write the notes                                  Stopping…") != null);
        try expectEffects(&.{}, try press(&state, .{}, .stop));
        try expectNotice(&state, "k7m2qx: Stopping");
        try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = "k7m2qx".*, .outcome = .stopped } }));
        try std.testing.expectEqual(@as(u64, 0), state.next_list_ms);
    }
}

test "ctrl-x in a conversation stops its Session as on its row, listed or not" {
    var state = try testState();
    defer state.deinit();
    const ref = "k7m2qx".*;
    const ctrl_x: Conversed = .{ .reference = ref, .work = .working, .stop = true };
    var buffer: [max_prompt_bytes]u8 = undefined;
    try expectSaid(null, false, true, conversation(&state, ref, .working, &buffer));
    try expectEffects(&.{}, try step(&state, .{ .conversed = ctrl_x }));
    try expectSaid("Stop k7m2qx? ctrl+x yes · esc no", true, true, conversation(&state, ref, .working, &buffer));
    // Another Session's conversation does not show the prompt.
    try std.testing.expect(!conversation(&state, "b4n8wd".*, .working, &buffer).asking);
    // Any other input there cancels, and the next ctrl-x asks afresh.
    try expectEffects(&.{}, try step(&state, .{ .conversed = .{ .reference = ref, .work = .working, .stop = false } }));
    try std.testing.expectEqual(@as(?[]const u8, null), conversation(&state, ref, .working, &buffer).text);
    try expectEffects(&.{}, try step(&state, .{ .conversed = ctrl_x }));
    try expectEffects(&.{.{ .stop = ref }}, try step(&state, .{ .conversed = ctrl_x }));
    // Until its answer the work is stopping: no hint, and ctrl-x says so.
    try std.testing.expect(!conversation(&state, ref, .working, &buffer).stoppable);
    try expectEffects(&.{}, try step(&state, .{ .conversed = ctrl_x }));
    try expectNotice(&state, "k7m2qx: Stopping");
    try expectSaid("k7m2qx: Stopping", false, false, conversation(&state, ref, .working, &buffer));
    try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = ref, .outcome = .{ .failed = "session_not_found" } } }));
    try expectNoticeWithData(&state, "! k7m2qx not stopped: session_not_found");
    // Ended work takes no stop.
    try std.testing.expect(conversation(&state, ref, .working, &buffer).stoppable and !conversation(&state, ref, .finished, &buffer).stoppable);
    try expectEffects(&.{}, try step(&state, .{ .conversed = .{ .reference = ref, .work = .finished, .stop = true } }));
    try expectNotice(&state, "k7m2qx is already finished.");
}

test "a cancelled stop prompt sends nothing" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectSelected(&state, "k7m2qx");
    // Esc only cancels: the draft stays.
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    try expectEffects(&.{}, try press(&state, .{ .bytes = "keep", .cursor = 4 }, .clear));
    try std.testing.expectEqual(@as(?Prompt, null), state.prompt);
    try expectSelected(&state, "k7m2qx");
    // Another key cancels, then acts.
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    try expectEffects(&.{}, try press(&state, .{}, .next));
    try std.testing.expectEqual(@as(?Prompt, null), state.prompt);
    try expectSelected(&state, "r4t9vw");
    // So does input that left the draft as it was.
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    try expectEffects(&.{}, try step(&state, .{ .composed = .{ .input = .{ .composer = .none }, .draft = .{} } }));
    try std.testing.expectEqual(@as(?Prompt, null), state.prompt);
    // A row that finished after the prompt opened has nothing left to stop.
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    _ = try refresh(&state, .changed, testToken(2), &.{session("r4t9vw", .{ .finished = ago(0) }, .{ .label = "Review PR 412", .yours = true })});
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    try expectNotice(&state, "r4t9vw is already finished.");
    // A failed stop says why. The finished row moved to the top of its group.
    try expectEffects(&.{}, try press(&state, .{}, .next));
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    try expectEffects(&.{.{ .stop = "k7m2qx".* }}, try press(&state, .{}, .stop));
    try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = "k7m2qx".*, .outcome = .{ .failed = "session_not_found" } } }));
    try expectNoticeWithData(&state, "! k7m2qx not stopped: session_not_found");
}

test "unconfirmed stops keep their handles until departure; a full ledger refuses another" {
    const refs = [_]Reference{ "k7m2qx".*, "r4t9vw".*, "a1b2c3".*, "b2c3d4".*, "c3d4e5".*, "d4e5f6".*, "f6g7h8".*, "g7h8j9".*, "m1n2p3".* };
    comptime std.debug.assert(refs.len == max_requests + 1);
    var rows: [refs.len]Listed = undefined;
    for (&rows, &refs, 0..) |*row, *ref, n| row.* = session(ref, .{ .working = ago(10 * (n + 1)) }, .{});
    var state = try opened(&rows);
    defer state.deinit();
    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    var stopped: [max_requests]Reference = undefined;
    for (&stopped, 0..) |*ref, n| {
        if (n != 0) try expectEffects(&.{}, try press(&state, .{}, .next));
        ref.* = state.selected.?;
        for (stopped[0..n]) |earlier| try std.testing.expect(!std.mem.eql(u8, &earlier, ref));
        var bytes: [32]u8 = undefined;
        const handle = try std.fmt.bufPrint(&bytes, "stop-handle-{d}", .{n});
        var notice: [128]u8 = undefined;
        const recover = try std.fmt.bufPrint(&notice, "! {s} stop unsure; details on exit", .{ref});
        try expectEffects(&.{}, try press(&state, .{}, .stop));
        try expectEffects(&.{.{ .stop = ref.* }}, try press(&state, .{}, .stop));
        try expectEffects(&.{}, try step(&state, .{ .stop = .{ .reference = ref.*, .outcome = .{ .unconfirmed = handle } } }));
        try expectNotice(&state, recover);
        // The row stays stopping: another Ctrl-X sends nothing and says
        // so again.
        try std.testing.expectEqual(Kind.stopping, shownKind(&state, state.find(ref.*).?));
        state.notice = null;
        try expectEffects(&.{}, try press(&state, .{}, .stop));
        try expectEffects(&.{}, try press(&state, .{}, .stop));
        try expectNotice(&state, recover);
        try expected.writer.print("rui: Not sure {s} stopped. Check with: rui request recover {s}\n", .{ ref, handle });
    }
    // A full ledger refuses a stop of a Session it does not hold.
    try expectEffects(&.{}, try press(&state, .{}, .next));
    const last = state.selected.?;
    for (stopped) |earlier| try std.testing.expect(!std.mem.eql(u8, &earlier, &last));
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    try expectEffects(&.{}, try press(&state, .{}, .stop));
    try expectNotice(&state, "! Busy; try again shortly.");
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try writeDeparture(&state, null, &departure.writer);
    try std.testing.expectEqualStrings(expected.written(), departure.written());
}

test "esc clears the draft, then held start settings, and otherwise does nothing" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    draft = try typeText(&state, "/configure --permission-mode ask");
    try expectEffects(&.{.clear_draft}, try submit(&state, draft));
    draft = try typeText(&state, "Fix the docs");
    try expectEffects(&.{.clear_draft}, try press(&state, draft, .clear));
    try std.testing.expect(!state.settings.empty());
    draft = try typeText(&state, "");
    try expectEffects(&.{}, try press(&state, draft, .clear));
    try std.testing.expect(state.settings.empty());
    try expectEffects(&.{}, try press(&state, draft, .clear));
    try expectSelected(&state, "k7m2qx");
    try expectNotice(&state, null);
}

test "the composer starts a Session with its text and opens it" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    draft = try typeText(&state, "Fix the flaky resize test");
    const empty: StartSettings = .{};
    try expectEffects(&.{.{ .start = .{ .settings = &empty, .text = "Fix the flaky resize test" } }}, try submit(&state, draft));
    try std.testing.expect(state.starting());
    try expectEffects(&.{ .clear_draft, .{ .open = "z9y8x7".* } }, try step(&state, .{ .start = .{ .started = .{ .reference = "z9y8x7".*, .handle = "h1" } } }));
    try std.testing.expect(!state.starting());
    try expectSelected(&state, "z9y8x7");
    // The next tick lists at once, so the new row is there on return.
    try expectEffects(&.{.{ .list = testToken(1) }}, try step(&state, .{ .tick = state.now_ms + 1 }));

    // A failed start keeps the text for another Enter.
    draft = try typeText(&state, "Try again");
    _ = try submit(&state, draft);
    try expectEffects(&.{}, try step(&state, .{ .start = .{ .failed = "model_capability_unavailable" } }));
    try expectNoticeWithData(&state, "! Not started: model_capability_unavailable");
    try std.testing.expect(!state.starting());
}

test "the composer starts text with one slash from //, as a conversation does" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    draft = try typeText(&state, "/home/me/project needs investigating");
    try expectEffects(&.{}, try submit(&state, draft));
    try expectNoticeWithData(&state, "! Unknown command /home/me/project · /help");
    draft = try typeText(&state, "//home/me/project needs investigating");
    const empty: StartSettings = .{};
    try expectEffects(&.{.{ .start = .{ .settings = &empty, .text = "/home/me/project needs investigating" } }}, try submit(&state, draft));
}

/// The rendered lines of `state` with `draft` at `width` by `height`.
fn draftLines(state: *State, draft: Draft, width: u16, height: u16) ![]u8 {
    var screen = try sizedRender(state, draft, width, height, .{}, 0);
    defer screen.deinit();
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer text.deinit();
    try screen.write(&text.writer);
    return text.toOwnedSlice();
}

test "typing / lists the overview's commands between the rule and the draft, as a conversation does" {
    var state = try opened(&mixed);
    defer state.deinit();
    const all = try draftLines(&state, try typeText(&state, "/"), 80, 24);
    defer std.testing.allocator.free(all);
    try expectLines(all, 16, &.{
        " /configure [OPTIONS]  hold settings for the next Session",
        " /exit                 leave; Host work continues",
        " /help                 keys and commands",
        " /model                choose the model new Sessions use",
        " /rename NAME          name the selected Session",
        " /setup [OPTIONS]      future defaults",
        " › /",
        " esc close",
    });
    // Typing narrows the list; Tab completes the one left.
    const narrowed = try draftLines(&state, try typeText(&state, "/m"), 80, 24);
    defer std.testing.allocator.free(narrowed);
    try expectLines(narrowed, 21, &.{ " /model                choose the model new Sessions use", " › /m" });
    _ = try typeText(&state, "/m");
    try std.testing.expectEqualStrings("odel", state.commands.?.list.completion(0));
    _ = try typeText(&state, "/c");
    try std.testing.expectEqualStrings("onfigure ", state.commands.?.list.completion(0));
    // No list for text, `//`, a word past its command, or a name no command
    // starts.
    for ([_][]const u8{ "fix it", "//home", "/model ", "/status" }) |text| {
        errdefer std.debug.print("draft={s}\n", .{text});
        _ = try typeText(&state, text);
        try std.testing.expect(state.commands == null);
    }
}

test "a short screen lists the commands it has rows for and counts the rest" {
    var state = try opened(&mixed);
    defer state.deinit();
    // At 11 rows the draft's cap is 3 rows: the draft and two list rows,
    // the second counting the rest.
    const text = try draftLines(&state, try typeText(&state, "/"), 80, 11);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, " /configure [OPTIONS]  hold settings for the next Session") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, " +5 more · type to narrow") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/exit ") == null);
}

test "Enter runs a command by the overview's table and names its usage when misused" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/model now")));
    try expectNotice(&state, "! Usage: /model");
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/exit now")));
    try expectNotice(&state, "! Usage: /exit");
    try expectEffects(&.{.exit}, try submit(&state, try typeText(&state, "/exit ")));
}

test "Esc closes a shown command list and keeps the draft; a change opens it again" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 80, .height = 24 } }));
    var draft: Draft = .{ .bytes = "/m", .cursor = 2, .edits = 2 };
    try expectEffects(&.{}, try step(&state, .{ .composed = .{ .input = .{ .composer = .redraw }, .draft = draft } }));
    drawWithRoom(&state, draft);
    try std.testing.expectEqual(.drawn, state.commands.?.seen);
    try expectEffects(&.{}, try press(&state, draft, .clear));
    try std.testing.expectEqual(.closed, state.commands.?.seen);
    const shown = try draftLines(&state, draft, 80, 24);
    defer std.testing.allocator.free(shown);
    try expectLines(shown, 22, &.{ " › /m", " esc clear" });
    // With the list closed, Esc clears the draft.
    drawWithRoom(&state, draft);
    try std.testing.expectEqual(.closed, state.commands.?.seen);
    try expectEffects(&.{.clear_draft}, try press(&state, draft, .clear));
    // An edit opens it again.
    draft = .{ .bytes = "/mo", .cursor = 3, .edits = 3 };
    drawWithRoom(&state, draft);
    try std.testing.expectEqual(.drawn, state.commands.?.seen);
    // The hint says what Enter does to each slash draft.
    const runs = try draftLines(&state, try typeText(&state, "/exit "), 80, 24);
    defer std.testing.allocator.free(runs);
    try expectLines(runs, 23, &.{" enter run · esc clear"});
}

test "a command word wrapped past the draft's cap shows no list, and Esc clears it" {
    var state = try opened(&mixed);
    defer state.deinit();
    // At 8x9 `/configure` fills the draft's three-row cap.
    const draft = try typeText(&state, "/configure");
    var screen = try sizedRender(&state, draft, 8, 9, .{}, 0);
    defer screen.deinit();
    try std.testing.expectEqual(.hidden, screen.commands.?.seen);
    state.commands = screen.commands;
    try expectEffects(&.{.clear_draft}, try press(&state, draft, .clear));
}

test "/configure holds start settings for the Session the next Enter starts" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    draft = try typeText(&state, "/configure --permission-mode ask --label \"lane four\"");
    try expectEffects(&.{.clear_draft}, try submit(&state, draft));
    try expectNotice(&state, null);
    try expectScreenLine(&state, 23, " start settings: --permission-mode ask --label \"lane four\" · esc clear");
    // A later value replaces an earlier one; the rest stay.
    draft = try typeText(&state, "/configure --label \"lane \\\"five\\\"\" --model gpt-5.5");
    try expectEffects(&.{.clear_draft}, try submit(&state, draft));
    var buffer: [2 * start_options.len][]const u8 = undefined;
    const args = state.settings.args(&buffer);
    try std.testing.expectEqual(@as(usize, 6), args.len);
    for ([_][]const u8{ "--model", "gpt-5.5", "--permission-mode", "ask", "--label", "lane \"five\"" }, args) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try expectScreenLine(&state, 23, " start settings: --model gpt-5.5 --permission-mode ask --label \"la… · esc clear");

    var held: StartSettings = .{};
    try held.put(startOption("model").?, "gpt-5.5");
    try held.put(startOption("permission-mode").?, "ask");
    try held.put(startOption("label").?, "lane \"five\"");
    draft = try typeText(&state, "Run the tests");
    try expectEffects(&.{.{ .start = .{ .settings = &held, .text = "Run the tests" } }}, try submit(&state, draft));
    _ = try step(&state, .{ .start = .{ .started = .{ .reference = "z9y8x7".*, .handle = "h1" } } });
    try std.testing.expect(state.settings.empty());

    // Only `session start` options, in the conversation's grammar, are held.
    for ([_]struct { []const u8, []const u8 }{
        .{ "/configure --instructions -", "! Set --instructions after the start" },
        .{ "/configure --text-output", "! Set --text-output after the start" },
        .{ "/configure --help", configure_usage },
        .{ "/configure --bogus 1", configure_usage },
        .{ "/configure --label \"open", configure_usage },
        // The Host would admit it; its Turns would fail at the provider.
        .{ "/configure --model \"gpt 5\"", "! Not a model ID; session configure -h" },
        .{ "/status", "! Unknown command /status · /help" },
    }) |case| {
        draft = try typeText(&state, case[0]);
        try expectEffects(&.{}, try submit(&state, draft));
        try if (case[1].ptr == configure_usage.ptr) expectNoticeWithData(&state, case[1]) else expectNotice(&state, case[1]);
        try std.testing.expect(state.settings.empty());
    }
    // Alone, /configure waits for an option: Enter on it in the list adds
    // the space that shows them.
    draft = try typeText(&state, "/configure");
    try expectEffects(&.{.{ .append = " " }}, try submit(&state, draft));
    // A model Rui does not list is held, with a quiet word on its limits.
    draft = try typeText(&state, "/configure --model unlisted-model");
    try expectEffects(&.{.clear_draft}, try submit(&state, draft));
    try std.testing.expectEqualStrings("unlisted-model", state.settings.get(startOption("model").?).?);
    try std.testing.expectEqual(Colour.quiet, state.notice.?.colour);
}

fn expectStyle(state: *State, row: usize, column: usize, expected: Style) !void {
    var screen = try sizedRender(state, .{}, 80, 24, .{}, 0);
    defer screen.deinit();
    try std.testing.expectEqual(cellStyle(screen.caps, expected), screen.styleAt(row, column).?);
}

fn expectScreenLine(state: *State, line: usize, expected: []const u8) !void {
    const text = try screenText(state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    for (0..line) |_| _ = lines.next();
    try std.testing.expectEqualStrings(expected, lines.next().?);
}

test "a line the editor rejects says why once; text it could not take clears" {
    var draft: Draft = .{};
    for ([_]struct { keymap.Outcome(Action), []const u8, bool }{
        .{ .{ .refused = .invalid }, "! Not valid text; nothing sent.", true },
        .{ .{ .refused = .overflow }, "! Too long to send.", true },
        .{ .{ .refused = .edit_rejected }, "! Can't add that character alone.", false },
        .{ .{ .refused = .unbound }, "! That key does nothing here.", false },
    }) |case| {
        var state = try opened(&mixed);
        defer state.deinit();
        draft = try typeText(&state, "first");
        const effects = try step(&state, .{ .composed = .{ .input = .{ .composer = case[0] }, .draft = draft } });
        try expectEffects(if (case[2]) &.{.clear_draft} else &.{}, effects);
        try expectNotice(&state, case[1]);
        // The next edit clears the notice.
        draft = try typeText(&state, "second");
        try expectNotice(&state, null);
    }
}

test "an unconfirmed start clears the composer and names the request that recovers it" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try writeDeparture(&state, null, &departure.writer);
    try std.testing.expectEqualStrings("", departure.written());

    draft = try typeText(&state, "/configure --permission-mode ask");
    _ = try submit(&state, draft);
    draft = try typeText(&state, "Fix the flaky resize test");
    _ = try submit(&state, draft);
    const handle = "0f8e2c1a-7b3d-4e5f-9a6b-1c2d3e4f5a6b";
    // Another Enter would be a second Session, so the text is not kept.
    try expectEffects(&.{.clear_draft}, try step(&state, .{ .start = .{ .unconfirmed = handle } }));
    try std.testing.expect(!state.starting());
    try std.testing.expect(state.settings.empty());
    try expectNotice(&state, "! Start unsure; details on exit");
    try expectScreenLine(&state, 23, " ! Start unsure; details on exit");
    // The next tick lists at once, so a start that did land shows.
    try expectEffects(&.{.{ .list = testToken(1) }}, try step(&state, .{ .tick = state.now_ms + 1 }));
    // A second unconfirmed start keeps the first one's handle.
    const second = "9a0b1c2d-3e4f-4a6b-8c7d-0f8e2c1a7b3d";
    draft = try typeText(&state, "Fix it again");
    _ = try submit(&state, draft);
    try expectEffects(&.{.clear_draft}, try step(&state, .{ .start = .{ .unconfirmed = second } }));
    try writeDeparture(&state, null, &departure.writer);
    try std.testing.expectEqualStrings("rui: Not sure the new Session started. Check with: rui request recover " ++ handle ++ "\n" ++
        "rui: Not sure the new Session started. Check with: rui request recover " ++ second ++ "\n", departure.written());
}

test "the cursor sits at the composer's caret and hides while a start is pending" {
    var draft: Draft = .{};
    var state = try opened(&mixed);
    defer state.deinit();
    const Expect = struct {
        fn cursor(from: *State, typed: Draft, width: u16, expected: ?Rendered.Cursor) !void {
            var screen = try sizedRender(from, typed, width, 24, .{}, 0);
            defer screen.deinit();
            try std.testing.expectEqual(expected, screen.cursor);
        }
        fn composerLine(from: *State, typed: Draft, expected: []const u8) !void {
            var screen = try sizedRender(from, typed, 80, 24, .{}, 0);
            defer screen.deinit();
            var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer text.deinit();
            try screen.write(&text.writer);
            var lines = std.mem.splitScalar(u8, text.written(), '\n');
            for (0..22) |_| _ = lines.next();
            try std.testing.expectEqualStrings(expected, lines.next().?);
        }
    };
    try Expect.cursor(&state, draft, 80, .{ .row = 22, .column = 3 });
    draft = try typeText(&state, "Fix 中");
    try Expect.cursor(&state, draft, 80, .{ .row = 22, .column = 9 });
    // The caret sits where the editor holds it, with the text after it.
    draft.cursor = 4;
    try Expect.cursor(&state, draft, 80, .{ .row = 22, .column = 7 });
    try Expect.composerLine(&state, draft, " › Fix 中");
    // A draft wider than the composer wraps between words into rows that
    // grow upward from the bottom: "Fix ", 76 x, then 24 x and " end".
    const long = "Fix " ++ @as([100]u8, @splat('x')) ++ " end";
    draft = try typeText(&state, long);
    try Expect.cursor(&state, draft, 80, .{ .row = 22, .column = 31 });
    // Two cells wide, the space before "end" hangs past the edge: "en",
    // then "d".
    try Expect.cursor(&state, draft, 6, .{ .row = 22, .column = 4 });
    // On the soft break after "Fix ", the caret starts the next row.
    draft.cursor = 4;
    try Expect.cursor(&state, draft, 80, .{ .row = 21, .column = 3 });
    try Expect.composerLine(&state, draft, "   " ++ @as([24]u8, @splat('x')) ++ " end");
    draft.cursor = long.len;
    _ = try submit(&state, draft);
    try Expect.cursor(&state, draft, 80, null);
}

test "a draft past its cap scrolls inside the composer and the rule counts what it hides" {
    var state = try opened(&mixed);
    defer state.deinit();
    const text = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13";
    const Expect = struct {
        fn rows(from: *State, typed: Draft, caps: Caps, rule: []const u8, top: []const u8, anchor: usize) !void {
            var screen = try sizedRender(from, typed, 40, 40, caps, 0);
            defer screen.deinit();
            var written: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer written.deinit();
            try screen.write(&written.writer);
            var lines = std.mem.splitScalar(u8, written.written(), '\n');
            for (0..28) |_| _ = lines.next();
            // Ten rows of draft under the rule, the hints on the last row.
            try std.testing.expectEqualStrings(rule, lines.next().?);
            try std.testing.expectEqualStrings(top, lines.next().?);
            try std.testing.expectEqual(anchor, screen.draft_anchor);
        }
    };
    // At the end, the first three lines are hidden above.
    var draft: Draft = .{ .bytes = text, .cursor = text.len };
    try Expect.rows(&state, draft, .{}, " ─────────── ↑ 3 more lines ───────────", "   4", 6);
    // The caret moving up inside the shown lines keeps them.
    draft = .{ .bytes = text, .cursor = 10, .anchor = 2 };
    try Expect.rows(&state, draft, .{}, " ──────── ↑ 1 · ↓ 2 more lines ────────", "   2", 2);
    // Above them, the composer follows the caret to the top.
    draft = .{ .bytes = text, .cursor = 0, .anchor = 6 };
    try Expect.rows(&state, draft, .{}, " ─────────── ↓ 3 more lines ───────────", " › 1", 0);
    // Without Unicode the rule draws in ASCII.
    draft = .{ .bytes = text, .cursor = text.len };
    try Expect.rows(&state, draft, .{ .unicode = false }, " ----------- ^ 3 more lines -----------", "   4", 6);
}

test "a first line arriving titles its unlabelled row" {
    var state = try testState();
    defer state.deinit();
    _ = try step(&state, .{ .tick = test_now_s * 1000 });
    var reads: Reads = .{};
    for ([_]struct { *const [6]u8, u64 }{ .{ "h8q2mz", 4 }, .{ "f6g7h8", 9 }, .{ "p3q4r5", 4 } }) |read| {
        reads.items[reads.len] = .{ .reference = read[0].*, .position = 1, .admission = read[1] };
        reads.len += 1;
    }
    // Rows in screen order; a labelled row or one with no Message needs none.
    try expectEffects(&.{.{ .read_first_lines = reads }}, try respond(&state, .full, testToken(1), &mixed));
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "h8q2mz".*, .admission = 4, .line = "  summarize yesterday's CI failures\r\nand say which are new" } }));
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "f6g7h8".*, .admission = 9, .line = null } }));
    // Another admission is another Message: ignored.
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "p3q4r5".*, .admission = 5, .line = "not this one" } }));
    try std.testing.expectEqualStrings("summarize yesterday's CI failures", state.lineOf(state.find("h8q2mz".*).?).?);
    try std.testing.expectEqual(Line.unavailable, state.find("f6g7h8".*).?.line);
    try std.testing.expectEqual(Line.requested, state.find("p3q4r5".*).?.line);
    try expectScreenLine(&state, 7, "  ✓ summarize yesterday's CI failures                                       12m");
    // Lines in flight or unreadable are not asked for again, and a refresh
    // that replaces a row keeps the line of its unchanged first Message.
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(2), &.{session("h8q2mz", .{ .working = ago(0) }, .{ .yours = true })}));
    try std.testing.expectEqualStrings("summarize yesterday's CI failures", state.lineOf(state.find("h8q2mz".*).?).?);
    // An unreadable line is not asked for again while listings, changed or
    // full, name its unchanged first Message.
    const f6g7h8 = session("f6g7h8", .{ .idle = ago(0) }, .{ .workspace = "/home/d/code/other", .first = .{ .position = 1, .admission = 9, .sender = "k7m2qx".* } });
    try expectEffects(&.{}, try refresh(&state, .changed, testToken(3), &.{f6g7h8}));
    // The full listing finds h8q2mz's next Turn finished after the working
    // above.
    var next_turn = mixed;
    next_turn[1].turn = 2;
    try expectEffects(&.{.{ .notify = .{ .name = "summarize yesterday's CI failures", .kind = .finished, .more = 0 } }}, try refresh(&state, .full, testToken(4), &next_turn));
    try std.testing.expectEqual(Line.unavailable, state.find("f6g7h8".*).?.line);
    try std.testing.expectEqualStrings("summarize yesterday's CI failures", state.lineOf(state.find("h8q2mz".*).?).?);
    // Results nobody asked for are ignored: a second answer for a read line,
    // or one for a row whose line is unread.
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "h8q2mz".*, .admission = 4, .line = "a second answer" } }));
    try expectEffects(&.{}, try step(&state, .{ .first_line = .{ .reference = "f6g7h8".*, .admission = 9, .line = "a late answer" } }));
    try std.testing.expectEqual(@as(usize, 1), state.lines.items.len);
    try std.testing.expectEqualStrings("summarize yesterday's CI failures", state.lineOf(state.find("h8q2mz".*).?).?);
    try std.testing.expectEqual(Line.unavailable, state.find("f6g7h8".*).?.line);
    // A new first Message is asked for.
    var again: Reads = .{};
    again.items[0] = .{ .reference = "f6g7h8".*, .position = 2, .admission = 12 };
    again.len = 1;
    try expectEffects(&.{.{ .read_first_lines = again }}, try refresh(&state, .changed, testToken(5), &.{session("f6g7h8", .{ .idle = ago(0) }, .{ .first = .{ .position = 2, .admission = 12, .sender = null } })}));
}

test "Host facts give the health line, and a row from before a restart still says working" {
    var state = try opened(&.{
        session("k7m2qx", .{ .working = ago(40) }, .{ .label = "Admitted before the restart" }),
        session("h8q2mz", .{ .working = ago(5) }, .{ .label = "Admitted after it" }),
        session("d4e5f6", .{ .pending = ago(5) }, .{ .label = "Waiting for a slot" }),
    });
    defer state.deinit();
    const before = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(before);
    try expectScreenLine(&state, 2, "");
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s - 20, .slots = 2, .slots_in_use = 2 } });
    try expectScreenLine(&state, 2, " Host up 20s   slots 2/2");
    try expectStyle(&state, 2, 15, .{ .colour = .ink });
    const after = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before[std.mem.indexOf(u8, before, " Active").?..], after[std.mem.indexOf(u8, after, " Active").?..]);
    // Full slots draw in ink, free ones in the normal colour.
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s - 20, .slots = 2, .slots_in_use = 1 } });
    try expectScreenLine(&state, 2, " Host up 20s   slots 1/2");
    try expectStyle(&state, 2, 15, .{});
}

test "a row from another Workspace keeps its title at every width" {
    var state = try opened(&.{
        session("a1b2c3", .{ .working = ago(5) }, .{ .label = "Profile the queue", .workspace = "/srv/elsewhere/project" }),
        session("d4e5f6", .{ .working = ago(5) }, .{ .label = "Trace the shutdown", .workspace = "/srv/elsewhere/project" }),
    });
    defer state.deinit();
    for (40..120) |width| {
        const text = try screenText(&state, @intCast(width), 24, .{});
        defer std.testing.allocator.free(text);
        // Each title shows at least its first word, and never fewer cells
        // than the Workspace beside it.
        try std.testing.expect(std.mem.indexOf(u8, text, "Profile") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Trace") != null);
        const columns = Columns.of(width);
        try std.testing.expect(columns.workspace == 0 or columns.word -| 2 -| Columns.title -| 2 -| columns.workspace >= columns.workspace);
    }
}

test "the selection stays on its Session when it moves from active to finished" {
    var state = try opened(&mixed);
    defer state.deinit();
    for (0..3) |_| _ = try press(&state, .{}, .next);
    try expectSelected(&state, "e5f6g7");
    _ = try refresh(&state, .changed, testToken(2), &.{session("e5f6g7", .{ .finished = ago(0) }, .{ .label = "List unused build steps" })});
    try expectSelected(&state, "e5f6g7");
    try std.testing.expectEqual(Group.finished, state.find("e5f6g7".*).?.group());
    try expectEffects(&.{.{ .open = "e5f6g7".* }}, try submit(&state, .{}));
    try expectScreenLine(&state, 20, "  ✓ List unused build steps                                                  1s");
    // Moving on goes to the next row on screen, not the next old index.
    _ = try press(&state, .{}, .next);
    try expectSelected(&state, "m1n2p3");
    // A selected row that lands among a folded group's hidden rows opens the group.
    _ = try refresh(&state, .changed, testToken(3), &.{session("m1n2p3", .{ .finished = ago(10 * 86400) }, .{ .label = "Explain provider output parsing" })});
    try expectSelected(&state, "m1n2p3");
    try std.testing.expect(state.unfolded.contains(.finished));
}

test "the overview lists once a second, one listing at a time" {
    var state = try testState();
    defer state.deinit();
    const start = test_now_s * 1000;
    try expectEffects(&.{.{ .list = null }}, try step(&state, .{ .tick = start }));
    try expectEffects(&.{}, try step(&state, .{ .tick = start + 2 * list_interval_ms }));
    _ = try respond(&state, .full, testToken(1), &mixed);
    try expectEffects(&.{.{ .list = testToken(1) }}, try step(&state, .{ .tick = start + 2 * list_interval_ms }));
    try expectEffects(&.{}, try step(&state, .{ .tick = start + 2 * list_interval_ms + 500 }));
    // A Host that stops answering fades the rows and says since when.
    try expectEffects(&.{}, try step(&state, .{ .list = .failed }));
    try expectEffects(&.{.{ .list = testToken(1) }}, try step(&state, .{ .tick = start + 3 * list_interval_ms }));
    try expectEffects(&.{}, try step(&state, .{ .list = .failed }));
    try expectScreenLine(&state, 1, " Host stopped 0s ago. Run rui host start.");
    try expectScreenLine(&state, 2, " Host not responding. Last update 1s ago.");
    var screen = try sizedRender(&state, .{}, 80, 24, .{}, 0);
    defer screen.deinit();
    try std.testing.expectEqual(cellStyle(screen.caps, Style{ .colour = .quiet }), screen.styleAt(7, 2).?);
    _ = try refresh(&state, .not_modified, testToken(1), &.{});
    try expectScreenLine(&state, 1, " Running. 20 Sessions. 2 failed.");
}

test "a tick moves a retry that fell due to pending" {
    var state = try opened(&mixed);
    defer state.deinit();
    try std.testing.expect(state.find("c3d4e5".*).?.state == .retrying);
    _ = try step(&state, .{ .tick = (test_now_s + 12) * 1000 });
    const row = state.find("c3d4e5".*).?;
    try std.testing.expectEqual(WorkState{ .pending = .{ .since = test_now_s + 12 } }, row.state);
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "  ◌ Audit permission paths                                                   0s\n") != null);
}

/// Renders `state` at 80x24 and 200x60 and compares both screens.
/// Renders `state` at 80x24 and 200x60 and compares both screens, and the
/// 80x24 screen's styles.
fn expectScreens(state: *State, caps: Caps, small: []const u8, small_styles: []const u8, large: []const u8) !void {
    try expectScreen(state, 80, 24, caps, small);
    try expectStyles(state, 80, 24, caps, small_styles);
    try expectScreen(state, 200, 60, caps, large);
}

/// One letter per cell: `.` unstyled; `s`trong, `i`nk, `n`ormal, `q`uiet,
/// `m`ark, ru`l`e, `a`ttention, `f`ailure or `b`and colour; `r` selected or
/// reversed. Capitals are bold.
fn expectStyles(state: *State, width: u16, height: u16, caps: Caps, expected: []const u8) !void {
    var screen = try sizedRender(state, .{}, width, height, caps, 0);
    defer screen.deinit();
    const letters = "sinqmlafb";
    var lines = std.mem.splitScalar(u8, expected, '\n');
    for (0..height) |row| {
        const line = lines.next() orelse return error.TestMissingStyleRow;
        for (line, 0..) |mark, col| {
            const cell = screen.cell(col, row);
            if (mark == '.') {
                try std.testing.expectEqualStrings(" ", cell.char.grapheme);
                try std.testing.expectEqual(cellStyle(caps, .{}), cell.style);
                continue;
            }
            const lower = std.ascii.toLower(mark);
            try std.testing.expectEqual(std.ascii.isUpper(mark), cell.style.bold);
            if (lower == 'r') {
                if (caps.depth == .none) try std.testing.expect(cell.style.reverse) else try std.testing.expectEqual(cellStyle(caps, .{ .background = .selection }).bg, cell.style.bg);
            } else {
                const index = std.mem.indexOfScalar(u8, letters, lower) orelse return error.TestUnknownStyle;
                const wanted = cellStyle(caps, .{ .colour = std.enums.values(Colour)[index] });
                try std.testing.expectEqual(wanted.fg, cell.style.fg);
            }
        }
        // No styled payload past the snapshot's final explicit cell.
        for (line.len..width) |col| {
            const cell = screen.cell(col, row);
            try std.testing.expectEqualStrings(" ", cell.char.grapheme);
            try std.testing.expectEqual(cellStyle(caps, .{}), cell.style);
        }
    }
}

fn expectBand(rows: []const Listed, small: []const u8, small_styles: []const u8, large: []const u8) !void {
    var state = try opened(rows);
    defer state.deinit();
    try expectScreens(&state, .{}, small, small_styles, large);
    // The band spans the line, in its colour or, without colour, reversed.
    for ([_]Caps{ .{}, .{ .depth = .none } }, [_]Style{ .{ .colour = .on_band, .background = .band, .bold = true }, .{ .bold = true, .reverse = true } }) |caps, style| {
        var screen = try sizedRender(&state, .{}, 80, 24, caps, 0);
        defer screen.deinit();
        try std.testing.expectEqual(cellStyle(caps, style), screen.styleAt(1, 0).?);
        try std.testing.expectEqual(cellStyle(caps, style), screen.styleAt(1, 79).?);
    }
}

test "a quota reset far in the future still draws its band" {
    var state = try opened(&.{failedRow("q1q1q1", 60, "provider_quota", 100_000_000_000_000_000)});
    defer state.deinit();
    try expectScreenLine(&state, 1, " Quota used up. Resets in 999d.");
}

test "render draws each band" {
    const done = session("ffffff", .{ .finished = ago(600) }, .{ .label = "Summarize the CI failures" });
    try expectBand(&.{ done, failedRow("aaaaaa", 60, "provider_sign_in_refresh_token_expired", null) },
        \\ रुई rui  ~/code/rui
        \\ Sign-in expired. Run rui auth login codex.
        \\
        \\
        \\ Finished · 1
        \\  ✓ Summarize the CI failures                                               10m
        \\
        \\ Stopped or failed · 1
        \\  × Ask the model                                                            1m
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\ ↑↓ select · enter open
        \\
    ,
        \\SSSSSSSnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        \\
        \\
        \\.IIIIIIIIqqqq
        \\.rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
        \\
        \\.IIIIIIIIIIIIIIIIIqqqq
        \\..f.qqqqqqqqqqqqq............................................................qq
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\.llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll
        \\.n.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqq
        \\
    ,
        \\ रुई rui  ~/code/rui
        \\ Sign-in expired. Run rui auth login codex.
        \\
        \\
        \\ Finished · 1
        \\  ✓ Summarize the CI failures                                                                                                                                                                       10m
        \\
        \\ Stopped or failed · 1
        \\  × Ask the model                                                                                                                                                                                    1m
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\ ↑↓ select · enter open
        \\
    );
    try expectBand(&.{ done, failedRow("aaaaaa", 60, "provider_quota", test_now_s + 20 * 60) },
        \\ रुई rui  ~/code/rui
        \\ Quota used up. Resets in 20m.
        \\
        \\
        \\ Finished · 1
        \\  ✓ Summarize the CI failures                                               10m
        \\
        \\ Stopped or failed · 1
        \\  × Ask the model                                                            1m
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\ ↑↓ select · enter open
        \\
    ,
        \\SSSSSSSnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        \\
        \\
        \\.IIIIIIIIqqqq
        \\.rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
        \\
        \\.IIIIIIIIIIIIIIIIIqqqq
        \\..f.qqqqqqqqqqqqq............................................................qq
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\.llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll
        \\.n.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqq
        \\
    ,
        \\ रुई rui  ~/code/rui
        \\ Quota used up. Resets in 20m.
        \\
        \\
        \\ Finished · 1
        \\  ✓ Summarize the CI failures                                                                                                                                                                       10m
        \\
        \\ Stopped or failed · 1
        \\  × Ask the model                                                                                                                                                                                    1m
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\ ↑↓ select · enter open
        \\
    );
    try expectBand(&.{ retryRow("aaaaaa", "provider_temporary_http_429", 10), retryRow("bbbbbb", "provider_temporary_http_429", 20) },
        \\ रुई rui  ~/code/rui
        \\ Rate limited. 2 Sessions will retry.
        \\
        \\
        \\ Active · 2
        \\  ● Ask the model again                      Rate limited · retry 1 in 10s   5s
        \\  ● Ask the model again                      Rate limited · retry 1 in 20s   5s
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\ ↑↓ select · enter open · ctrl+x stop
        \\
    ,
        \\SSSSSSSnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        \\
        \\
        \\.IIIIIIqqqq
        \\.rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
        \\..a.iiiiiiiiiiiiiiiiiii......................aaaaaaaaaaaaaaaaaaaaaaaaaaaaa...qq
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\.llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll
        \\.n.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\
    ,
        \\ रुई rui  ~/code/rui
        \\ Rate limited. 2 Sessions will retry.
        \\
        \\
        \\ Active · 2
        \\  ● Ask the model again                                                                                                                              Rate limited · retry 1 in 10s                   5s
        \\  ● Ask the model again                                                                                                                              Rate limited · retry 1 in 20s                   5s
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\ ↑↓ select · enter open · ctrl+x stop
        \\
    );
}

test "render draws an empty Store" {
    var state = try opened(&.{});
    defer state.deinit();
    try expectScreens(&state, .{},
        \\ रुई rui  ~/code/rui
        \\ No Sessions yet. Type a task below.
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\
        \\
    ,
        \\SSSSSSSnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\.llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll
        \\.n.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\
        \\
    ,
        \\ रुई rui  ~/code/rui
        \\ No Sessions yet. Type a task below.
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\
        \\
    );
}

test "render draws twenty mixed rows" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectScreens(&state, .{},
        \\ रुई rui  ~/code/rui
        \\ Running. 20 Sessions. 2 failed.
        \\
        \\
        \\ Yours · 3
        \\  ⠋ Fix the flaky resize test                                               40s
        \\  ○ Review PR 412                                    Needs approval          3m
        \\  ✓ h8q2mz                                                                  12m
        \\
        \\ Active · 5
        \\  ● List unused build steps                          Stopping…               8s
        \\  ● Audit permission paths                 Provider error · retry 2 in 12s  30s
        \\  ● Find why store tests fail                        Run the logic tests     1m
        \\  ● f6g7h8                             ~/code/other                          1m
        \\  ● Profile the curl send queue                                              2m
        \\
        \\ Queued · 1
        \\  ◌ Trace Host shutdown order                                                5s
        \\
        \\ Idle · 1
        \\  ○ Check macOS socket cleanup                                               2h
        \\ ──────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\ ↑↓ select · enter open · ctrl+x stop
        \\
    ,
        \\SSSSSSSnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\.SSSSSSSS.nnnnnnnnnnnnnnnnnnnnnn
        \\
        \\
        \\.IIIIIqqqq
        \\.rrRRRRRRRRRRRRRRRRRRRRRRRRRRrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
        \\..a.SSSSSSSSSSSSS....................................aaaaaaaaaaaaaa..........qq
        \\..m.SSSSSS..................................................................qqq
        \\
        \\.IIIIIIqqqq
        \\..q.iiiiiiiiiiiiiiiiiiiiiii..........................qqqqqqqqq...............qq
        \\..a.iiiiiiiiiiiiiiiiiiiiii.................aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa..qqq
        \\..i.iiiiiiiiiiiiiiiiiiiiiiiii........................nnnnnnnnnnnnnnnnnnn.....qq
        \\..i.qqqqqq.............................nnnnnnnnnnnn..........................qq
        \\..i.iiiiiiiiiiiiiiiiiiiiiiiiiii..............................................qq
        \\
        \\.IIIIIIqqqq
        \\..n.iiiiiiiiiiiiiiiiiiiiiiiii................................................qq
        \\
        \\.IIIIqqqq
        \\..n.iiiiiiiiiiiiiiiiiiiiiiiiii...............................................qq
        \\.llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll
        \\.n.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\.qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
        \\
    ,
        \\ रुई rui  ~/code/rui
        \\ Running. 20 Sessions. 2 failed.
        \\
        \\
        \\ Yours · 3
        \\  ⠋ Fix the flaky resize test                                                                                                                                                                       40s
        \\  ○ Review PR 412                                                                                                                                    Needs approval                                  3m
        \\  ✓ h8q2mz                                                                                                                                                                                          12m
        \\
        \\ Active · 5
        \\  ● List unused build steps                                                                                                                          Stopping…                                       8s
        \\  ● Audit permission paths                                                                                                                           Provider error · retry 2 in 12s                30s
        \\  ● Find why store tests fail                                                                                                                        Run the logic tests                             1m
        \\  ● f6g7h8                                                                                                                             ~/code/other                                                  1m
        \\  ● Profile the curl send queue                                                                                                                                                                      2m
        \\
        \\ Queued · 1
        \\  ◌ Trace Host shutdown order                                                                                                                                                                        5s
        \\
        \\ Idle · 1
        \\  ○ Check macOS socket cleanup                                                                                                                                                                       2h
        \\
        \\ Finished · 7
        \\  ✓ Explain provider output parsing                                                                                                                                                                 20m
        \\  ✓ Find the commit that broke WAL                                                                                                                                                                  45m
        \\  ✓ p3q4r5                                                                                                                                                                                           1h
        \\  ✓ Summarize the build cache study                                                                                                                                                                  3h
        \\  ✓ Check the release notes                                                                                                               /srv/work                                                  2d
        \\   2 more
        \\
        \\ Stopped or failed · 3
        \\  × Bisect the WAL regression                                                                                                                        failed · for "Fix the flaky resize test"       15m
        \\  ■ Rename the session tables                                                                                                                        stopped · for zzzzzz                           30m
        \\  × Retry the flaky upload                                                                                                                                                                          50m
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
        \\ › Type a task to start a Session
        \\ ↑↓ select · enter open · ctrl+x stop
        \\
    );
}

test "render draws ASCII without colour" {
    var state = try opened(&mixed);
    defer state.deinit();
    _ = try step(&state, .{ .first_line = .{ .reference = "h8q2mz".*, .admission = 4, .line = "résumé the naïve café ☕ notes" } });
    const caps: Caps = .{ .unicode = false, .depth = .none };
    try expectScreens(&state, caps,
        \\ rui  ~/code/rui
        \\ Running. 20 Sessions. 2 failed.
        \\
        \\
        \\ Yours - 3
        \\  * Fix the flaky resize test                                               40s
        \\  o Review PR 412                                    Needs approval          3m
        \\  + r?sum? the na?ve caf? ? notes                                           12m
        \\
        \\ Active - 5
        \\  * List unused build steps                          Stopping.               8s
        \\  * Audit permission paths                 Provider error - retry 2 in 12s  30s
        \\  * Find why store tests fail                        Run the logic tests     1m
        \\  * f6g7h8                             ~/code/other                          1m
        \\  * Profile the curl send queue                                              2m
        \\
        \\ Queued - 1
        \\  : Trace Host shutdown order                                                5s
        \\
        \\ Idle - 1
        \\  o Check macOS socket cleanup                                               2h
        \\ ------------------------------------------------------------------------------
        \\ > Type a task to start a Session
        \\ ^v select - enter open - ctrl+x stop
        \\
    ,
        \\.NNN..nnnnnnnnnn
        \\.NNNNNNNN.nnnnnnnnnnnnnnnnnnnnnn
        \\
        \\
        \\.NNNNNnnnn
        \\rrrRRRRRRRRRRRRRRRRRRRRRRRRRRrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
        \\..n.NNNNNNNNNNNNN....................................nnnnnnnnnnnnnn..........nn
        \\..n.NNNNNNNNNNNNNNNNNNNNNNNNNNNNN...........................................nnn
        \\
        \\.NNNNNNnnnn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnn..........................nnnnnnnnn...............nn
        \\..n.nnnnnnnnnnnnnnnnnnnnnn.................nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn..nnn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnn........................nnnnnnnnnnnnnnnnnnn.....nn
        \\..n.nnnnnn.............................nnnnnnnnnnnn..........................nn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnnnn..............................................nn
        \\
        \\.NNNNNNnnnn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnn................................................nn
        \\
        \\.NNNNnnnn
        \\..n.nnnnnnnnnnnnnnnnnnnnnnnnnn...............................................nn
        \\.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\.n.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\.nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn
        \\
    ,
        \\ rui  ~/code/rui
        \\ Running. 20 Sessions. 2 failed.
        \\
        \\
        \\ Yours - 3
        \\  * Fix the flaky resize test                                                                                                                                                                       40s
        \\  o Review PR 412                                                                                                                                    Needs approval                                  3m
        \\  + r?sum? the na?ve caf? ? notes                                                                                                                                                                   12m
        \\
        \\ Active - 5
        \\  * List unused build steps                                                                                                                          Stopping.                                       8s
        \\  * Audit permission paths                                                                                                                           Provider error - retry 2 in 12s                30s
        \\  * Find why store tests fail                                                                                                                        Run the logic tests                             1m
        \\  * f6g7h8                                                                                                                             ~/code/other                                                  1m
        \\  * Profile the curl send queue                                                                                                                                                                      2m
        \\
        \\ Queued - 1
        \\  : Trace Host shutdown order                                                                                                                                                                        5s
        \\
        \\ Idle - 1
        \\  o Check macOS socket cleanup                                                                                                                                                                       2h
        \\
        \\ Finished - 7
        \\  + Explain provider output parsing                                                                                                                                                                 20m
        \\  + Find the commit that broke WAL                                                                                                                                                                  45m
        \\  + p3q4r5                                                                                                                                                                                           1h
        \\  + Summarize the build cache study                                                                                                                                                                  3h
        \\  + Check the release notes                                                                                                               /srv/work                                                  2d
        \\   2 more
        \\
        \\ Stopped or failed - 3
        \\  x Bisect the WAL regression                                                                                                                        failed - for "Fix the flaky resize test"       15m
        \\  # Rename the session tables                                                                                                                        stopped - for zzzzzz                           30m
        \\  x Retry the flaky upload                                                                                                                                                                          50m
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\
        \\ ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        \\ > Type a task to start a Session
        \\ ^v select - enter open - ctrl+x stop
        \\
    );
    var screen = try sizedRender(&state, .{}, 200, 60, caps, 0);
    defer screen.deinit();
    for (0..screen.height) |row| for (0..screen.width) |col| {
        const cell = screen.cell(col, row);
        try std.testing.expect(cell.style.fg == .default);
        for (cell.char.grapheme) |byte| try std.testing.expect(byte < 0x80);
    };
    // The selection is reverse video across the whole line, as before the
    // painted skins.
    for ([_]usize{ 0, 1, 199 }) |column| try std.testing.expect(screen.styleAt(5, column).?.reverse);
}

test "render fits any screen size" {
    var state = try opened(&mixed);
    defer state.deinit();
    for ([_][2]u16{ .{ 0, 0 }, .{ 8, 2 }, .{ 20, 5 }, .{ 40, 10 }, .{ 119, 30 }, .{ 2048, 24 }, .{ 4096, 6 } }) |size| {
        var screen = try sizedRender(&state, .{}, size[0], size[1], .{}, 0);
        defer screen.deinit();
        try std.testing.expectEqual(size[1], screen.height);
        for (0..screen.height) |row| for (0..screen.width) |col| {
            const cell = screen.cell(col, row);
            try std.testing.expect(col + cell.char.width <= screen.width);
        };
        const text = try screenText(&state, size[0], size[1], .{});
        std.testing.allocator.free(text);
    }
}

test "the composer needs six rows and six columns, and shows nothing smaller" {
    var state = try opened(&mixed);
    defer state.deinit();
    for (1..9) |w| for (1..9) |h| {
        const width: u16 = @intCast(w);
        const height: u16 = @intCast(h);
        var screen = try sizedRender(&state, .{ .bytes = "draft", .cursor = 5 }, width, height, .{}, 0);
        defer screen.deinit();
        const fits = width >= 6 and height >= 6;
        try std.testing.expectEqual(fits, screen.cursor != null);
        if (screen.cursor) |cursor| {
            try std.testing.expectEqual(height - 2, cursor.row);
            try std.testing.expect(cursor.column < width);
        }
    };
}

test "a full-capacity draft of spaces keeps the composer's caret on screen" {
    var state = try opened(&mixed);
    defer state.deinit();
    const spaces: [65536]u8 = @splat(' ');
    var screen = try sizedRender(&state, .{ .bytes = &spaces, .cursor = spaces.len }, 80, 24, .{}, 0);
    defer screen.deinit();
    try std.testing.expectEqual(@as(?Rendered.Cursor, .{ .row = 22, .column = 3 }), screen.cursor);
}

test "every line fits the screen as the terminal measures it" {
    var draft: Draft = .{};
    const rockets = comptime repeated("🚀", 50);
    var state = try opened(&.{
        session("k7m2qx", .{ .working = ago(1) }, .{ .label = rockets[0..max_label_bytes] }),
        session("r4t9vw", .{ .idle = ago(60) }, .{ .label = "修复存储测试在第二次运行时失败的原因并说明哪些是新问题", .workspace = "/home/d/代码/存储" }),
        session("h8q2mz", .{ .finished = ago(90) }, .{ .label = comptime repeated("👨‍👩‍👧‍👦", 4) }),
        session("m3n8pd", .{ .failed = .{ .since = test_now_s - 120, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .{ .label = comptime repeated("Cafe\u{301} ", 14) }),
    });
    defer state.deinit();
    draft = try typeText(&state, rockets);
    for ([_]Caps{ .{ .width = .unicode }, .{ .width = .wcwidth }, .{ .unicode = false } }) |caps| for ([_]u16{ 80, 41, 24 }) |width| {
        var screen = try sizedRender(&state, draft, width, 24, caps, 0);
        defer screen.deinit();
        for (0..screen.height) |row| {
            var col: usize = 0;
            while (col < screen.width) {
                const cell = screen.cell(col, row);
                try std.testing.expectEqual(gwidth.gwidth(cell.char.grapheme, caps.width), cell.char.width);
                col += @max(cell.char.width, 1);
            }
        }
        const text = try screenText(&state, width, 24, caps);
        defer std.testing.allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| try std.testing.expect(gwidth.gwidth(line, caps.width) <= width);
    };
}

test "bidi controls in a title or a starter's Label cannot reorder a row" {
    const bidi = "\u{202e}\u{2066}\u{200f}\u{061c}";
    var state = try opened(&.{
        session("k7m2qx", .{ .working = ago(5) }, .{ .label = "Pay " ++ bidi ++ "evil" }),
        session("t7v8w9", .{ .stopped = .{ .since = test_now_s - 30, .cause = .stop } }, .{ .label = "Next", .first = .{ .position = 1, .admission = 2, .sender = "k7m2qx".* } }),
    });
    defer state.deinit();
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Pay ????evil") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "for \"Pay ?") != null);
    for ([_][]const u8{ "\u{202e}", "\u{2066}", "\u{200f}", "\u{061c}" }) |control| try std.testing.expect(std.mem.indexOf(u8, text, control) == null);
}

test "untrusted text cannot reach the terminal as control bytes" {
    var state = try opened(&.{session("k7m2qx", .{ .working = ago(5) }, .{ .label = "Bell\x07 and \x1b[31mred" })});
    defer state.deinit();
    try expectScreenLine(&state, 5, "  ● Bell? and ?[31mred                                                       5s");
}

test "only the finished and the failed or stopped groups fold" {
    var rows: [8]Listed = undefined;
    for (&rows, 0..) |*row, n| row.* = session(&[6]u8{ 'i', 'i', 'i', 'i', 'i', '0' + @as(u8, @intCast(n)) }, .{ .idle = ago(n * 60) }, .{ .label = "Wait for review" });
    var state = try opened(&rows);
    defer state.deinit();
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, text, "○ Wait for review"));
    try std.testing.expect(std.mem.indexOf(u8, text, " more") == null);
}

test "your Sessions keep a bright title once they end" {
    var state = try opened(&.{ session("k7m2qx", .{ .finished = ago(60) }, .{ .label = "Fix it", .yours = true }), session("r4t9vw", .{ .finished = ago(90) }, .{ .label = "Map it" }) });
    defer state.deinit();
    state.selected = null;
    var screen = try sizedRender(&state, .{}, 80, 24, .{}, 0);
    defer screen.deinit();
    try std.testing.expectEqual(cellStyle(screen.caps, Style{ .colour = .strong, .bold = true }), screen.styleAt(5, 4).?);
    try std.testing.expectEqual(cellStyle(screen.caps, Style{ .colour = .quiet }), screen.styleAt(8, 4).?);
}

fn expectPainted(state: *State, width: u16, height: u16, caps: Caps) !void {
    var screen = try sizedRender(state, .{}, width, height, caps, 0);
    defer screen.deinit();
    for (0..height) |row| for (0..width) |column| {
        const cell = screen.cell(column, row);
        const palette = view.palettes.get(caps.skin());
        var ground_known = false;
        for (std.enums.values(Background)) |background| {
            if (std.meta.eql(cell.style.bg, cellStyle(caps, .{ .background = background }).bg)) ground_known = true;
        }
        try std.testing.expect(ground_known);
        if (caps.depth == .none) {
            try std.testing.expect(cell.style.fg == .default and cell.style.bg == .default);
        } else {
            var ink_known = false;
            for (std.enums.values(Colour)) |colour| {
                if (std.meta.eql(cell.style.fg, cellStyle(caps, .{ .colour = colour }).fg)) ink_known = true;
            }
            try std.testing.expect(ink_known);
        }
        _ = palette;
    };
    const bytes = try screen.backend.encode();
    try std.testing.expect(std.mem.endsWith(u8, bytes, vaxis.ctlseqs.osc8_clear ++ vaxis.ctlseqs.sgr_reset));
    if (caps.depth == .none) {
        try std.testing.expect(std.mem.indexOf(u8, bytes, "38;") == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "48;") == null);
    }
}

test "direct row writes place text and domain styles in the shared grid" {
    const caps: Caps = .{ .depth = .indexed };
    const backend = try testBackend(caps);
    defer {
        backend.deinit();
        std.testing.allocator.destroy(backend);
    }
    try backend.begin(.{ .cols = 10, .rows = 2, .x_pixel = 0, .y_pixel = 0 });
    defer backend.end();
    var row: RowPaint = .{ .arena = backend.scratch(), .caps = caps, .glyphs = unicode_glyphs, .window = backend.window(), .width = 10, .frame = 0 };
    row.begin(false);
    _ = try row.put(1, "ab", 2, .{});
    _ = try row.put(3, "cd", 2, .{});
    _ = try row.put(5, "e", 1, .{ .colour = .ink });
    _ = try row.put(8, "f", 1, .{ .colour = .ink });
    try row.finish();
    const grid = &backend.storage.?.vx.screen;
    for ([_]u16{ 1, 2, 3, 4 }, "abcd") |col, byte| {
        try std.testing.expectEqual(byte, grid.readCell(col, 0).?.char.grapheme[0]);
        try std.testing.expectEqual(cellStyle(caps, .{}), grid.readCell(col, 0).?.style);
    }
    for ([_]u16{ 5, 8 }, "ef") |col, byte| {
        try std.testing.expectEqual(byte, grid.readCell(col, 0).?.char.grapheme[0]);
        try std.testing.expectEqual(cellStyle(caps, .{ .colour = .ink }), grid.readCell(col, 0).?.style);
    }
    const bytes = try backend.encode();
    try std.testing.expect(std.mem.endsWith(u8, bytes, vaxis.ctlseqs.osc8_clear ++ vaxis.ctlseqs.sgr_reset));
    try std.testing.expect(std.mem.indexOf(u8, bytes, ";2;") == null);
}

test "each skin paints every cell of the screen at each colour depth" {
    var state = try opened(&mixed);
    defer state.deinit();
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s - 7500, .slots = 100, .slots_in_use = 3 } });
    for ([_]?Rgb{ null, .{ 0x12, 0x18, 0x33 }, .{ 0xf3, 0xee, 0xe2 } }) |background| {
        for ([_]Caps.Depth{ .direct, .indexed, .none }) |depth| {
            for ([_][2]u16{ .{ 80, 24 }, .{ 200, 60 } }) |size| try expectPainted(&state, size[0], size[1], .{ .depth = depth, .background = background });
        }
    }
    // The band and the faded rows paint too.
    _ = try step(&state, .{ .tick = (test_now_s + 1) * 1000 });
    _ = try step(&state, .{ .list = .failed });
    for ([_]Caps.Depth{ .direct, .indexed, .none }) |depth| try expectPainted(&state, 80, 24, .{ .depth = depth });
}

test "the top reads as the mock: wordmark, headline, health, then the counted groups" {
    var state = try opened(&mixed);
    defer state.deinit();
    _ = try step(&state, .{ .host = .{ .started_at = test_now_s - 7500, .slots = 100, .slots_in_use = 3 } });
    try expectScreenLine(&state, 0, " रुई rui  ~/code/rui");
    try expectScreenLine(&state, 1, " Running. 20 Sessions. 2 failed.");
    try expectScreenLine(&state, 2, " Host up 2h05m   slots 3/100");
    // The headings count the rows, so no line above them does.
    try expectScreenLine(&state, 3, "");
    try expectScreenLine(&state, 4, " Yours · 3");
    // The wordmark and the headline's opening are the only bold on the top.
    try expectStyle(&state, 0, 1, .{ .colour = .strong, .background = .bar, .bold = true });
    try expectStyle(&state, 0, 5, .{ .colour = .strong, .background = .bar, .bold = true });
    try expectStyle(&state, 0, 79, .{ .background = .bar });
    try expectStyle(&state, 1, 1, .{ .colour = .strong, .bold = true });
    try expectStyle(&state, 1, 10, .{});
    // ASCII has rui alone.
    const text = try screenText(&state, 80, 24, .{ .unicode = false });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, " rui  ~/code/rui\n Running. 20 Sessions. 2 failed.\n Host up 2h05m   slots 3/100\n\n Yours - 3\n"));
}

test "the headline says whether anything works, and counts failures" {
    const yours_done = session("k7m2qx", .{ .finished = ago(5 * 60) }, .{ .label = "Fix it", .yours = true });
    const other_done = session("h8q2mz", .{ .finished = ago(9 * 60) }, .{ .label = "Map it", .yours = true });
    const working = session("a1b2c3", .{ .working = ago(40) }, .{ .label = "Profile it" });
    const failed = failedRow("aaaaaa", 60, "provider_output_invalid", null);
    const approval = session("r4t9vw", .{ .approval = ago(3 * 60) }, .{ .label = "Review PR 412" });
    for ([_]struct { rows: []const Listed, line: []const u8 }{
        .{ .rows = &.{ working, yours_done }, .line = " Running. 2 Sessions. Nothing needs you." },
        .{ .rows = &.{ approval, yours_done }, .line = " Running. 2 Sessions." },
        .{ .rows = &.{session("r4t9vw", .{ .working = ago(3) }, .{ .label = "Review it", .yours = true })}, .line = " Running. 1 Session. Nothing needs you." },
        .{ .rows = &.{ working, failed }, .line = " Running. 2 Sessions. 1 failed." },
        .{ .rows = &.{ yours_done, other_done }, .line = " Quiet for 5m. All 2 of your conversations have answered." },
        .{ .rows = &.{yours_done}, .line = " Quiet for 5m. Your conversation has answered." },
        .{ .rows = &.{ yours_done, failed }, .line = " Quiet for 1m. 1 failed." },
        .{ .rows = &.{session("g7h8j9", .{ .idle = ago(7200) }, .{ .label = "Wait" })}, .line = " Quiet for 2h00m. Nothing is working or waiting." },
        .{ .rows = &.{}, .line = " No Sessions yet. Type a task below." },
    }) |case| {
        var state = try opened(case.rows);
        defer state.deinit();
        try expectScreenLine(&state, 1, case.line);
        // The sentence reads the State the listing left.
        try std.testing.expectEqual(std.mem.startsWith(u8, case.line, " Running."), state.summary.working);
    }
}

test "overview top stays compact through completion failure Host changes and input" {
    const Check = struct {
        fn screen(state: *State, headline_text: []const u8, health: []const u8, group: []const u8) !void {
            const text = try screenText(state, 80, 24, .{});
            defer std.testing.allocator.free(text);
            var lines = std.mem.splitScalar(u8, text, '\n');
            for ([_][]const u8{ " रुई rui  ~/code/rui", headline_text, health, "", group }) |expected| {
                try std.testing.expectEqualStrings(expected, lines.next().?);
            }
            try std.testing.expect(std.mem.indexOf(u8, text, "Since you looked") == null);
            try std.testing.expect(std.mem.indexOf(u8, text, "Host restarted") == null);
        }
    };
    var state = try opened(&.{
        session("a1b2c3", .{ .working = ago(40) }, .{ .label = "Finish later" }),
        session("b2c3d4", .{ .working = ago(20) }, .{ .label = "Fail later" }),
    });
    defer state.deinit();
    try Check.screen(&state, " Running. 2 Sessions. Nothing needs you.", "", " Active · 2");
    const host: Host = .{ .started_at = test_now_s - 600, .slots = 4, .slots_in_use = 2 };
    _ = try step(&state, .{ .host = host });
    try Check.screen(&state, " Running. 2 Sessions. Nothing needs you.", " Host up 10m   slots 2/4", " Active · 2");

    _ = try step(&state, .{ .tick = (test_now_s + 60) * 1000 });
    _ = try respond(&state, .changed, testToken(2), &.{session("a1b2c3", .{ .finished = .{ .since = test_now_s + 60 } }, .{ .label = "Finish later" })});
    try Check.screen(&state, " Running. 2 Sessions. Nothing needs you.", " Host up 11m   slots 2/4", " Active · 1");

    _ = try step(&state, .{ .tick = (test_now_s + 120) * 1000 });
    _ = try respond(&state, .changed, testToken(3), &.{session("b2c3d4", .{ .failed = .{ .since = test_now_s + 120, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .{ .label = "Fail later" })});
    try Check.screen(&state, " Quiet for 0s. 1 failed.", " Host up 12m   slots 2/4", " Finished · 1");
    try expectScreenLine(&state, 7, " Stopped or failed · 1");
    try expectScreenLine(&state, 8, "  × Fail later                                                               0s");

    _ = try step(&state, .{ .host = null });
    try Check.screen(&state, " Quiet for 0s. 1 failed.", "", " Finished · 1");
    _ = try step(&state, .{ .host = host });
    try Check.screen(&state, " Quiet for 0s. 1 failed.", " Host up 12m   slots 2/4", " Finished · 1");
    for ([_]u64{ test_now_s + 60, test_now_s + 120, test_now_s + 120 }) |started_at| {
        _ = try step(&state, .{ .host = .{ .started_at = started_at, .slots = 8, .slots_in_use = 0 } });
        try Check.screen(&state, " Quiet for 0s. 1 failed.", if (started_at == test_now_s + 60) " Host up 1m   slots 0/8" else " Host up 0s   slots 0/8", " Finished · 1");
    }
    _ = try step(&state, .{ .tick = (test_now_s + 121) * 1000 });
    try Check.screen(&state, " Quiet for 1s. 1 failed.", " Host up 1s   slots 0/8", " Finished · 1");
    _ = try press(&state, .{}, .next);
    try Check.screen(&state, " Quiet for 1s. 1 failed.", " Host up 1s   slots 0/8", " Finished · 1");
    _ = try typeText(&state, "a task");
    try Check.screen(&state, " Quiet for 1s. 1 failed.", " Host up 1s   slots 0/8", " Finished · 1");
}

test "overview compact top leaves a failed row visible in a narrow viewport" {
    var state = try opened(&.{session("a1b2c3", .{ .working = ago(40) }, .{ .label = "Fail later" })});
    defer state.deinit();
    _ = try step(&state, .{ .tick = (test_now_s + 60) * 1000 });
    _ = try respond(&state, .changed, testToken(2), &.{session("a1b2c3", .{ .failed = .{ .since = test_now_s + 60, .code = bounded(session_work.max_code_bytes, "provider_output_invalid"), .resets_at = null } }, .{ .label = "Fail later" })});
    const text = try screenText(&state, 40, 9, .{});
    defer std.testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    for ([_][]const u8{
        " रुई rui  ~/code/rui",
        " Quiet for 0s. 1 failed.",
        "",
        "",
        " Stopped or failed · 1",
        "  × Fail later",
    }) |expected| try std.testing.expectEqualStrings(expected, lines.next().?);
    try std.testing.expect(std.mem.indexOf(u8, text, "Since you looked") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Host restarted") == null);
}

test "overview compact top preserves both alarm bands before health and the list" {
    var state = try opened(&.{session("a1b2c3", .{ .working = ago(40) }, .{ .label = "Fail later" })});
    defer state.deinit();
    _ = try step(&state, .{ .tick = (test_now_s + 60) * 1000 });
    _ = try respond(&state, .changed, testToken(2), &.{session("a1b2c3", .{ .failed = .{ .since = test_now_s + 60, .code = bounded(session_work.max_code_bytes, "provider_sign_in_refresh_token_expired"), .resets_at = null } }, .{ .label = "Fail later" })});
    _ = try step(&state, .{ .tick = (test_now_s + 61) * 1000 });
    _ = try step(&state, .{ .list = .failed });
    _ = try step(&state, .{ .tick = (test_now_s + 121) * 1000 });
    const text = try screenText(&state, 80, 24, .{});
    defer std.testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    for ([_][]const u8{
        " रुई rui  ~/code/rui",
        " Host stopped 1m ago. Run rui host start.",
        " Sign-in expired. Run rui auth login codex.",
        " Host not responding. Last update 1m ago.",
        "",
        " Stopped or failed · 1",
        "  × Fail later                                                               1m",
    }) |expected| try std.testing.expectEqualStrings(expected, lines.next().?);
    try std.testing.expect(std.mem.indexOf(u8, text, "Since you looked") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Host restarted") == null);
}

test "the Host-stopped band comes first, over the provider bands and the faded rows" {
    var state = try opened(&.{ failedRow("aaaaaa", 60, "provider_sign_in_refresh_token_expired", null), session("a1b2c3", .{ .working = ago(40) }, .{ .label = "Profile it" }) });
    defer state.deinit();
    try expectScreenLine(&state, 1, " Sign-in expired. Run rui auth login codex.");
    _ = try step(&state, .{ .tick = (test_now_s + 1) * 1000 });
    _ = try step(&state, .{ .list = .failed });
    try std.testing.expectEqual(@as(?u64, (test_now_s + 1) * 1000), state.unreachable_since_ms);
    _ = try step(&state, .{ .tick = (test_now_s + 181) * 1000 });
    try expectScreenLine(&state, 1, " Host stopped 3m ago. Run rui host start.");
    try expectScreenLine(&state, 2, " Sign-in expired. Run rui auth login codex.");
    try expectStyle(&state, 1, 0, .{ .colour = .on_band, .background = .band, .bold = true });
    // No headline sentence claims calm under a band; the rows fade.
    try expectScreenLine(&state, 3, " Host not responding. Last update 3m ago.");
    try expectStyle(&state, 3, 1, .{ .colour = .failure });
    try expectStyle(&state, 9, 4, .{ .colour = .quiet });
}

fn pickerScreen(state: *State) ![]u8 {
    return screenText(state, 60, 24, .{ .unicode = true });
}

fn onScreen(state: *State, text: []const u8) !bool {
    const screen = try pickerScreen(state);
    defer std.testing.allocator.free(screen);
    return std.mem.indexOf(u8, screen, text) != null;
}

test "/model lists the models, default first, and a model one sign-in offers is the whole pick" {
    var state = try pickerState(Default.of("codex", "gpt-6.1-sol"));
    defer state.deinit();
    try openPicker(&state, &.{chatgpt});
    try std.testing.expectEqualStrings("gpt-6.1-sol", shownRow(&state, 0));
    // The default leads, and the sign-in the Host does not serve says how to add it.
    try std.testing.expect(try onScreen(&state, "› gpt-6.1-sol"));
    try std.testing.expect(try onScreen(&state, Provider.openai.login()));
    try std.testing.expect(!try onScreen(&state, Provider.codex.login()));
    // Select gpt-6-luna with ChatGPT, the only sign-in.
    var draft = try typeText(&state, "");
    try highlightModel(&state, draft, "gpt-6-luna");
    try expectEffects(&.{.{ .save_default = Default.of("codex", "gpt-6-luna").? }}, try submit(&state, draft));
    // Closing the picker frees its menu.
    try std.testing.expect(state.picker == null and state.menu.entries.len == 0);
    // The pick is the default at once, before its save ends.
    try std.testing.expectEqualStrings("gpt-6-luna", state.default.?.model.slice());
    try std.testing.expectEqual(Provider.codex, state.default.?.provider);
    try expectEffects(&.{}, try step(&state, saveEnded("codex", "gpt-6-luna", .done)));
    try std.testing.expect(state.notice.?.colour == .quiet);
    // A save the file holds but may not keep says so; a failed one says so
    // quietly, and the pick stays this overview's default.
    for ([_]struct { Saved, []const u8, Colour }{ .{ .unconfirmed, "gpt-5.5", .attention }, .{ .{ .failed = "disk full" }, "gpt-5.6-luna", .quiet } }) |case| {
        try openPicker(&state, &.{chatgpt});
        draft = try typeText(&state, "");
        try highlightModel(&state, draft, case[1]);
        try expectEffects(&.{.{ .save_default = Default.of("codex", case[1]).? }}, try submit(&state, draft));
        try expectEffects(&.{}, try step(&state, saveEnded("codex", case[1], case[0])));
        try std.testing.expectEqualStrings(case[1], state.default.?.model.slice());
        try std.testing.expect(state.notice.?.colour == case[2]);
    }
    try std.testing.expect(std.mem.indexOf(u8, state.notice.?.text(), "disk full") != null);
}

test "with both sign-ins, Enter turns the input row into the sign-in choice at the default's sign-in; Esc steps back" {
    var state = try pickerState(Default.of("openai", "gpt-6-luna"));
    defer state.deinit();
    try openPicker(&state, &both);
    const draft = try typeText(&state, "");
    try expectEffects(&.{}, try submit(&state, draft));
    try std.testing.expect(state.inputMode() == .choice);
    try std.testing.expectEqual(Provider.openai, state.picker.?.step.sign_in);
    try std.testing.expect(try onScreen(&state, "Use    ChatGPT   › API key"));
    // Left moves to ChatGPT and stops there.
    try expectEffects(&.{}, try choose(&state, .left));
    try expectEffects(&.{}, try choose(&state, .left));
    try std.testing.expectEqual(Provider.codex, state.picker.?.step.sign_in);
    // A refused key's notice leaves the choice's keys in view.
    try expectEffects(&.{}, try step(&state, .{ .composed = .{ .input = .{ .choice = .refused }, .draft = draft } }));
    {
        const screen = try pickerScreen(&state);
        defer std.testing.allocator.free(screen);
        const hint_row = screen[std.mem.lastIndexOfScalar(u8, screen[0 .. screen.len - 1], '\n').? + 1 ..];
        try std.testing.expect(std.mem.indexOf(u8, hint_row, state.notice.?.text()) != null);
        try std.testing.expect(std.mem.indexOf(u8, hint_row, "←→") != null);
    }
    // Esc goes back to the models, then closes the picker.
    try expectEffects(&.{}, try press(&state, draft, .clear));
    try std.testing.expect(state.picker != null and state.inputMode() == .compose);
    try expectEffects(&.{}, try press(&state, draft, .clear));
    try std.testing.expect(state.picker == null and state.menu.entries.len == 0);
    // gpt-6.1-sol only ChatGPT offers: Enter saves it without a choice.
    try openPicker(&state, &both);
    try highlightModel(&state, draft, "gpt-6.1-sol");
    try std.testing.expectEqualStrings("gpt-6.1-sol", state.picker.?.highlight.slice());
    try expectEffects(&.{.{ .save_default = Default.of("codex", "gpt-6.1-sol").? }}, try submit(&state, draft));
    // Typing leaves the picker for the draft.
    try openPicker(&state, &both);
    _ = try typeText(&state, "h");
    try std.testing.expect(state.picker == null and state.menu.entries.len == 0);
}

test "a model Rui does not list shows under Other models and is picked like any other" {
    var state = try pickerState(Default.of("openai", "gpt-6-luna"));
    defer state.deinit();
    try openPicker(&state, &both);
    const draft = try typeText(&state, "");
    try expectEffects(&.{}, try press(&state, draft, .last));
    try std.testing.expect(try onScreen(&state, "Other models"));
    try std.testing.expectEqualStrings("unlisted-z", state.picker.?.highlight.slice());
    try expectEffects(&.{.{ .save_default = Default.of("openai", "unlisted-z").? }}, try submit(&state, draft));
    try expectEffects(&.{}, try step(&state, saveEnded("openai", "unlisted-z", .done)));
    // Saved, it leads the next menu, highlighted, and "Other models" holds the rest.
    try openPicker(&state, &both);
    try std.testing.expectEqualStrings("unlisted-z", shownRow(&state, 0));
    try std.testing.expectEqualStrings("unlisted-a", shownRow(&state, state.shownMenu().others()));
    try std.testing.expect(try onScreen(&state, "› unlisted-z"));
}

test "a pick leads the next menu before its save ends, and a re-read that reorders the list keeps the highlight on its model" {
    var state = try pickerState(Default.of("codex", "gpt-6-luna"));
    defer state.deinit();
    try openPicker(&state, &.{chatgpt});
    const draft = try typeText(&state, "");
    try highlightModel(&state, draft, "gpt-5.5");
    try expectEffects(&.{.{ .save_default = Default.of("codex", "gpt-5.5").? }}, try submit(&state, draft));
    try openPicker(&state, &.{chatgpt});
    try std.testing.expectEqualStrings("gpt-5.5", shownRow(&state, 0));
    try std.testing.expectEqualStrings("gpt-5.6-luna", shownRow(&state, 1));
    try std.testing.expect(try onScreen(&state, "› gpt-5.5"));
    // Select gpt-6.1-sol; its save ending moves nothing.
    try highlightModel(&state, draft, "gpt-6.1-sol");
    try expectEffects(&.{}, try step(&state, saveEnded("codex", "gpt-5.5", .done)));
    try std.testing.expectEqualStrings("gpt-6.1-sol", state.picker.?.highlight.slice());
    try std.testing.expect(try onScreen(&state, "› gpt-6.1-sol"));
    // A re-read without gpt-5.5 or gpt-6-luna reorders the rows; the
    // highlight goes with it.
    try answerModels(&state, &.{.{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6-sol\ngpt-6.1-sol\n" } } }});
    try std.testing.expectEqualStrings("gpt-6-sol", shownRow(&state, 0));
    try std.testing.expect(try onScreen(&state, "› gpt-6.1-sol"));
    try expectEffects(&.{}, try press(&state, draft, .first));
    try std.testing.expect(try onScreen(&state, "› gpt-6-sol"));
    // A re-read without the highlighted model highlights the first row.
    try answerModels(&state, &.{.{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-5.5\ngpt-6.1-sol\n" } } }});
    try std.testing.expectEqualStrings("gpt-5.5", state.picker.?.highlight.slice());
    try std.testing.expect(try onScreen(&state, "› gpt-5.5"));
}

test "a loading list is read again with the next listing, and a failed read keeps the list under a note" {
    var state = try pickerState(Default.of("openai", "gpt-6-luna"));
    defer state.deinit();
    try openPicker(&state, &.{.{ .provider = .openai, .list = .pending }});
    try std.testing.expect(try onScreen(&state, "loading"));
    // The next listing asks for the lists again, once.
    const asked = try step(&state, .{ .tick = state.now_ms + list_interval_ms });
    try expectEffects(&.{ .{ .list = testToken(1) }, .list_models }, asked);
    try answerModels(&state, &.{.{ .provider = .openai, .list = .catalog_fallback }});
    try std.testing.expect(!try onScreen(&state, "loading"));
    const fallback = try pickerScreen(&state);
    defer std.testing.allocator.free(fallback);
    // No answer and an answer Rui cannot read each keep the list, and each
    // puts its own note right above the first model.
    var notes: [2][]u8 = undefined;
    for ([_]ModelsRead{ .unanswered, .invalid }, &notes) |read, *note| {
        try expectEffects(&.{}, try step(&state, .{ .models = read }));
        const screen = try pickerScreen(&state);
        defer std.testing.allocator.free(screen);
        const first = std.mem.indexOf(u8, screen, "› gpt-6-luna").?;
        const above = screen[0..std.mem.lastIndexOfScalar(u8, screen[0..first], '\n').?];
        const line = std.mem.trim(u8, above[std.mem.lastIndexOfScalar(u8, above, '\n').? + 1 ..], " ");
        try std.testing.expect(line.len != 0 and std.mem.indexOf(u8, fallback, line) == null);
        note.* = try std.testing.allocator.dupe(u8, line);
    }
    defer for (notes) |note| std.testing.allocator.free(note);
    try std.testing.expect(!std.mem.eql(u8, notes[0], notes[1]));
    // Before any list, a failure replaces the loading line, with no models.
    var first = try pickerState(null);
    defer first.deinit();
    const draft = try typeText(&first, "/model");
    _ = try submit(&first, draft);
    const loading = try pickerScreen(&first);
    defer std.testing.allocator.free(loading);
    try expectEffects(&.{}, try step(&first, .{ .models = .unanswered }));
    const unanswered = try pickerScreen(&first);
    defer std.testing.allocator.free(unanswered);
    try std.testing.expect(!std.mem.eql(u8, loading, unanswered));
    try std.testing.expect(std.mem.indexOf(u8, unanswered, "gpt-") == null);
}

test "picker tag columns admit ids at and beyond the 24-column cap" {
    for ([_]usize{ 24, model_capability.max_model_bytes }) |length| {
        var state = try pickerState(null);
        defer state.deinit();
        const id: [model_capability.max_model_bytes]u8 = @splat('m');
        var bytes: [model_capability.max_model_bytes + 1]u8 = undefined;
        @memcpy(bytes[0..length], id[0..length]);
        bytes[length] = '\n';
        try openPicker(&state, &.{.{ .provider = .codex, .list = .{ .live = .{ .bytes = bytes[0 .. length + 1] } } }});
        try std.testing.expectEqual(length, state.menu.widest);
        try std.testing.expect(try onScreen(&state, "› mmmm"));
        try std.testing.expectEqualStrings(id[0..length], state.picker.?.highlight.slice());
    }
}

test "a long list shows a window around the highlight and counts the rest" {
    var state = try pickerState(null);
    defer state.deinit();
    try openPicker(&state, &.{.{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-6-luna\ngpt-6.1-sol\ngpt-6-sol\ngpt-6-astra\ngpt-5.6-sol\ngpt-5.6-terra\ngpt-5.6-luna\ngpt-5.5\no1\no2\no3\no4\n" } } }});
    const draft = try typeText(&state, "");
    try expectEffects(&.{}, try press(&state, draft, .last));
    try std.testing.expect(try onScreen(&state, "› o4"));
    try std.testing.expect(!try onScreen(&state, "gpt-5.5"));
    const screen = try pickerScreen(&state);
    defer std.testing.allocator.free(screen);
    try std.testing.expect(pickerMore(screen));
}

test "on a short screen the highlighted model always shows, and \"N more\" takes only spare rows" {
    var state = try pickerState(null);
    defer state.deinit();
    try openPicker(&state, &both);
    const draft = try typeText(&state, "");
    try expectEffects(&.{}, try press(&state, draft, .last));
    var counted = false;
    for (5..24) |height| {
        const screen = try screenText(&state, 60, @intCast(height), .{ .unicode = true });
        defer std.testing.allocator.free(screen);
        var rows: usize = 0;
        var lines = std.mem.splitScalar(u8, screen, '\n');
        while (lines.next()) |line| rows += @intFromBool(std.mem.indexOf(u8, line, "gpt-") != null or std.mem.indexOf(u8, line, "unlisted-a") != null or std.mem.indexOf(u8, line, "unlisted-z") != null or std.mem.indexOf(u8, line, "Other models") != null);
        if (rows == 0) continue;
        try std.testing.expect(std.mem.indexOf(u8, screen, "› unlisted-z") != null);
        // "N more" shows only once the rows hold all the models they may.
        if (pickerMore(screen)) {
            try std.testing.expectEqual(@as(usize, max_picker_rows), rows);
            counted = true;
        }
    }
    try std.testing.expect(counted);
}

test "the Session row's highlight stays in view while the picker is open, even on a short screen" {
    var state = try pickerState(null);
    defer state.deinit();
    // ChatGPT's models and the API-key login note fill a short screen.
    try openPicker(&state, &.{chatgpt});
    for (8..25) |height| {
        var screen = try sizedRender(&state, .{}, 60, @intCast(height), .{ .unicode = true }, 0);
        defer screen.deinit();
        var highlighted: usize = 0;
        for (0..screen.height) |row| {
            for (0..screen.width) |col| if (std.meta.eql(screen.cell(col, row).style.bg, cellStyle(screen.caps, .{ .background = .selection }).bg)) {
                highlighted += 1;
                break;
            };
        }
        // The selected Session always; the picker's model once a row is
        // left for it. With one row, the Session keeps it: a stop is the
        // key that must never act on what the screen does not show.
        try std.testing.expectEqual(@as(usize, if (height > 8) 2 else 1), highlighted);
    }
}

test "with no sign-in served, the picker shows each login line instead of models" {
    var state = try pickerState(null);
    defer state.deinit();
    try openPicker(&state, &.{});
    try std.testing.expect(try onScreen(&state, Provider.codex.login()));
    try std.testing.expect(try onScreen(&state, Provider.openai.login()));
    const draft = try typeText(&state, "");
    try expectEffects(&.{}, try submit(&state, draft));
    try std.testing.expect(state.default == null);
}

test "the unknown-command notice fits a 40-column screen" {
    var state = try pickerState(null);
    defer state.deinit();
    const draft = try typeText(&state, "/status");
    _ = try submit(&state, draft);
    const screen = try screenText(&state, 40, 24, .{ .unicode = true });
    defer std.testing.allocator.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, state.notice.?.text()) != null);
}

test "a picker the screen cannot show never acts: /model says so, and keys on a hidden picker pick nothing" {
    var state = try pickerState(Default.of("codex", "gpt-6.1-sol"));
    defer state.deinit();
    // At 8 rows the top, the selected Session and the input leave the
    // picker none.
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 60, .height = 8 } }));
    var draft = try typeText(&state, "/model");
    try expectEffects(&.{}, try submit(&state, draft));
    try std.testing.expect(state.picker == null);
    try std.testing.expectEqual(Colour.attention, state.notice.?.colour);
    // Opened on a taller screen, then shrunk: Down and Enter act on what
    // the screen shows, which holds no model.
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 60, .height = 24 } }));
    try openPicker(&state, &.{chatgpt});
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 60, .height = 8 } }));
    try std.testing.expect(state.shownPicker() == null);
    draft = try typeText(&state, "");
    _ = try press(&state, draft, .next);
    for ((try submit(&state, draft)).slice()) |effect| try std.testing.expect(effect != .save_default);
    try std.testing.expectEqualStrings("gpt-6.1-sol", state.default.?.model.slice());
    const screen = try screenText(&state, 60, 8, .{ .unicode = true });
    defer std.testing.allocator.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "gpt-") == null);
}

/// The rows the Sessions' list takes on an 80 by 24 screen with `draft`.
fn listRows(state: *State, draft: Draft) ![]u8 {
    const text = try draftLines(state, draft, 80, 24);
    errdefer std.testing.allocator.free(text);
    const at = layout(state, 1, 0).list;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var kept: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer kept.deinit();
    var row: usize = 0;
    while (lines.next()) |line| : (row += 1) if (row >= at.start and row < at.end) {
        try kept.writer.print("{s}\n", .{std.mem.trimEnd(u8, line, " ")});
    };
    std.testing.allocator.free(text);
    return kept.toOwnedSlice();
}

test "/help shows the overview's keys and commands in the Sessions' rows until Esc" {
    var state = try opened(&mixed);
    defer state.deinit();
    const label = "Fix the flaky resize test";
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 80, .height = 24 } }));
    _ = try submit(&state, try typeText(&state, "/configure --permission-mode ask"));
    try expectEffects(&.{.clear_draft}, try submit(&state, try typeText(&state, "/help")));
    const shown = try listRows(&state, .{});
    defer std.testing.allocator.free(shown);
    var lines = std.mem.splitScalar(u8, shown, '\n');
    const top = lines.next().?;
    try std.testing.expect(std.mem.startsWith(u8, top, " Help "));
    try std.testing.expect(std.mem.endsWith(u8, top, "Esc returns"));
    try std.testing.expectEqual(@as(usize, 79), top.len);
    for ([_][]const u8{
        " Up/Down select a Session past the draft's lines · Shift-Up/Down always",
        " Home/End select the first or last Session while the draft is empty",
        " Enter on an empty draft opens the selected Session · Ctrl-X twice stops it",
        " A message and Enter starts a new Session with it",
        " / lists the commands · Up/Down move the highlight · Tab or Enter takes it",
        " Esc or Ctrl-G closes the list, this panel, the draft, then held settings",
        " Ctrl-C, or Ctrl-D on an empty draft, leaves; Host work continues",
        "",
        " /configure [OPTIONS]  hold settings for the next Session",
        " /exit                 leave; Host work continues",
        " /help                 keys and commands",
        " /model                choose the model new Sessions use",
        " /rename NAME          name the selected Session",
        " /setup [OPTIONS]      future defaults",
    }) |expected| try std.testing.expectEqualStrings(expected, lines.next().?);
    try std.testing.expect(std.mem.indexOf(u8, shown, label) == null);
    // The line under the input says Esc closes it, over held settings or a
    // typed draft.
    try expectScreenLine(&state, 23, " start settings: --permission-mode ask · esc close");
    const draft = try typeText(&state, "fix the build");
    const held = state.settings;
    state.settings = .{};
    const hinted = try draftLines(&state, draft, 80, 24);
    defer std.testing.allocator.free(hinted);
    state.settings = held;
    try std.testing.expect(std.mem.indexOf(u8, hinted, " enter start · esc close") != null);
    // A draft typed under it stays when Esc closes it, and so do the held
    // start settings: Esc returns to the Sessions first. (Over a shown
    // command list, Esc closes the list first.)
    try expectEffects(&.{}, try press(&state, draft, .clear));
    try std.testing.expect(state.panel == null);
    try std.testing.expect(!state.settings.empty());
    const back = try listRows(&state, .{});
    defer std.testing.allocator.free(back);
    try std.testing.expect(std.mem.indexOf(u8, back, label) != null);
    // Ctrl-G closes it as Esc does.
    _ = try submit(&state, try typeText(&state, "/help"));
    try expectEffects(&.{}, try press(&state, .{}, .clear));
    try std.testing.expect(state.panel == null);
    try std.testing.expect(!state.settings.empty());
}

test "/help says when the screen is too small for it, and a screen that shrinks under it counts the lines it hides" {
    var state = try opened(&mixed);
    defer state.deinit();
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 80, .height = 12 } }));
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/help")));
    try std.testing.expect(state.panel == null);
    try expectNotice(&state, "! Screen too small for /help");
    try std.testing.expectEqual(Colour.attention, state.notice.?.colour);
    try expectEffects(&.{}, try step(&state, .{ .resized = .{ .width = 80, .height = 24 } }));
    _ = try submit(&state, try typeText(&state, "/help"));
    const text = try draftLines(&state, .{}, 80, 12);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, " Help ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, " more lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/setup [OPTIONS]") == null);
}

test "/rename names the selected Session through the shell, as a conversation does, one command at a time" {
    var empty = try opened(&.{});
    defer empty.deinit();
    try expectEffects(&.{}, try submit(&empty, try typeText(&empty, "/rename lane four")));
    try expectNotice(&empty, "! Select a Session first.");
    try std.testing.expectEqual(Colour.attention, empty.notice.?.colour);
    try expectEffects(&.{}, try press(&empty, .{}, .stop));
    try expectNotice(&empty, "! Select a Session first.");

    var state = try opened(&mixed);
    defer state.deinit();
    const selected = state.selected.?;
    var line = "/rename lane four".*;
    try expectEffects(&.{ .clear_draft, .{ .command = .{ .name = .rename, .session = selected, .text = &line } } }, try submit(&state, try typeText(&state, &line)));
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/rename ")));
    try expectNotice(&state, "! Usage: /rename NAME");
    // One runs at a time, and the Session it names does not open under it.
    try expectEffects(&.{}, try submit(&state, try typeText(&state, "/setup")));
    try expectNotice(&state, "! Wait for /rename to finish.");
    try expectEffects(&.{}, try submit(&state, .{}));
    try expectNotice(&state, "! Wait for /rename to finish.");
    // Its line is a notice, as in a conversation, and the next listing,
    // which shows the new label, goes at once.
    try ranWith(&state, .{ .output = "Rui: Configured.\n" });
    try expectNotice(&state, "Configured.");
    try std.testing.expectEqual(Colour.quiet, state.notice.?.colour);
    try expectEffects(&.{.{ .list = testToken(1) }}, try step(&state, .{ .tick = state.now_ms }));
    _ = try respond(&state, .full, testToken(2), &mixed);
    for ([_]struct { Ran, []const u8, Colour }{
        .{ .{ .output = "rui: no session k7m2qx in this Store\n" }, "! no session k7m2qx in this Store", .attention },
        .{ .{ .output = "" }, slash_commands.no_output, .quiet },
        .{ .{ .output = "", .outcome = .not_run }, "! /rename unavailable.", .attention },
        // Two lines are a notice too, as in a conversation.
        .{ .{ .output = "Rui: Configured.\nrui: label saved locally only\n" }, "Configured.\n! label saved locally only", .quiet },
    }) |case| {
        _ = try submit(&state, try typeText(&state, "/rename x"));
        try ranWith(&state, case[0]);
        try expectNotice(&state, case[1]);
        try std.testing.expectEqual(case[2], state.notice.?.colour);
    }
    // Both lines show under the input.
    try expectScreenLine(&state, 22, " Configured.");
    try expectScreenLine(&state, 23, " ! label saved locally only");
}

test "/setup needs no Session, and output of more than a line takes the Sessions' rows until Esc" {
    var state = try opened(&.{});
    defer state.deinit();
    var line = "/setup --notifications off".*;
    try expectEffects(&.{ .clear_draft, .{ .command = .{ .name = .setup, .text = &line } } }, try submit(&state, try typeText(&state, &line)));
    try ranWith(&state, .{ .output = "Saved defaults for future Sessions.\nStore: /s (saved)\nNotifications: off\n" });
    try expectNotice(&state, null);
    const shown = try listRows(&state, .{});
    defer std.testing.allocator.free(shown);
    try expectLines(shown, 1, &.{ " Saved defaults for future Sessions.", " Store: /s (saved)", " Notifications: off", "" });
    try std.testing.expect(std.mem.startsWith(u8, shown, " /setup "));
    try expectEffects(&.{}, try press(&state, .{}, .clear));
    try std.testing.expect(state.panel == null);
    // Output past what the overview keeps says it was cut.
    _ = try submit(&state, try typeText(&state, "/setup"));
    try ranWith(&state, .{ .output = "Defaults (read only):", .cut = true });
    const cut = try listRows(&state, .{});
    defer std.testing.allocator.free(cut);
    try expectLines(cut, 1, &.{ " Defaults (read only):", " Output cut at 8 KiB." });
    // Typing "/" lists /setup's options as a conversation does.
    _ = try typeText(&state, "/setup ");
    try std.testing.expectEqualStrings("--model ", state.commands.?.list.shown()[0].word);
}

test "direct overview max-cell frames charge scratch grids prefix and encoding to one cap" {
    var state = try opened(&mixed);
    defer state.deinit();
    const text = comptime text: {
        @setEvalBranchQuota(30_000);
        break :text repeated("e\u{301}", 21_845);
    };
    const draft: Draft = .{ .bytes = text, .cursor = text.len };
    const caps: Caps = .{ .width = .unicode, .depth = .direct };
    for ([_][2]u16{ .{ 2048, 24 }, .{ 256, 192 } }) |size| {
        _ = try step(&state, .{ .resized = .{ .width = size[0], .height = size[1] } });
        const backend = try testBackend(caps);
        defer {
            backend.deinit();
            std.testing.allocator.destroy(backend);
        }
        try backend.begin(.{ .cols = size[0], .rows = size[1], .x_pixel = 0, .y_pixel = 0 });
        try backend.prefixWriter().splatByteAll('p', 32 * 1024);
        _ = try draw(backend.window(), backend.scratch(), &state, draft, caps, 1);
        const bytes = try backend.encode();
        try std.testing.expect(std.mem.startsWith(u8, bytes, "pppp"));
        try std.testing.expect(std.mem.indexOf(u8, bytes, "e\u{301}") != null);
        try std.testing.expect(std.mem.endsWith(u8, bytes, vaxis.ctlseqs.osc8_clear ++ vaxis.ctlseqs.sgr_reset));
        try std.testing.expect(backend.usage().peak <= Backend.memory_limit);
        std.debug.print("overview direct NFD/draft65535/prefix32768 {d}x{d}: charged_peak={d}, retained={d}\n", .{ size[0], size[1], backend.usage().peak, backend.usage().used });
        backend.end();
        const unchanged = try encoded(backend, &state, draft, caps, 1);
        defer std.testing.allocator.free(unchanged);
        try std.testing.expectEqual(@as(usize, 0), unchanged.len);
    }
}

test "direct overview scratch refusal cannot publish or preserve a partial painted diff" {
    var state = try opened(&mixed);
    defer state.deinit();
    _ = try step(&state, .{ .resized = .{ .width = 80, .height = 24 } });
    const backend = try testBackend(.{});
    defer {
        backend.deinit();
        std.testing.allocator.destroy(backend);
    }
    try backend.begin(.{ .cols = 80, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    backend.memory.fault = .{ .after = 0 };
    try std.testing.expectError(error.OutOfMemory, draw(backend.window(), backend.scratch(), &state, .{}, .{}, 0));
    backend.end();
    try std.testing.expectError(error.RenderBackendPoisoned, backend.begin(.{ .cols = 80, .rows = 24, .x_pixel = 0, .y_pixel = 0 }));
}
