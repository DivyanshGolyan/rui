//! Work under way, at the transcript's tail: the running calls, each
//! running Bash call with its own clock; `+N more running · info` when
//! more run than fit; the work line (`⠹ Thinking · 12s`, `⠹ Rate limited ·
//! retry 2 in 18s`, `Stopping…`) when no shown call carries it; and the
//! newest Message waiting its turn, `◌ also update docs …`. One row each, in
//! that order, so a retry or the next call replaces a row in place rather
//! than stacking. The screen shows it only at the latest view. This block
//! alone decides which rows a short screen keeps.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const session_view = @import("session_view.zig");
const session_line = @import("session_line.zig");
const work_line = @import("work_line.zig");
const queued_line = @import("queued_line.zig");
const Chip = @import("Chip.zig");
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
method: vaxis.gwidth.Method = .unicode,
styles: Styles = .{},
/// `+N more running · info`; clicking it opens chat info. It lives as
/// long as the block, so the press that starts a click survives the redraw
/// before its release; its label is written into `more_label` while
/// drawing, never into a frame's arena.
more: Chip,
more_label: [more_bytes]u8 = undefined,

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .drawFn = draw };
}

/// The index of the shown call that carries the work line's clock, if any.
fn clockCall(self: *const Self) ?usize {
    const call = (self.work orelse return null).call orelse return null;
    for (self.live.entries[0..self.live.count], 0..) |shown, index| {
        if (shown.operation == call.operation and shown.ordinal == call.ordinal) return index;
    }
    return null;
}

/// Which rows a tail `height` rows tall keeps: the one decision `rows` and
/// `draw` both read.
const Plan = struct {
    /// Calls drawn, the oldest retained first.
    shown: usize,
    /// Whether `+N more` shows, counting every call not drawn.
    more: bool,
    /// Whether the work line takes a row of its own.
    work_row: bool,
    queued: bool,

    fn rows(self: Plan) usize {
        return self.shown + @intFromBool(self.more) + @intFromBool(self.work_row) + @intFromBool(self.queued);
    }
};

/// The work line and the waiting row keep their rows; the calls take what
/// is left, oldest first as they are retained, with `+N more` counting
/// every call not drawn. When the call that carries the work line's clock
/// is not drawn, the work line takes a row of its own, so the clock always
/// shows. A screen too short even for those keeps the last rows.
fn plan(self: *const Self, height: usize) Plan {
    const clock_call = self.clockCall();
    const beyond = self.live.total > self.live.count;
    var result: Plan = .{ .shown = 0, .more = false, .work_row = self.work != null and clock_call == null, .queued = self.queued != null };
    for (0..2) |_| {
        const room = height -| (@as(usize, @intFromBool(result.work_row)) + @intFromBool(result.queued));
        const all_fit = self.live.count + @intFromBool(beyond) <= room;
        result.shown = if (all_fit) self.live.count else room -| 1;
        result.more = if (all_fit) beyond else room >= 1;
        if (result.work_row or self.work == null or clock_call.? < result.shown) break;
        result.work_row = true;
    }
    return result;
}

/// Rows the block takes at full height.
pub fn rows(self: *const Self) u16 {
    return @intCast(self.plan(std.math.maxInt(u16)).rows());
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const max = ctx.max.size();
    const clock_call = self.clockCall();
    const kept = self.plan(max.height);
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
        var column = Chip.print(surface, self.method, 0, row, fitted.words, look, width);
        if (fitted.cut) column = Chip.print(surface, self.method, column, row, session_line.ellipsis, look, width);
        _ = Chip.print(surface, self.method, column, row, fitted.clock, self.styles.quiet, width);
    }
    if (more) {
        defer index += 1;
        if (index >= skip) {
            const omitted = self.live.total - shown;
            // Indented under the calls' words, as the mocks set it.
            const indent: u16 = @min(2, width - 1);
            const full = std.fmt.bufPrint(&self.more_label, "+{d} more running · info", .{omitted}) catch unreachable;
            self.more.label = if (vaxis.gwidth.gwidth(full, self.method) <= width - indent) full else std.fmt.bufPrint(&self.more_label, "+{d} · info", .{omitted}) catch unreachable;
            self.more.style = self.styles.quiet;
            self.more.hover = self.styles.quiet;
            self.more.hover.ul_style = .single;
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
            column = Chip.print(surface, self.method, column, row, fitted.words, words, width);
            if (fitted.cut) column = Chip.print(surface, self.method, column, row, session_line.ellipsis, words, width);
            _ = Chip.print(surface, self.method, column, row, fitted.clock, self.styles.quiet, width);
        }
    };
    if (self.queued) |waiting| {
        defer index += 1;
        if (index >= skip) {
            const buffer = try ctx.arena.create([queued_line.waiting_capacity]u8);
            _ = Chip.print(surface, self.method, 0, index - skip, queued_line.waitingRow(buffer, waiting.line, waiting.count, width, self.method), self.styles.quiet, width);
        }
    }
    surface.children = children;
    return surface;
}

