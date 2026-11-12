//! File-backed inspection, Action and Message panels. Drawing allocates
//! cells only for this viewport; the continuous feed is owned by FeedView.
//! With a `handler`, a drag across its rows copies their text (OSC 52) when
//! released, and a click on a peer's name opens that Session.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const viewport = @import("ConversationViewport.zig");
const selecting = @import("transcript_selection.zig");
const TerminalText = @import("TerminalText.zig");
const Spot = selecting.Spot;
const Self = @This();
const Hover = @import("widgets/Hover.zig");

document: *const viewport.Document,
first: viewport.Position = .{},
next: viewport.Position = .end,
size: vxfw.Size = .{},
method: vaxis.gwidth.Method = .unicode,
colour: bool = true,
style: vaxis.Style = .{},
hover: Hover = .{},
colours: viewport.Colours = .{},
/// Report the rows below this viewport without prescribing input.
more: bool = false,
/// What the screen does for this widget's gestures; without it the mouse
/// does nothing here.
handler: ?Handler = null,
/// The drag under way, if any. Nothing of it remains after release.
selection: ?Selection = null,
/// The cells last drawn: valid until the next frame, as App's hit testing is.
drawn: Drawn = .{},

pub const Handler = struct {
    userdata: *anyopaque,
    /// A click on a peer's name: the ID of the Session it names, which is
    /// the document's bytes, so copy it before the document changes.
    on_open: ?*const fn (*anyopaque, *vxfw.EventContext, []const u8) anyerror!void = null,
    /// What a release did: `Copied N lines`, or why nothing was copied.
    on_notice: *const fn (*anyopaque, *vxfw.EventContext, []const u8) anyerror!void,
    /// A drag held at the top or bottom row moves the view one row, through
    /// rows already loaded (`up` toward older rows).
    on_scroll: *const fn (*anyopaque, *vxfw.EventContext, up: bool) anyerror!void,
    /// A click anywhere but a peer's name: the drawn row it landed on, as
    /// its logical line's origin-relative offset and wrapped row.
    on_click: ?*const fn (*anyopaque, *vxfw.EventContext, viewport.Position) anyerror!void = null,
    /// Caller-owned eligibility for actionable rows (ordinary prose stays inert).
    action_at: ?*const fn (*anyopaque, viewport.Position) bool = null,
};

pub const Selection = struct {
    press: Point,
    anchor: Spot,
    head: Spot,
    /// A press becomes a drag once the pointer reaches another cell.
    dragging: bool = false,
    edge: enum { none, up, down } = .none,
    ticking: bool = false,
    /// The first row shown when `head` was last set: held at an edge, the
    /// head moves to the edge row only once the view has scrolled.
    view: viewport.Position = .{},
};

/// A cell in this widget's coordinates; a forwarded drag may be outside it.
const Point = struct { row: i32, col: i32 };

/// What the last draw showed, as plain data: events lay out the row under
/// the pointer again from retained bytes, never from a past frame's cells.
const Drawn = struct {
    /// Which text was drawn: a selection in other text is dropped.
    document: ?*const viewport.Document = null,
    replacements: u32 = 0,
    width: u16 = 0,
    height: u16 = 0,
    /// The first row drawn, its line as an absolute offset.
    line: u64 = 0,
    row: u16 = 0,
    continuation: ?viewport.Position = null,
};

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

/// The first omitted row of this frame, valid only for the same document.
/// Open gestures use this position, not a second saved preview or fold.
pub fn continuation(self: *const Self) ?viewport.Position {
    if (self.drawn.document != self.document or self.drawn.replacements != self.document.replacements) return null;
    return self.drawn.continuation;
}

/// Whether mouse geometry still names this exact retained document frame.
pub fn drawnNow(self: *const Self) bool {
    return self.drawn.document == self.document and self.drawn.replacements == self.document.replacements and self.drawn.width != 0 and self.drawn.height != 0;
}

/// Whether a press or drag is under way.
pub fn dragging(self: *const Self) bool {
    return self.selection != null;
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.hover.handleEvent(ctx, input);
    switch (input) {
        .mouse => |value| try self.mouse(ctx, value),
        // vxfw sends no release once the pointer has left: a press or drag
        // ends there, copying nothing, so no highlight stays behind.
        .mouse_leave => if (self.selection != null) {
            self.selection = null;
            ctx.redraw = true;
        },
        .tick => {
            const selection = if (self.selection) |*value| value else return;
            if (!selection.dragging or selection.edge == .none) {
                selection.ticking = false;
                return;
            }
            const handler = self.handler orelse return;
            try handler.on_scroll(handler.userdata, ctx, selection.edge == .up);
            // The next draw extends the selection to the new edge row.
            ctx.redraw = true;
            try ctx.tick(edge_interval_ms, self.widget());
        },
        else => {},
    }
}

const edge_interval_ms = 50;

