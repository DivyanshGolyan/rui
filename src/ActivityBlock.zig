const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const session_view = @import("session_view.zig");
const session_line = @import("session_line.zig");
const work_line = @import("work_line.zig");
const queued_line = @import("queued_line.zig");
const Chip = @import("Chip.zig");
const Hover = @import("widgets/Hover.zig");
const Self = @This();

const more_bytes = std.fmt.count("+{d} more running · info", .{std.math.maxInt(u64)});

pub const Styles = struct {
    ink: vaxis.Style = .{},
    normal: vaxis.Style = .{},
    quiet: vaxis.Style = .{ .dim = true },
    attention: vaxis.Style = .{},
    failure: vaxis.Style = .{},
};

live: session_view.Live = .{},
work: ?work_line.Line = null,
queued: ?queued_line.Waiting = null,
local_queued: ?queued_line.Waiting = null,
queued_note: ?[]const u8 = null,
note_drawn: bool = false,
method: vaxis.gwidth.Method = .unicode,
styles: Styles = .{},
more: Chip,
more_label: [more_bytes]u8 = undefined,

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .drawFn = draw };
}

fn clockCall(self: *const Self) ?usize {
    const call = (self.work orelse return null).call orelse return null;
    for (self.live.entries[0..self.live.count], 0..) |shown, index| {
        if (shown.operation == call.operation and shown.ordinal == call.ordinal) return index;
    }
    return null;
}

const Plan = struct {
    shown: usize,
    more: bool,
    work_row: bool,
    queued: bool,
    local_queued: bool,
    queued_note_rows: usize,

    fn rows(self: Plan) usize {
        return self.shown + @intFromBool(self.more) + @intFromBool(self.work_row) + @intFromBool(self.queued) + @intFromBool(self.local_queued) + self.queued_note_rows;
    }
};

fn noteIndent(width: usize) usize {
    return if (width >= 4) 2 else 0;
}

fn notePiece(self: *const Self, text: []const u8, width: usize) usize {
    const length = session_line.fit(text, width, self.method).len;
    if (length == 0 or length == text.len) return length;
    if (text[length] == ' ') return length + 1;
    if (std.mem.lastIndexOfScalar(u8, text[0..length], ' ')) |space| {
        if (space != 0) return space + 1;
    }
    return length;
}

fn noteRows(self: *const Self, width: usize) ?usize {
    const note = self.queued_note orelse return 0;
    const room = width -| noteIndent(width);
    if (room == 0) return null;
    var remaining = note;
    var count: usize = 0;
    while (remaining.len != 0) {
        const length = self.notePiece(remaining, room);
        if (length == 0) return null;
        remaining = remaining[length..];
        count += 1;
    }
    return count;
}

fn plan(self: *const Self, height: usize, width: usize) Plan {
    const clock_call = self.clockCall();
    const beyond = self.live.total > self.live.count;
    var result: Plan = .{ .shown = 0, .more = false, .work_row = self.work != null and clock_call == null, .queued = self.queued != null, .local_queued = self.local_queued != null, .queued_note_rows = 0 };
    for (0..2) |_| {
        const priority = @as(usize, @intFromBool(result.work_row)) + @intFromBool(result.queued) + @intFromBool(result.local_queued);
        const note_rows = if (result.queued or result.local_queued) self.noteRows(width) orelse 0 else 0;
        result.queued_note_rows = if (note_rows <= height -| priority) note_rows else 0;
        const room = height -| (priority + result.queued_note_rows);
        const all_fit = self.live.count + @intFromBool(beyond) <= room;
        result.shown = if (all_fit) self.live.count else room -| 1;
        result.more = if (all_fit) beyond else room >= 1;
        if (result.work_row or self.work == null or clock_call.? < result.shown) break;
        result.work_row = true;
    }
    return result;
}