const Fitted = struct { words: []const u8, cut: bool, clock: []const u8 };

/// A call row within `width`: its words cut with an ellipsis so the clock
/// stays; a row too narrow for the clock and a few words drops the clock.
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
    block.work = .{ .mark = "⠹", .tone = .normal, .words = "Run zig build test", .clock = .{ .elapsed = 42 }, .call = .{ .operation = 7, .ordinal = 2 } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 20 }, .cell_size = .{} };
    const drawn = try block.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 4), drawn.size.height);
    try std.testing.expectEqualStrings("✓ Read src/overview_view.zig", try rowText(drawn, 0));
    try std.testing.expectEqualStrings("⠹ Run zig build test · 42s", try rowText(drawn, 1));
    try std.testing.expectEqualStrings("⠹ Run zig build test-store", try rowText(drawn, 2));
    // Finished calls are quiet; active calls use ink and their clocks stay quiet.
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

    // NO_COLOR clears both heading colours without changing the rows or clock.
    const widget_style = @import("widget_style.zig");
    block.styles = .{
        .normal = widget_style.of(.{ .depth = .none }, .{ .colour = .normal }),
        .ink = widget_style.of(.{ .depth = .none }, .{ .colour = .ink }),
        .quiet = widget_style.of(.{ .depth = .none }, .{ .colour = .quiet }),
        .attention = widget_style.of(.{ .depth = .none }, .{ .colour = .attention }),
        .failure = widget_style.of(.{ .depth = .none }, .{ .colour = .failure }),
    };
    const plain = try block.widget().draw(ctx);
    try std.testing.expectEqualStrings("⠹ Run zig build test · 42s", try rowText(plain, 1));
    try std.testing.expectEqualStrings("⠹ Run zig build test-store", try rowText(plain, 2));
    for (plain.buffer) |cell| {
        try std.testing.expectEqual(vaxis.Color.default, cell.style.fg);
        try std.testing.expectEqual(vaxis.Color.default, cell.style.bg);
    }
    block.styles = coloured;

    // The model works with no call shown: one dim work row, never stacked.
    block.live = .{};
    block.work = .{ .mark = "⠹", .tone = .normal, .words = "Thinking", .clock = .{ .elapsed = 12 } };
    block.queued = .{ .line = "also update docs/using-rui.md", .count = 1 };
    const waiting = try block.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 2), waiting.size.height);
    try std.testing.expectEqualStrings("⠹ Thinking · 12s", try rowText(waiting, 0));
    try std.testing.expectEqualStrings("◌ also update docs/using-rui.md", try rowText(waiting, 1));
    try std.testing.expectEqual(@as(usize, 0), waiting.children.len);

    // A retry replaces the row in place.
    block.work = .{ .mark = "⠹", .tone = .attention, .words = "Rate limited", .clock = .{ .retry = .{ .attempt = 2, .seconds = 18 } } };
    const retry = try block.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 2), retry.size.height);
    try std.testing.expectEqualStrings("⠹ Rate limited · retry 2 in 18s", try rowText(retry, 0));

    // Idle: nothing.
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
    block.work = .{ .mark = "⠹", .tone = .normal, .words = "Run the whole store conformance suite on every dialect", .clock = .{ .elapsed = 61 }, .call = .{ .operation = 7, .ordinal = 2 } };
    block.queued = .{ .line = "and then summarize", .count = 3 };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const narrow = try block.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 20 }, .cell_size = .{} });
    try std.testing.expectEqualStrings("⠹ Run the whole store… · 1m 1s", try rowText(narrow, 1));
    try std.testing.expectEqualStrings("+28 more running · info", block.more.label);
    try std.testing.expectEqualStrings("◌ 3 · and then summarize", try rowText(narrow, 3));
    _ = try block.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 21, .height = 20 }, .cell_size = .{} });
    try std.testing.expectEqualStrings("+28 · info", block.more.label);
    // Two rows of room: the call carrying the clock is clipped, so the work
    // line keeps the clock above the waiting row.
    const short = try block.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 2 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(u16, 2), short.size.height);
    try std.testing.expectEqualStrings("⠹ Run the whole store… · 1m 1s", try rowText(short, 0));
    try std.testing.expectEqualStrings("◌ 3 · and then summarize", try rowText(short, 1));
    // Three rows: the oldest call would leave the clock's call clipped, so
    // the work line takes the row and the overflow counts all 30.
    const three = try block.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 3 }, .cell_size = .{} });
    try std.testing.expectEqualStrings("+30 more running · info", block.more.label);
    try std.testing.expectEqualStrings("⠹ Run the whole store… · 1m 1s", try rowText(three, 1));
    try std.testing.expectEqualStrings("◌ 3 · and then summarize", try rowText(three, 2));
    // Every running call retained, but not every one fits: the clipped ones
    // still get an overflow row.
    const work = block.work;
    block.work = null;
    // With no clock to keep, a short tail keeps the oldest call, as the
    // three retained are the oldest, and counts the other 29.
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