/// Source-cell peer links, caller-approved rows and the explicit continuation.
fn drawHover(self: *Self, arena: std.mem.Allocator, surface: vxfw.Surface) !void {
    self.hover.targets = &.{};
    const handler = self.handler orelse return;
    var targets: std.ArrayList(Hover.Rect) = .empty;
    if (handler.on_open != null) for (0..self.drawn.height) |row| {
        const cells = surface.buffer[row * surface.size.width ..][0..surface.size.width];
        for (try selecting.peers(self.document, cells, arena)) |span| {
            const rect: Hover.Rect = .{ .row = @intCast(row), .col = span.start, .width = span.end - span.start };
            try targets.append(arena, rect);
            if (self.hover.contains(rect)) for (cells[span.start..span.end]) |*cell| {
                cell.style.ul_style = .single;
            };
        }
    };
    if (handler.on_click != null) if (handler.action_at) |action_at| {
        var rows = self.document.rowsFrom(self.layout(), self.laidFirst());
        for (0..self.drawn.height) |row| {
            const position = rows.next() orelse break;
            if (!action_at(handler.userdata, position)) continue;
            const rect: Hover.Rect = .{ .row = @intCast(row), .width = surface.size.width };
            try targets.append(arena, rect);
            if (self.hover.contains(rect)) for (surface.buffer[row * surface.size.width ..][0..surface.size.width]) |*cell| {
                cell.style.bg = self.colours.selection;
                cell.style.reverse = self.colours.selection == .default;
            };
        }
    };
    if (handler.on_click != null and self.continuation() != null) {
        const rect: Hover.Rect = .{ .row = self.drawn.height, .width = surface.size.width };
        try targets.append(arena, rect);
        if (self.hover.contains(rect)) for (surface.buffer[@as(usize, self.drawn.height) * surface.size.width ..]) |*cell| {
            cell.style.bg = self.colours.selection;
            cell.style.reverse = self.colours.selection == .default;
        };
    }
    self.hover.targets = targets.items;
}

/// One mouse event in this widget's coordinates.
fn mouse(self: *Self, ctx: *vxfw.EventContext, value: vaxis.Mouse) anyerror!void {
    const handler = self.handler orelse return;
    if (!self.drawnNow()) {
        self.selection = null;
        return;
    }
    const at: Point = .{ .row = value.row, .col = value.col };
    switch (value.type) {
        .press => {
            if (value.button != .left) return;
            const spot = try self.spotAt(ctx.alloc, at);
            self.selection = .{ .press = at, .anchor = spot, .head = spot };
            ctx.consumeEvent();
        },
        .drag => {
            const selection = if (self.selection) |*held| held else return;
            if (!selection.dragging and std.meta.eql(at, selection.press)) return;
            selection.dragging = true;
            selection.head = try self.spotAt(ctx.alloc, at);
            selection.view = self.first;
            selection.edge = if (at.row <= 0) .up else if (at.row >= self.drawn.height - 1) .down else .none;
            if (selection.edge != .none and !selection.ticking) {
                selection.ticking = true;
                try ctx.tick(edge_interval_ms, self.widget());
            }
            ctx.consumeAndRedraw();
        },
        .release => {
            const selection = self.selection orelse return;
            self.selection = null;
            ctx.consumeAndRedraw();
            if (selection.dragging) return copy(ctx, handler, try selecting.copy(ctx.alloc, self.document, .of(selection.anchor, selection.head)));
            if (!std.meta.eql(at, selection.press)) return;
            // The state row is not the last text row, even when selection's
            // clamped anchor happens to fall on a link in that text.
            if (at.row == self.drawn.height) if (self.continuation()) |position| {
                if (handler.on_click) |clicked| try clicked(handler.userdata, ctx, position);
                return;
            };
            if (selecting.opens(self.document, selection.anchor)) |id| return if (handler.on_open) |open| open(handler.userdata, ctx, id);
            const clicked = handler.on_click orelse return;
            if (at.row >= 0 and at.row < self.drawn.height) if (self.rowPosition(self.laidFirst(), @intCast(at.row))) |position| try clicked(handler.userdata, ctx, position);
        },
        .motion => {},
    }
}

/// Sends what a release copies, once, and says what happened.
fn copy(ctx: *vxfw.EventContext, handler: Handler, result: selecting.Copy) !void {
    // App frees the command's bytes once written.
    if (result == .text) try ctx.addCmd(.{ .copy_to_clipboard = result.text.bytes });
    var buffer: [64]u8 = undefined;
    if (selecting.notice(result, &buffer)) |text| try handler.on_notice(handler.userdata, ctx, text);
}

fn layout(self: *const Self) viewport.Layout {
    return .{ .width = self.drawn.width, .method = self.method };
}

/// The first row the last draw showed, in the current text. Once its line
/// has been evicted the text's first row stands in.
fn laidFirst(self: *const Self) viewport.Position {
    const offset = selecting.relative(self.document, self.drawn.line) orelse return .{};
    return self.document.clamp(self.layout(), .{ .offset = offset, .row = self.drawn.row });
}

/// The logical line and wrapped row `row` rows below `first`, or null
/// below the text.
fn rowPosition(self: *const Self, first: viewport.Position, row: u16) ?viewport.Position {
    if (self.document.text().len == 0) return null;
    if (self.document.measure(self.layout(), first, row +| 1).rows <= row) return null;
    return self.document.down(self.layout(), first, row);
}

/// Row `row` of cells laid out from `first`, for the selection core.
fn rowAt(self: *const Self, cells: []const vaxis.Cell, first: viewport.Position, index: u16) selecting.Row {
    return .{ .document = self.document, .cells = cells, .line = if (self.rowPosition(first, index)) |position| position.offset else null };
}