pub fn rows(self: *const Self) u16 {
    return @intCast(self.plan(std.math.maxInt(u16), std.math.maxInt(u16)).rows());
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const max = ctx.max.size();
    const clock_call = self.clockCall();
    const kept = self.plan(max.height, max.width);
    self.note_drawn = kept.queued_note_rows != 0;
    const shown = kept.shown;
    const more = kept.more;
    const work_row = kept.work_row;
    const total: u16 = @intCast(kept.rows());
    const height = @min(total, max.height);
    var surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), .{ .width = max.width, .height = height });
    @memset(surface.buffer, .{ .style = self.styles.normal });
    if (max.width == 0 or height == 0) return surface;
    const width = max.width;
    const skip = total - height;
    var index: u16 = 0;
    var children: []vxfw.SubSurface = &.{};
    const clock = try ctx.arena.create([work_line.max_clock_bytes]u8);

    for (0..shown) |call| {
        defer index += 1;
        if (index < skip) continue;
        const buffer = try ctx.arena.create([session_view.Live.line_bytes]u8);
        const words = self.live.line(call, buffer, "") catch unreachable;
        const running = if (clock_call == call) work_line.clockText(clock, self.work.?.clock, .conversation, .unicode) else "";
        const look = self.style(self.live.style(call));
        const row = index - skip;
        const fitted = fitWords(words, running, width, self.method);
        self.printFitted(surface, row, 0, fitted, look, width);
    }
    if (more) {
        defer index += 1;
        if (index >= skip) {
            const omitted = self.live.total - shown;
            const indent: u16 = @min(2, width - 1);
            const full = std.fmt.bufPrint(&self.more_label, "+{d} more running · info", .{omitted}) catch unreachable;
            self.more.label = if (vaxis.gwidth.gwidth(full, self.method) <= width - indent) full else std.fmt.bufPrint(&self.more_label, "+{d} · info", .{omitted}) catch unreachable;
            self.more.style = self.styles.quiet;
            self.more.hover = Hover.underlined(self.styles.quiet);
            self.more.method = self.method;
            children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{ .origin = .{ .row = index - skip, .col = indent }, .surface = try self.more.widget().draw(ctx.withConstraints(.{}, .{ .width = width - indent, .height = 1 })) };
        }
    }
    if (self.work) |line| if (work_row) {
        defer index += 1;
        if (index >= skip) {
            const row = index - skip;
            const fitted = work_line.fit(clock, line, width, self.method);
            const words = switch (line.tone) {
                .normal => self.styles.normal,
                .quiet => self.styles.quiet,
                .attention => self.styles.attention,
            };
            var column: u16 = 0;
            if (fitted.mark.len != 0) {
                column = Chip.print(surface, self.method, column, row, fitted.mark, if (line.tone == .attention) self.styles.attention else self.styles.quiet, width);
                column = Chip.print(surface, self.method, column, row, " ", self.styles.normal, width);
            }
            self.printFitted(surface, row, column, fitted, words, width);
        }
    };
    if (self.queued) |waiting| {
        defer index += 1;
        if (index >= skip) {
            const buffer = try ctx.arena.create([queued_line.waiting_capacity]u8);
            _ = Chip.print(surface, self.method, 0, index - skip, queued_line.waitingRow(buffer, waiting.line, waiting.count, width, self.method), self.styles.quiet, width);
        }
    }
    if (self.local_queued) |waiting| {
        defer index += 1;
        if (index >= skip) {
            const buffer = try ctx.arena.create([queued_line.waiting_capacity]u8);
            _ = Chip.print(surface, self.method, 0, index - skip, queued_line.waitingRow(buffer, waiting.line, waiting.count, width, self.method), self.styles.quiet, width);
        }
    }
    if (kept.queued_note_rows != 0) {
        var remaining = self.queued_note.?;
        const indent: u16 = @intCast(noteIndent(width));
        while (remaining.len != 0) {
            defer index += 1;
            const length = self.notePiece(remaining, width - indent);
            if (index >= skip) _ = Chip.print(surface, self.method, indent, index - skip, remaining[0..length], self.styles.quiet, width);
            remaining = remaining[length..];
        }
    }
    surface.children = children;
    return surface;
}

const Fitted = struct { words: []const u8, cut: bool, clock: []const u8 };

fn printFitted(self: *const Self, surface: vxfw.Surface, row: u16, column: u16, fitted: anytype, words: vaxis.Style, width: u16) void {
    var at = Chip.print(surface, self.method, column, row, fitted.words, words, width);
    if (fitted.cut) at = Chip.print(surface, self.method, at, row, session_line.ellipsis, words, width);
    _ = Chip.print(surface, self.method, at, row, fitted.clock, self.styles.quiet, width);
}