/// The spot under a pointer, laying out its row from the retained text at
/// the position last drawn. A pointer above or below the rows takes the
/// first row's start or the last row's end.
fn spotAt(self: *const Self, gpa: std.mem.Allocator, at: Point) !Spot {
    const last_row: i32 = self.drawn.height - 1;
    const index: u16 = @intCast(std.math.clamp(at.row, 0, last_row));
    const col: i32 = if (at.row < 0) 0 else if (at.row > last_row) self.drawn.width else at.col;
    const first = self.laidFirst();
    const cells = try gpa.alloc(vaxis.Cell, self.drawn.width);
    defer gpa.free(cells);
    @memset(cells, .{});
    if (self.rowPosition(first, index)) |position| {
        var screen: vaxis.Screen = .{ .width = self.drawn.width, .height = 1, .width_method = self.method, .buf = cells };
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = screen.width, .height = 1, .screen = &screen };
        _ = self.document.draw(window, position, true, false, .{}, .{});
    }
    return self.rowAt(cells, first, index).spot(col);
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.hover.targets = &.{};
    const surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    self.size = surface.size;
    const shape: viewport.Layout = .{ .width = @max(1, self.size.width), .method = self.method };
    self.first = self.document.first(shape, self.size.height);
    @memset(surface.buffer, .{ .style = self.style });
    var screen: vaxis.Screen = .{
        .width = surface.size.width,
        .height = surface.size.height,
        .width_method = self.method,
        .buf = surface.buffer,
    };
    const window: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = &screen,
    };
    const below = if (!self.more or self.size.height < 2) 0 else self.document.measure(shape, self.first, std.math.maxInt(u16)).rows;
    var text = window;
    if (below > self.size.height) text.height -= 1;
    const drawn = self.document.draw(text, self.first, true, self.colour, self.style, self.colours);
    self.next = drawn.next;
    if (below > self.size.height) {
        var quiet = self.style;
        quiet.fg = self.colours.quiet;
        const remaining = try std.fmt.allocPrint(ctx.arena, "… {d} more lines", .{below - drawn.rows});
        _ = window.child(.{ .y_off = text.height, .height = 1 }).print(&.{.{ .text = remaining, .style = quiet }}, .{ .wrap = .none });
    }
    // Replaced content (another document, or this one cleared) ends a press
    // or drag over the old text without copying.
    if (self.drawn.document != self.document or self.drawn.replacements != self.document.replacements) self.selection = null;
    self.drawn = .{
        .document = self.document,
        .replacements = self.document.replacements,
        .width = surface.size.width,
        .height = text.height,
        .line = self.document.origin + @min(self.first.offset, self.document.text().len),
        .row = self.first.row,
        .continuation = if (below > self.size.height) drawn.next else null,
    };
    try self.drawHover(ctx.arena, surface);
    if (self.selection) |*selection| if (selection.dragging and surface.buffer.len != 0) {
        const width = surface.size.width;
        const height = text.height;
        // Held at an edge, the selection follows the rows scrolled in; until
        // the view moves, it keeps the pointer's column.
        if (!std.meta.eql(selection.view, self.first)) switch (selection.edge) {
            .none => {},
            .up => selection.head = self.rowAt(surface.buffer[0..width], self.first, 0).spot(0),
            .down => selection.head = self.rowAt(surface.buffer[(height - 1) * width ..][0..width], self.first, height - 1).spot(width),
        };
        selection.view = self.first;
        const range: selecting.Range = .of(selection.anchor, selection.head);
        const columns = try ctx.arena.alloc(bool, width);
        var rows = self.document.rowsFrom(self.layout(), self.first);
        for (0..height) |index| {
            const cells = surface.buffer[index * width ..][0..width];
            const line = if (rows.next()) |position| position.offset else null;
            (selecting.Row{ .document = self.document, .cells = cells, .line = line }).covered(range, columns);
            for (cells, columns) |*cell, selected| {
                if (selected) cell.style.reverse = true;
            }
        }
    };
    return surface;
}

test "DocumentView user text keeps theme contrast without terminal dim" {
    const widget_style = @import("widget_style.zig");
    const view = @import("overview_view.zig");
    const Check = struct {
        fn rgb(c: vaxis.Color) [3]u8 {
            return switch (c) {
                .rgb => |value| value,
                .index => |i| if (i < 232) blk: {
                    const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
                    const n: usize = i - 16;
                    break :blk .{ levels[n / 36], levels[n / 6 % 6], levels[n % 6] };
                } else @splat(@intCast(8 + 10 * (@as(u16, i) - 232))),
                else => unreachable,
            };
        }
        fn luminance(c: [3]u8) f64 {
            var total: f64 = 0;
            for (c, [_]f64{ 0.2126, 0.7152, 0.0722 }) |channel, weight| {
                const value = @as(f64, @floatFromInt(channel)) / 255;
                total += weight * (if (value <= 0.04045) value / 12.92 else std.math.pow(f64, (value + 0.055) / 1.055, 2.4));
            }
            return total;
        }
    };
    const document = try std.testing.allocator.create(viewport.Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    try document.append("\x1b[2muser text\x1b[0m");
    for ([_]?view.Rgb{ .{ 255, 255, 255 }, null }) |background| for ([_]view.Caps.Depth{ .direct, .indexed }) |depth| {
        const quiet = widget_style.of(.{ .background = background, .depth = depth }, .{ .colour = .quiet });
        const normal = widget_style.of(.{ .background = background, .depth = depth }, .{});
        var transcript: Self = .{ .document = document, .style = normal, .colours = .{ .quiet = quiet.fg } };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const surface = try transcript.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 20, .height = 2 }, .cell_size = .{} });
        const style = surface.readCell(0, 0).style;
        try std.testing.expect(!style.dim);
        try std.testing.expectEqual(quiet.fg, style.fg);
        const fg = Check.luminance(Check.rgb(style.fg));
        const bg = Check.luminance(Check.rgb(style.bg));
        try std.testing.expect((@max(fg, bg) + 0.05) / (@min(fg, bg) + 0.05) >= 4.5);
    };
}

test "DocumentView forwards foreground roles and keeps its overflow state quiet" {
    const document = try std.testing.allocator.create(viewport.Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    try document.append("\x1b[94mu\x1b[90mq\x1b[33ma\x1b[91mf\x1b[0m\n\x1b[2muser text\x1b[0m\nthird\nfourth");
    document.top = .{};
    const colours: viewport.Colours = .{
        .user = .{ .rgb = .{ 17, 34, 51 } },
        .quiet = .{ .index = 102 },
        .attention = .{ .index = 143 },
        .failure = .{ .rgb = .{ 170, 187, 204 } },
    };
    const plain: vaxis.Style = .{ .fg = .{ .index = 255 }, .bg = .{ .index = 19 } };
    var transcript: Self = .{ .document = document, .style = plain, .colours = colours, .more = true };
    for ([_]bool{ true, false }) |colour| {
        transcript.colour = colour;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const surface = try transcript.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 32, .height = 3 }, .cell_size = .{} });
        for ([_]vaxis.Color{ colours.user, colours.quiet, colours.attention, colours.failure }, 0..) |foreground, column| {
            try std.testing.expectEqual(if (colour) foreground else plain.fg, surface.readCell(@intCast(column), 0).style.fg);
        }
        try std.testing.expectEqual(if (colour) colours.quiet else plain.fg, surface.readCell(0, 1).style.fg);
        try std.testing.expectEqualStrings("…", surface.readCell(0, 2).char.grapheme);
        try std.testing.expectEqual(colours.quiet, surface.readCell(0, 2).style.fg);
        for (surface.buffer) |cell| try std.testing.expectEqual(plain.bg, cell.style.bg);
    }
}

test "DocumentView draws only the requested rows and retains the first unread row" {
    const document = try std.testing.allocator.create(viewport.Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    try document.append("first\nsecond\nthird\nfourth");
    document.top = .{ .offset = 6 };
    var transcript: Self = .{ .document = document, .style = .{ .bg = .{ .index = 19 } } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const surface = try transcript.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 8, .height = 2 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(usize, 16), surface.buffer.len);
    try std.testing.expectEqualStrings("s", surface.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("t", surface.readCell(0, 1).char.grapheme);
    try std.testing.expectEqual(viewport.Position{ .offset = 19 }, transcript.next);
    try std.testing.expectEqualStrings("first\nsecond\nthird\nfourth", document.text());
    for (surface.buffer) |cell| try std.testing.expectEqual(vaxis.Color{ .index = 19 }, cell.style.bg);
    for ([_]vxfw.Size{ .{ .width = 1, .height = 1 }, .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 0 } }) |size| {
        const resized = try transcript.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{} });
        try std.testing.expect(resized.size.width <= size.width and resized.size.height <= size.height);
        try std.testing.expectEqual(viewport.Position{ .offset = 6 }, document.top.?);
    }
    const restored = try transcript.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 8, .height = 2 }, .cell_size = .{} });
    try std.testing.expectEqualDeep(surface.buffer, restored.buffer);
    try std.testing.expectEqual(viewport.Position{ .offset = 19 }, transcript.next);
}