fn fitWords(words: []const u8, clock: []const u8, width: u16, method: vaxis.gwidth.Method) Fitted {
    const words_cells = session_line.cells(words, method);
    const clock_cells = session_line.cells(clock, method);
    if (words_cells + clock_cells <= width) return .{ .words = words, .cut = false, .clock = clock };
    const ellipsis = session_line.cells(session_line.ellipsis, method);
    const kept_clock = if (clock_cells + ellipsis + 4 <= width) clock else "";
    const room = width -| session_line.cells(kept_clock, method);
    if (words_cells <= room) return .{ .words = words, .cut = false, .clock = kept_clock };
    const kept = session_line.fit(words, room -| ellipsis, method);
    return .{ .words = words[0..kept.len], .cut = room >= ellipsis, .clock = kept_clock };
}

fn style(self: *const Self, value: session_view.Style) vaxis.Style {
    return switch (value) {
        .normal => self.styles.normal,
        .user => self.styles.ink,
        .quiet => self.styles.quiet,
        .attention => self.styles.attention,
        .failure => self.styles.failure,
    };
}

fn rowText(surface: vxfw.Surface, row: u16) ![]const u8 {
    const S = struct {
        var bytes: [512]u8 = undefined;
    };
    var out = std.Io.Writer.fixed(&S.bytes);
    var column: u16 = 0;
    while (column < surface.size.width) : (column += 1) {
        const cell = surface.readCell(column, row);
        if (cell.char.width == 0 and cell.char.grapheme.len == 0) continue;
        try out.writeAll(if (cell.char.grapheme.len == 0) " " else cell.char.grapheme);
        if (cell.char.width == 2) column += 1;
    }
    return std.mem.trimEnd(u8, out.buffered(), " ");
}

fn entry(operation: u64, ordinal: u64, description: []const u8, code: @import("protocol.zig").ToolPresentation.Code) session_view.Live.Entry {
    var value: session_view.Live.Entry = std.mem.zeroes(session_view.Live.Entry);
    value.operation = operation;
    value.ordinal = ordinal;
    value.presentation.code = code;
    value.presentation.description = .{};
    value.presentation.description.?.set(description) catch unreachable;
    return value;
}

const Click = struct {
    count: usize = 0,
    fn status(raw: *anyopaque, _: *vxfw.EventContext) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.count += 1;
    }
};