/// A Transcript under test with a screen that records what its gestures did.
const Harness = struct {
    document: *viewport.Document,
    transcript: Self = undefined,
    arena: std.heap.ArenaAllocator,
    ctx: vxfw.EventContext,
    opened: std.ArrayList(u8) = .empty,
    notices: std.ArrayList([]const u8) = .empty,
    clicks: std.ArrayList(viewport.Position) = .empty,
    scrolls: i32 = 0,
    size: vxfw.Size,

    fn init(text: []const u8, size: vxfw.Size) !*Harness {
        const gpa = std.testing.allocator;
        const self = try gpa.create(Harness);
        self.* = .{ .document = try gpa.create(viewport.Document), .arena = .init(gpa), .ctx = .{ .io = std.testing.io, .alloc = gpa, .cmds = .empty }, .size = size };
        self.document.* = .{ .sidenotes = true };
        try self.document.append(text);
        try self.document.prepare();
        self.transcript = .{ .document = self.document, .handler = .{ .userdata = self, .on_open = open, .on_notice = notice, .on_scroll = scroll, .on_click = click } };
        _ = try self.frame();
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = std.testing.allocator;
        self.clearCommands();
        self.ctx.cmds.deinit(gpa);
        for (self.notices.items) |text| gpa.free(text);
        self.notices.deinit(gpa);
        self.opened.deinit(gpa);
        self.clicks.deinit(gpa);
        self.arena.deinit();
        gpa.destroy(self.document);
        gpa.destroy(self);
    }

    fn frame(self: *Harness) !vxfw.Surface {
        return self.transcript.widget().draw(.{ .arena = self.arena.allocator(), .min = .{}, .max = .{ .width = self.size.width, .height = self.size.height }, .cell_size = .{} });
    }

    fn send(self: *Harness, kind: vaxis.Mouse.Type, col: i16, row: i16) !void {
        try self.transcript.widget().handleEvent(&self.ctx, .{ .mouse = .{ .col = col, .row = row, .button = if (kind == .motion) .none else .left, .mods = .{}, .type = kind } });
    }

    fn drag(self: *Harness, from: [2]i16, to: [2]i16) !void {
        try self.send(.press, from[0], from[1]);
        try self.send(.drag, to[0], to[1]);
        _ = try self.frame();
    }

    /// The clipboard writes queued since the last call, joined by `|`.
    fn copies(self: *Harness, buffer: []u8) []const u8 {
        var length: usize = 0;
        for (self.ctx.cmds.items) |command| switch (command) {
            .copy_to_clipboard => |text| {
                if (length != 0) {
                    buffer[length] = '|';
                    length += 1;
                }
                @memcpy(buffer[length..][0..text.len], text);
                length += text.len;
            },
            else => {},
        };
        self.clearCommands();
        return buffer[0..length];
    }

    fn clearCommands(self: *Harness) void {
        for (self.ctx.cmds.items) |command| if (command == .copy_to_clipboard) std.testing.allocator.free(command.copy_to_clipboard);
        self.ctx.cmds.clearRetainingCapacity();
    }

    fn reversed(surface: vxfw.Surface, row: u16, buffer: []u8) []const u8 {
        var length: usize = 0;
        for (0..surface.size.width) |column| {
            const cell = surface.readCell(@intCast(column), row);
            buffer[length] = if (cell.style.reverse) '#' else '.';
            length += 1;
        }
        return buffer[0..length];
    }

    fn open(raw: *anyopaque, _: *vxfw.EventContext, id: []const u8) anyerror!void {
        const self: *Harness = @ptrCast(@alignCast(raw));
        try self.opened.appendSlice(std.testing.allocator, id);
    }

    fn notice(raw: *anyopaque, _: *vxfw.EventContext, text: []const u8) anyerror!void {
        const self: *Harness = @ptrCast(@alignCast(raw));
        try self.notices.append(std.testing.allocator, try std.testing.allocator.dupe(u8, text));
    }

    fn click(raw: *anyopaque, _: *vxfw.EventContext, position: viewport.Position) anyerror!void {
        const self: *Harness = @ptrCast(@alignCast(raw));
        try self.clicks.append(std.testing.allocator, position);
    }

    fn scroll(raw: *anyopaque, _: *vxfw.EventContext, up: bool) anyerror!void {
        const self: *Harness = @ptrCast(@alignCast(raw));
        self.scrolls += if (up) -1 else 1;
        const shape: viewport.Layout = .{ .width = self.size.width, .method = self.transcript.method };
        self.document.top = if (up) self.document.up(shape, self.transcript.first, 1) else self.document.down(shape, self.transcript.first, 1).min(self.document.bottom(shape, self.size.height));
    }
};

test "a drag highlights the text it crosses, copies it once on release and clears" {
    // At 16 columns "› fix the flaky store" wraps after "flaky"; the time
    // sits in no margin this narrow and copies nowhere.
    const h = try Harness.init("› \x1b[2mfix the flaky store test\x1b[8m14:20\x1b[0m\n\nnext line\n", .{ .width = 16, .height = 4 });
    defer h.deinit();
    var copied: [256]u8 = undefined;
    var row: [16]u8 = undefined;
    // From "the" on the first row to the "t" of "store" on the wrapped row.
    try h.drag(.{ 6, 0 }, .{ 3, 1 });
    const held = try h.frame();
    try std.testing.expectEqualStrings("......##########", Harness.reversed(held, 0, &row));
    try std.testing.expectEqualStrings("####............", Harness.reversed(held, 1, &row));
    try std.testing.expectEqualStrings("", h.copies(&copied));
    try h.send(.release, 3, 1);
    // One write: the wrap joins without a newline and the indent is left out.
    try std.testing.expectEqualStrings("the flaky st", h.copies(&copied));
    try std.testing.expectEqualStrings("Copied 1 line", h.notices.items[0]);
    const after = try h.frame();
    for (0..4) |index| try std.testing.expectEqualStrings("................", Harness.reversed(after, @intCast(index), &row));
    // Upward, across the empty line, to past the last row's text: whole
    // lines, the empty one included, and the order of the ends doesn't matter.
    try h.drag(.{ 12, 3 }, .{ 0, 0 });
    try h.send(.release, 0, 0);
    try std.testing.expectEqualStrings("› fix the flaky store test\n\nnext line", h.copies(&copied));
    try std.testing.expectEqualStrings("Copied 3 lines", h.notices.items[1]);
    try std.testing.expectEqual(@as(usize, 0), h.opened.items.len);
}

test "a press and release on one cell is a click, and only a peer's name opens" {
    const name = TerminalText.link_open ++ TerminalText.session_link ++ "k7m2qx" ++ TerminalText.link_end ++ "\x1b[4mPlan" ++ TerminalText.link_close ++ "\x1b[0m\x1b[2;8m";
    const h = try Harness.init("\x1b[2;8m← Received message from " ++ name ++ "\x1b[0m\nSee " ++ TerminalText.link_open ++ "https://r.dev" ++ TerminalText.link_end ++ "docs" ++ TerminalText.link_close ++ "\n", .{ .width = 40, .height = 3 });
    defer h.deinit();
    var copied: [64]u8 = undefined;
    // "Plan" is at columns 24 to 27.
    for ([_]i16{ 23, 28, 5 }) |column| {
        try h.send(.press, column, 0);
        try h.send(.release, column, 0);
    }
    try h.send(.press, 4, 1); // a web link stays the terminal's
    try h.send(.release, 4, 1);
    try std.testing.expectEqualStrings("", h.opened.items);
    // Every other click reports its row: the peer line, then the second.
    try std.testing.expectEqualSlices(viewport.Position, &.{ .{}, .{}, .{}, .{ .offset = h.document.nextLine(0).? } }, h.clicks.items);
    try h.send(.press, 27, 0);
    try h.send(.release, 27, 0);
    try std.testing.expectEqualStrings("k7m2qx", h.opened.items);
    try std.testing.expectEqual(@as(usize, 4), h.clicks.items.len);
    // Moving off before release cancels the click; back on the same cell
    // it is a drag over one cluster.
    try h.send(.press, 24, 0);
    try h.send(.drag, 30, 0);
    try h.send(.release, 30, 0);
    try std.testing.expectEqualStrings("k7m2qx", h.opened.items);
    try std.testing.expectEqualStrings("Plan", h.copies(&copied));
    try h.send(.press, 25, 0);
    try h.send(.drag, 26, 0);
    try h.send(.drag, 25, 0);
    try h.send(.release, 25, 0);
    try std.testing.expectEqualStrings("k7m2qx", h.opened.items);
    try std.testing.expectEqualStrings("l", h.copies(&copied));
    try std.testing.expectEqual(@as(usize, 4), h.clicks.items.len);
    // Other buttons and bare motion do nothing.
    try h.transcript.widget().handleEvent(&h.ctx, .{ .mouse = .{ .col = 27, .row = 0, .button = .right, .mods = .{}, .type = .press } });
    try h.send(.motion, 27, 0);
    try std.testing.expect(!h.transcript.dragging());
    try std.testing.expectEqualStrings("", h.copies(&copied));
}

test "DocumentView continuation click never follows the link in the last text row" {
    const peer = TerminalText.link_open ++ TerminalText.session_link ++ "k7m2qx" ++ TerminalText.link_end ++ "Plan" ++ TerminalText.link_close;
    const h = try Harness.init("first\n" ++ peer ++ "\nthird\nfourth", .{ .width = 24, .height = 3 });
    defer h.deinit();
    h.document.top = .{};
    h.transcript.more = true;
    _ = try h.frame();
    const next = h.transcript.continuation().?;
    try h.send(.press, 0, 2);
    try h.send(.release, 0, 2);
    try std.testing.expectEqualStrings("", h.opened.items);
    try std.testing.expectEqualSlices(viewport.Position, &.{next}, h.clicks.items);
    h.document.clear();
    try h.document.append("replacement");
    try std.testing.expectEqual(null, h.transcript.continuation());
}

test "a drag held at an edge scrolls one row a tick and selects the rows it brings in" {
    var text: [10 * 7]u8 = undefined;
    for (0..10) |index| _ = std.fmt.bufPrint(text[index * 7 ..][0..7], "line {d}\n", .{index}) catch unreachable;
    const h = try Harness.init(&text, .{ .width = 10, .height = 3 });
    defer h.deinit();
    h.document.top = .{ .offset = 4 * 7 };
    _ = try h.frame();
    var copied: [128]u8 = undefined;
    try h.drag(.{ 9, 1 }, .{ 2, 0 });
    try std.testing.expect(h.transcript.selection.?.ticking);
    var ticks: usize = 0;
    for (h.ctx.cmds.items) |command| ticks += @intFromBool(command == .tick);
    try std.testing.expectEqual(@as(usize, 1), ticks);
    h.clearCommands();
    for (0..2) |_| {
        try h.transcript.widget().handleEvent(&h.ctx, .tick);
        _ = try h.frame();
    }
    try std.testing.expectEqual(@as(i32, -2), h.scrolls);
    try h.send(.release, 2, 0);
    try std.testing.expectEqualStrings("line 2\nline 3\nline 4\nline 5", h.copies(&copied));
    // Released, a pending tick neither scrolls nor reschedules.
    try h.transcript.widget().handleEvent(&h.ctx, .tick);
    try std.testing.expectEqual(@as(i32, -2), h.scrolls);
    try std.testing.expectEqual(@as(usize, 0), h.ctx.cmds.items.len);
    // Down past the last row.
    try h.drag(.{ 0, 1 }, .{ 3, 5 });
    try h.transcript.widget().handleEvent(&h.ctx, .tick);
    _ = try h.frame();
    try h.send(.release, 3, 5);
    try std.testing.expectEqual(@as(i32, -1), h.scrolls);
    try std.testing.expectEqualStrings("line 3\nline 4\nline 5", h.copies(&copied));
}