test "the activity tail puts the clock on the running call's own row, and the work line only when no shown row carries it" {
    var click: Click = .{};
    const coloured: Styles = .{
        .normal = .{ .fg = .{ .index = 7 } },
        .ink = .{ .fg = .{ .index = 4 } },
        .quiet = .{ .fg = .{ .index = 8 } },
    };
    var block: Self = .{ .more = .{ .label = "", .userdata = &click, .on_click = Click.status }, .styles = coloured };
    block.live.entries[0] = entry(7, 1, "Read src/overview_view.zig", .succeeded);
    block.live.entries[1] = entry(7, 2, "Run zig build test", .unresolved);
    block.live.entries[2] = entry(7, 3, "Run zig build test-store", .unresolved);
    block.live.count = 3;
    block.live.total = 5;
    block.work = .{ .mark = "◝", .tone = .normal, .words = "Run zig build test", .clock = .{ .elapsed = 42 }, .call = .{ .operation = 7, .ordinal = 2 } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 20 }, .cell_size = .{} };
    const drawn = try block.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 4), drawn.size.height);
    try std.testing.expectEqualStrings("✓ Read src/overview_view.zig", try rowText(drawn, 0));
    try std.testing.expectEqualStrings("◝ Run zig build test · 42s", try rowText(drawn, 1));
    try std.testing.expectEqualStrings("◝ Run zig build test-store", try rowText(drawn, 2));
    try std.testing.expectEqual(vaxis.Color{ .index = 8 }, drawn.readCell(2, 0).style.fg);
    for ([_]u16{ 1, 2 }) |row| {
        try std.testing.expectEqual(vaxis.Color{ .index = 4 }, drawn.readCell(0, row).style.fg);
        try std.testing.expectEqual(vaxis.Color{ .index = 4 }, drawn.readCell(2, row).style.fg);
        try std.testing.expectEqual(vaxis.Color{ .index = 7 }, drawn.readCell(79, row).style.fg);
    }
    try std.testing.expectEqual(vaxis.Color{ .index = 8 }, drawn.readCell(24, 1).style.fg);
    try std.testing.expectEqual(@as(usize, 1), drawn.children.len);
    try std.testing.expectEqual(@as(i17, 3), drawn.children[0].origin.row);
    try std.testing.expectEqual(@as(i17, 2), drawn.children[0].origin.col);
    try std.testing.expectEqualStrings("+2 more running · info", block.more.label);
    try std.testing.expect(drawn.children[0].surface.widget.eql(block.more.widget()));

    const widget_style = @import("widget_style.zig");
    block.styles = .{
        .normal = widget_style.of(.{ .depth = .none }, .{ .colour = .normal }),
        .ink = widget_style.of(.{ .depth = .none }, .{ .colour = .ink }),
        .quiet = widget_style.of(.{ .depth = .none }, .{ .colour = .quiet }),
        .attention = widget_style.of(.{ .depth = .none }, .{ .colour = .attention }),
        .failure = widget_style.of(.{ .depth = .none }, .{ .colour = .failure }),
    };
    const plain = try block.widget().draw(ctx);
    try std.testing.expectEqualStrings("◝ Run zig build test · 42s", try rowText(plain, 1));
    try std.testing.expectEqualStrings("◝ Run zig build test-store", try rowText(plain, 2));
    for (plain.buffer) |cell| {
        try std.testing.expectEqual(vaxis.Color.default, cell.style.fg);
        try std.testing.expectEqual(vaxis.Color.default, cell.style.bg);
    }
    block.styles = coloured;

    block.live = .{};
    block.work = .{ .mark = "◝", .tone = .normal, .words = "Thinking", .clock = .{ .elapsed = 12 } };
    block.queued = .{ .line = "also update docs/using-rui.md", .count = 1 };
    const waiting = try block.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 2), waiting.size.height);
    try std.testing.expectEqualStrings("◝ Thinking · 12s", try rowText(waiting, 0));
    try std.testing.expectEqualStrings("◌ also update docs/using-rui.md", try rowText(waiting, 1));
    try std.testing.expectEqual(@as(usize, 0), waiting.children.len);

    block.work = .{ .mark = "◝", .tone = .attention, .words = "Rate limited", .clock = .{ .retry = .{ .attempt = 2, .seconds = 18 } } };
    const retry = try block.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 2), retry.size.height);
    try std.testing.expectEqualStrings("◝ Rate limited · retry 2 in 18s", try rowText(retry, 0));

    block.work = null;
    block.queued = null;
    try std.testing.expectEqual(@as(u16, 0), (try block.widget().draw(ctx)).size.height);
}