test "DocumentView active edge drag survives zero one and two row resizes with queued ticks" {
    var text: [32 * 7]u8 = undefined;
    for (0..32) |index| _ = try std.fmt.bufPrint(text[index * 7 ..][0..7], "line{d:0>2}\n", .{index});
    for ([_]u16{ 10, 46 }) |width| for ([_]bool{ false, true }) |up| {
        const h = try Harness.init(&text, .{ .width = width, .height = 3 });
        defer h.deinit();
        h.document.top = .{ .offset = 8 * 7 };
        h.transcript.more = true;
        _ = try h.frame();
        try h.drag(.{ 0, 0 }, .{ 0, if (up) -1 else 4 });
        try std.testing.expect(h.transcript.selection.?.dragging);
        try std.testing.expect(h.transcript.selection.?.ticking);
        const anchor = h.transcript.selection.?.anchor;

        // Keep the same live drag while collapsing and restoring the view.
        // A previously queued tick is delivered after every resized frame;
        // its redraw must still have text cells for either selection edge.
        for ([_]u16{ 0, 1, 2, 0, 2, 1 }) |height| {
            h.size.height = height;
            _ = try h.frame();
            h.clearCommands();
            const before = h.scrolls;
            try h.transcript.widget().handleEvent(&h.ctx, .tick);
            const surface = try h.frame();
            try std.testing.expectEqual(before + @as(i32, if (up) -1 else 1), h.scrolls);
            try std.testing.expectEqual(height, surface.size.height);
            try std.testing.expectEqual(@as(u16, if (height == 2) 1 else height), h.transcript.drawn.height);
            try std.testing.expect(h.transcript.selection.?.dragging);
            try std.testing.expectEqualDeep(anchor, h.transcript.selection.?.anchor);
            if (height < 2) {
                try std.testing.expectEqual(null, h.transcript.continuation());
                if (height == 1) try std.testing.expect(!std.mem.eql(u8, "…", surface.readCell(0, 0).char.grapheme));
            } else {
                try std.testing.expect(h.transcript.continuation() != null);
                try std.testing.expectEqualStrings("…", surface.readCell(0, 1).char.grapheme);
            }
            var ticks: usize = 0;
            for (h.ctx.cmds.items) |command| ticks += @intFromBool(command == .tick);
            try std.testing.expectEqual(@as(usize, 1), ticks);
        }
        try h.send(.release, 0, 0);
        try std.testing.expect(!h.transcript.dragging());
        const after_release = h.scrolls;
        h.clearCommands();
        try h.transcript.widget().handleEvent(&h.ctx, .tick);
        try std.testing.expectEqual(after_release, h.scrolls);
        try std.testing.expectEqual(@as(usize, 0), h.ctx.cmds.items.len);
    };
}

test "a drag on an edge row keeps the pointer's column until the view scrolls" {
    const h = try Harness.init("alpha beta\ngamma delta\nepsilon\n", .{ .width = 16, .height = 3 });
    defer h.deinit();
    var copied: [64]u8 = undefined;
    // On the first row at the document's top, a frame and an edge tick move
    // nothing, so the selection stays where the pointer is.
    try h.drag(.{ 6, 0 }, .{ 9, 0 });
    try h.transcript.widget().handleEvent(&h.ctx, .tick);
    _ = try h.frame();
    try h.send(.release, 9, 0);
    try std.testing.expectEqualStrings("beta", h.copies(&copied));
    h.clearCommands();
    // Likewise on the last row at the document's bottom.
    try h.drag(.{ 1, 2 }, .{ 3, 2 });
    try h.transcript.widget().handleEvent(&h.ctx, .tick);
    _ = try h.frame();
    try h.send(.release, 3, 2);
    try std.testing.expectEqualStrings("psi", h.copies(&copied));
    try std.testing.expectEqual(@as(i32, 0), h.scrolls);
}

test "a press or drag ends without copying when the pointer leaves or the content is replaced" {
    const h = try Harness.init("first line\nsecond line\n", .{ .width = 16, .height = 3 });
    defer h.deinit();
    var copied: [64]u8 = undefined;
    var row: [16]u8 = undefined;
    // Leaving mid-drag: the highlight goes, and a later release copies nothing.
    try h.drag(.{ 0, 0 }, .{ 4, 1 });
    try std.testing.expectEqualStrings("################", Harness.reversed(try h.frame(), 0, &row));
    try h.transcript.widget().handleEvent(&h.ctx, .mouse_leave);
    try std.testing.expect(!h.transcript.dragging());
    try std.testing.expectEqualStrings("................", Harness.reversed(try h.frame(), 0, &row));
    try h.send(.release, 4, 1);
    try std.testing.expectEqualStrings("", h.copies(&copied));
    // Leaving after a press: the release back on that cell is no click.
    try h.send(.press, 0, 0);
    try h.transcript.widget().handleEvent(&h.ctx, .mouse_leave);
    try h.send(.release, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), h.clicks.items.len);
    // The same document cleared and refilled mid-drag.
    try h.drag(.{ 0, 0 }, .{ 4, 1 });
    h.document.clear();
    try h.document.append("other text\nmore\n");
    try std.testing.expectEqualStrings("................", Harness.reversed(try h.frame(), 0, &row));
    try std.testing.expect(!h.transcript.dragging());
    try h.send(.release, 4, 1);
    try std.testing.expectEqualStrings("", h.copies(&copied));
    // Another document put in place mid-drag, as a Message page is.
    const page = try std.testing.allocator.create(viewport.Document);
    defer std.testing.allocator.destroy(page);
    page.* = .{};
    try page.append("page text\n");
    try h.drag(.{ 0, 0 }, .{ 4, 1 });
    h.transcript.document = page;
    try std.testing.expectEqualStrings("................", Harness.reversed(try h.frame(), 0, &row));
    try h.send(.release, 4, 1);
    try std.testing.expectEqualStrings("", h.copies(&copied));
    try std.testing.expectEqual(@as(usize, 0), h.notices.items.len);
}

test "a drag over cells drawn before the text changed copies the text they showed" {
    const h = try Harness.init("first\nsecond line\nthird\n", .{ .width = 16, .height = 2 });
    defer h.deinit();
    h.document.top = .{ .offset = "first\n".len };
    _ = try h.frame();
    var copied: [64]u8 = undefined;
    // Between the draw and the gesture, a worker drops the line above the
    // view and appends another, as eviction and live output do: the rows
    // drawn keep meaning the text they showed.
    h.document.discardFront(h.document.origin + "first\n".len);
    try h.document.append("fourth\n");
    try h.send(.press, 0, 1);
    try h.send(.drag, 4, 1);
    try h.send(.release, 4, 1);
    try std.testing.expectEqualStrings("third", h.copies(&copied));
}

test "DocumentView peer links and continuation hover only painted actionable spans" {
    const peer = TerminalText.link_open ++ TerminalText.session_link ++ "k7m2qx" ++ TerminalText.link_end ++ "Plan" ++ TerminalText.link_close;
    const h = try Harness.init("See " ++ peer ++ " today\nsecond\nthird\nfourth\n", .{ .width = 24, .height = 3 });
    defer h.deinit();
    h.document.top = .{};
    h.transcript.more = true;
    h.transcript.colours.selection = .{ .index = 2 };
    _ = try h.frame();
    try std.testing.expectEqual(@as(usize, 2), h.transcript.hover.targets.len);
    try std.testing.expectEqual(Hover.Rect{ .row = 0, .col = 4, .width = 4 }, h.transcript.hover.targets[0]);
    try h.transcript.widget().handleEvent(&h.ctx, .mouse_enter);
    try h.send(.motion, 5, 0);
    const peer_hover = try h.frame();
    for (4..8) |col| try std.testing.expectEqual(.single, peer_hover.readCell(col, 0).style.ul_style);
    try std.testing.expectEqual(vaxis.Mouse.Shape.pointer, h.ctx.cmds.items[h.ctx.cmds.items.len - 1].set_mouse_shape);
    try std.testing.expect(h.transcript.selection == null and h.opened.items.len == 0 and h.clicks.items.len == 0);
    try h.send(.motion, 8, 0);
    try std.testing.expectEqual(vaxis.Mouse.Shape.default, h.ctx.cmds.items[h.ctx.cmds.items.len - 1].set_mouse_shape);
    try h.send(.motion, 3, 2);
    const continuation_hover = try h.frame();
    for (0..24) |col| try std.testing.expectEqual(h.transcript.colours.selection, continuation_hover.readCell(col, 2).style.bg);
    try std.testing.expect(h.transcript.selection == null and h.clicks.items.len == 0);
    const next = h.transcript.continuation().?;
    try h.send(.press, 3, 2);
    try h.send(.release, 3, 2);
    try std.testing.expectEqualSlices(viewport.Position, &.{next}, h.clicks.items);
    try h.transcript.widget().handleEvent(&h.ctx, .mouse_leave);
    const left = try h.frame();
    try std.testing.expectEqual(h.transcript.style.bg, left.readCell(0, 2).style.bg);
    h.transcript.handler.?.on_open = null;
    h.transcript.handler.?.on_click = null;
    _ = try h.frame();
    try std.testing.expectEqual(@as(usize, 0), h.transcript.hover.targets.len);
}

test "DocumentView wide peer glyph continuation cells share hover and click geometry" {
    const peer = TerminalText.link_open ++ TerminalText.session_link ++ "k7m2qx" ++ TerminalText.link_end ++ "設計" ++ TerminalText.link_close;
    const h = try Harness.init("See " ++ peer ++ " end\n", .{ .width = 16, .height = 1 });
    defer h.deinit();
    try std.testing.expectEqualSlices(Hover.Rect, &.{.{ .row = 0, .col = 4, .width = 4 }}, h.transcript.hover.targets);
    try h.transcript.widget().handleEvent(&h.ctx, .mouse_enter);
    try h.send(.motion, 5, 0);
    try std.testing.expectEqual(vaxis.Mouse.Shape.pointer, h.ctx.cmds.items[h.ctx.cmds.items.len - 1].set_mouse_shape);
    const hovered = try h.frame();
    for (4..8) |col| try std.testing.expectEqual(.single, hovered.readCell(col, 0).style.ul_style);
    try std.testing.expect(h.transcript.selection == null and h.opened.items.len == 0);
    try h.send(.press, 5, 0);
    try h.send(.release, 5, 0);
    try std.testing.expectEqualStrings("k7m2qx", h.opened.items);
    try h.transcript.widget().handleEvent(&h.ctx, .mouse_leave);
    try std.testing.expectEqual(vaxis.Mouse.Shape.default, h.ctx.cmds.items[h.ctx.cmds.items.len - 1].set_mouse_shape);
}

test "DocumentView hover and drag highlight measure each visible line a bounded number of times" {
    const Eligible = struct {
        fn none(_: *anyopaque, _: viewport.Position) bool {
            return false;
        }
    };
    var measured: [2]usize = undefined;
    const heights = [_]u16{ 64, 2048 };
    for (heights, &measured) |height, *count| {
        const text = try std.testing.allocator.alloc(u8, 2 * @as(usize, height));
        defer std.testing.allocator.free(text);
        for (0..height) |line| @memcpy(text[2 * line ..][0..2], "x\n");
        const h = try Harness.init(text, .{ .width = 8, .height = height });
        defer h.deinit();
        h.transcript.handler.?.action_at = Eligible.none;
        try h.send(.press, 0, 0);
        try h.send(.drag, 1, 0);
        viewport.measured_lines = 0;
        const frame = try h.frame();
        try std.testing.expect(frame.buffer[0].style.reverse);
        count.* = viewport.measured_lines;
    }
    // Every line is one row, so a linear frame costs at most 32 times as
    // much for 32 times the rows; the quadratic walk cost about 1000 times.
    try std.testing.expect(measured[1] <= 32 * measured[0]);
}