test "a narrow or short activity tail keeps the clock and the oldest calls" {
    var click: Click = .{};
    var block: Self = .{ .more = .{ .label = "", .userdata = &click, .on_click = Click.status } };
    block.live.entries[0] = entry(7, 1, "Read src/overview_view.zig", .succeeded);
    block.live.entries[1] = entry(7, 2, "Run the whole store conformance suite on every dialect", .unresolved);
    block.live.count = 2;
    block.live.total = 30;
    block.work = .{ .mark = "◝", .tone = .normal, .words = "Run the whole store conformance suite on every dialect", .clock = .{ .elapsed = 61 }, .call = .{ .operation = 7, .ordinal = 2 } };
    block.queued = .{ .line = "and then summarize", .count = 3 };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const narrow = try block.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 20 }, .cell_size = .{} });
    try std.testing.expectEqualStrings("◝ Run the whole store… · 1m 1s", try rowText(narrow, 1));
    try std.testing.expectEqualStrings("+28 more running · info", block.more.label);
    try std.testing.expectEqualStrings("◌ 3 · and then summarize", try rowText(narrow, 3));
    _ = try block.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 21, .height = 20 }, .cell_size = .{} });
    try std.testing.expectEqualStrings("+28 · info", block.more.label);
    const short = try block.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 2 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(u16, 2), short.size.height);
    try std.testing.expectEqualStrings("◝ Run the whole store… · 1m 1s", try rowText(short, 0));
    try std.testing.expectEqualStrings("◌ 3 · and then summarize", try rowText(short, 1));
    const three = try block.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 3 }, .cell_size = .{} });
    try std.testing.expectEqualStrings("+30 more running · info", block.more.label);
    try std.testing.expectEqualStrings("◝ Run the whole store… · 1m 1s", try rowText(three, 1));
    try std.testing.expectEqualStrings("◌ 3 · and then summarize", try rowText(three, 2));
    const work = block.work;
    block.work = null;
    const oldest = try block.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 3 }, .cell_size = .{} });
    try std.testing.expectEqualStrings("✓ Read src/overview_view.zig", try rowText(oldest, 0));
    try std.testing.expectEqualStrings("+29 more running · info", block.more.label);
    block.live.total = 2;
    const clipped = try block.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 2 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(usize, 1), clipped.children.len);
    try std.testing.expectEqualStrings("+2 more running · info", block.more.label);
    try std.testing.expectEqualStrings("◌ 3 · and then summarize", try rowText(clipped, 1));
    block.live.total = 30;
    block.work = work;
    for ([_]vxfw.Size{ .{ .width = 0, .height = 4 }, .{ .width = 1, .height = 1 }, .{ .width = 4, .height = 0 } }) |size| {
        const tiny = try block.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{} });
        try std.testing.expect(tiny.size.width <= size.width and tiny.size.height <= size.height);
    }
}

test "queued recovery note follows its preview without displacing work on short screens" {
    var click: Click = .{};
    var block: Self = .{
        .more = .{ .label = "", .userdata = &click, .on_click = Click.status },
        .work = .{ .mark = "◝", .tone = .normal, .words = "Thinking", .clock = .{ .elapsed = 1 } },
        .queued = .{ .line = "original", .count = 1 },
        .queued_note = "Rejected · /discard",
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]u16{ 2, 3 }) |height| {
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = height }, .cell_size = .{} };
        const frame = try block.widget().draw(ctx);
        try std.testing.expect(std.mem.indexOf(u8, try rowText(frame, 0), "Thinking") != null);
        try std.testing.expectEqualStrings("◌ original", try rowText(frame, 1));
        if (height == 3) try std.testing.expectEqualStrings("  Rejected · /discard", try rowText(frame, 2));
    }
}

test "separate queue previews retain their counts and wrap recovery without displacing priority rows" {
    var click: Click = .{};
    var block: Self = .{
        .more = .{ .label = "", .userdata = &click, .on_click = Click.status },
        .work = .{ .mark = "◝", .tone = .normal, .words = "Thinking", .clock = .{ .elapsed = 1 } },
        .queued = .{ .line = "durable", .count = 3 },
        .local_queued = .{ .line = "local", .count = 1 },
        .queued_note = "Not confirmed · ctrl+r retries original",
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const full = try block.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 20, .height = 6 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(u16, 6), full.size.height);
    try std.testing.expectEqualStrings("◝ Thinking · 1s", try rowText(full, 0));
    try std.testing.expectEqualStrings("◌ 3 · durable", try rowText(full, 1));
    try std.testing.expectEqualStrings("◌ local", try rowText(full, 2));
    try std.testing.expectEqualStrings("  Not confirmed ·", try rowText(full, 3));
    try std.testing.expectEqualStrings("  ctrl+r retries", try rowText(full, 4));
    try std.testing.expectEqualStrings("  original", try rowText(full, 5));
    const short = try block.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 20, .height = 5 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(u16, 3), short.size.height);
    try std.testing.expectEqualStrings("◝ Thinking · 1s", try rowText(short, 0));
    try std.testing.expectEqualStrings("◌ 3 · durable", try rowText(short, 1));
    try std.testing.expectEqualStrings("◌ local", try rowText(short, 2));
    block.queued = null;
    block.queued_note = "Rejected · /discard";
    const rejected = try block.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 12, .height = 5 }, .cell_size = .{} });
    try std.testing.expectEqualStrings("  Rejected ·", try rowText(rejected, 2));
    try std.testing.expectEqualStrings("  /discard", try rowText(rejected, 3));
}
