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
hover_style: vaxis.Style = .{ .ul_style = .single },
hover: Hover = .{},
colours: viewport.Colours = .{},
more: bool = false,
handler: ?Handler = null,
selection: ?Selection = null,
drawn: Drawn = .{},

pub const Handler = struct {
    userdata: *anyopaque,
    on_open: ?*const fn (*anyopaque, *vxfw.EventContext, []const u8) anyerror!void = null,
    on_notice: *const fn (*anyopaque, *vxfw.EventContext, []const u8) anyerror!void,
    on_scroll: *const fn (*anyopaque, *vxfw.EventContext, up: bool) anyerror!void,
    on_click: ?*const fn (*anyopaque, *vxfw.EventContext, viewport.Position) anyerror!void = null,
    action_at: ?*const fn (*anyopaque, viewport.Position) bool = null,
};

pub const Selection = struct {
    press: Point,
    anchor: Spot,
    head: Spot,
    dragging: bool = false,
    edge: enum { none, up, down } = .none,
    ticking: bool = false,
    view: viewport.Position = .{},
};

const Point = struct { row: i32, col: i32 };

const Drawn = struct {
    document: ?*const viewport.Document = null,
    replacements: u32 = 0,
    width: u16 = 0,
    height: u16 = 0,
    line: u64 = 0,
    row: u16 = 0,
    continuation: ?viewport.Position = null,
};

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

pub fn continuation(self: *const Self) ?viewport.Position {
    if (self.drawn.document != self.document or self.drawn.replacements != self.document.replacements) return null;
    return self.drawn.continuation;
}

pub fn drawnNow(self: *const Self) bool {
    return self.drawn.document == self.document and self.drawn.replacements == self.document.replacements and self.drawn.width != 0 and self.drawn.height != 0;
}

pub fn dragging(self: *const Self) bool {
    return self.selection != null;
}

pub fn cancelSelection(self: *Self) bool {
    if (self.selection == null) return false;
    self.selection = null;
    return true;
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.hover.handleEvent(ctx, input);
    switch (input) {
        .mouse => |value| try self.mouse(ctx, value),
        // vxfw sends no release once the pointer has left; focus loss likewise
        // cancels the held gesture without copying.
        .mouse_leave, .focus_out => if (self.cancelSelection()) {
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
            ctx.redraw = true;
            try ctx.tick(edge_interval_ms, self.widget());
        },
        else => {},
    }
}

const edge_interval_ms = 50;

fn drawHover(self: *Self, arena: std.mem.Allocator, surface: vxfw.Surface) !void {
    self.hover.targets = &.{};
    const handler = self.handler orelse return;
    var targets: std.ArrayList(Hover.Rect) = .empty;
    if (handler.on_open != null) {
        var peer_hover: selecting.PeerHover = .{};
        for (0..self.drawn.height) |row| {
            const cells = surface.buffer[row * surface.size.width ..][0..surface.size.width];
            try peer_hover.row(self.document, cells, row, &self.hover, &targets, arena);
        }
        peer_hover.paint(surface);
    }
    if (handler.on_click != null) if (handler.action_at) |action_at| {
        var rows = self.document.rowsFrom(self.layout(), self.laidFirst());
        for (0..self.drawn.height) |row| {
            const position = rows.next() orelse break;
            if (!action_at(handler.userdata, position)) continue;
            const rect: Hover.Rect = .{ .row = @intCast(row), .width = surface.size.width };
            try targets.append(arena, rect);
            const open = self.colour and self.document.toolIsOpen(position.offset);
            if (!open and self.hover.contains(rect)) self.hovering(surface.buffer[row * surface.size.width ..][0..surface.size.width]);
        }
    };
    if (handler.on_click != null and self.continuation() != null) {
        const rect: Hover.Rect = .{ .row = self.drawn.height, .width = surface.size.width };
        try targets.append(arena, rect);
        if (self.hover.contains(rect)) self.hovering(surface.buffer[@as(usize, self.drawn.height) * surface.size.width ..]);
    }
    self.hover.targets = targets.items;
}

fn hovering(self: *const Self, cells: []vaxis.Cell) void {
    for (cells) |*cell| cell.style = Hover.look(cell.style, self.hover_style);
}

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

fn copy(ctx: *vxfw.EventContext, handler: Handler, result: selecting.Copy) !void {
    if (result == .text) try ctx.addCmd(.{ .copy_to_clipboard = result.text.bytes });
    var buffer: [64]u8 = undefined;
    if (selecting.notice(result, &buffer)) |text| try handler.on_notice(handler.userdata, ctx, text);
}

fn layout(self: *const Self) viewport.Layout {
    return .{ .width = self.drawn.width, .method = self.method };
}

fn laidFirst(self: *const Self) viewport.Position {
    const offset = selecting.relative(self.document, self.drawn.line) orelse return .{};
    return self.document.clamp(self.layout(), .{ .offset = offset, .row = self.drawn.row });
}

fn rowPosition(self: *const Self, first: viewport.Position, row: u16) ?viewport.Position {
    if (self.document.text().len == 0) return null;
    if (self.document.measure(self.layout(), first, row +| 1).rows <= row) return null;
    return self.document.down(self.layout(), first, row);
}

fn rowAt(self: *const Self, cells: []const vaxis.Cell, first: viewport.Position, index: u16) selecting.Row {
    return .{ .document = self.document, .cells = cells, .line = if (self.rowPosition(first, index)) |position| self.document.selectionLine(self.layout(), position) else null };
}

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
    const surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), ctx.max.size());
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
            const line = if (rows.next()) |position| self.document.selectionLine(self.layout(), position) else null;
            (selecting.Row{ .document = self.document, .cells = cells, .line = line }).covered(range, columns);
            selecting.highlight(cells, columns);
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
                .index => |i| @import("theme.zig").xtermRgb(i),
                else => unreachable,
            };
        }
        const luminance = @import("theme.zig").relativeLuminance;
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
        const surface = try transcript.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 20, .height = 2 }, .cell_size = .{} });
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
        const surface = try transcript.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 32, .height = 3 }, .cell_size = .{} });
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
    const surface = try transcript.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 8, .height = 2 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(usize, 16), surface.buffer.len);
    try std.testing.expectEqualStrings("s", surface.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("t", surface.readCell(0, 1).char.grapheme);
    try std.testing.expectEqual(viewport.Position{ .offset = 19 }, transcript.next);
    try std.testing.expectEqualStrings("first\nsecond\nthird\nfourth", document.text());
    for (surface.buffer) |cell| try std.testing.expectEqual(vaxis.Color{ .index = 19 }, cell.style.bg);
    for ([_]vxfw.Size{ .{ .width = 1, .height = 1 }, .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 0 } }) |size| {
        const resized = try transcript.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{} });
        try std.testing.expect(resized.size.width <= size.width and resized.size.height <= size.height);
        try std.testing.expectEqual(viewport.Position{ .offset = 6 }, document.top.?);
    }
    const restored = try transcript.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 8, .height = 2 }, .cell_size = .{} });
    try std.testing.expectEqualDeep(surface.buffer, restored.buffer);
    try std.testing.expectEqual(viewport.Position{ .offset = 19 }, transcript.next);
}

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
        return self.transcript.widget().draw(.{ .arena = self.arena.allocator(), .cell_arena = self.arena.allocator(), .min = .{}, .max = .{ .width = self.size.width, .height = self.size.height }, .cell_size = .{} });
    }

    fn send(self: *Harness, kind: vaxis.Mouse.Type, col: i16, row: i16) !void {
        try self.transcript.widget().handleEvent(&self.ctx, .{ .mouse = .{ .col = col, .row = row, .button = if (kind == .motion) .none else .left, .mods = .{}, .type = kind } });
    }

    fn drag(self: *Harness, from: [2]i16, to: [2]i16) !void {
        try self.send(.press, from[0], from[1]);
        try self.send(.drag, to[0], to[1]);
        _ = try self.frame();
    }

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
    const h = try Harness.init(TerminalText.leader_on ++ "›" ++ TerminalText.leader_off ++ " \x1b[2mfix the flaky store test\x1b[8m14:20\x1b[0m\n\nnext line\n", .{ .width = 16, .height = 4 });
    defer h.deinit();
    var copied: [256]u8 = undefined;
    var row: [16]u8 = undefined;
    try h.drag(.{ 6, 0 }, .{ 3, 1 });
    const held = try h.frame();
    try std.testing.expectEqualStrings("......##########", Harness.reversed(held, 0, &row));
    try std.testing.expectEqualStrings("####............", Harness.reversed(held, 1, &row));
    try std.testing.expectEqualStrings("", h.copies(&copied));
    try h.send(.release, 3, 1);
    try std.testing.expectEqualStrings("the flaky st", h.copies(&copied));
    try std.testing.expectEqualStrings("Copied 1 line", h.notices.items[0]);
    const after = try h.frame();
    for (0..4) |index| try std.testing.expectEqualStrings("................", Harness.reversed(after, @intCast(index), &row));
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
    for ([_]i16{ 23, 28, 5 }) |column| {
        try h.send(.press, column, 0);
        try h.send(.release, column, 0);
    }
    try h.send(.press, 4, 1);
    try h.send(.release, 4, 1);
    try std.testing.expectEqualStrings("", h.opened.items);
    try std.testing.expectEqualSlices(viewport.Position, &.{ .{}, .{}, .{}, .{ .offset = h.document.nextLine(0).? } }, h.clicks.items);
    try h.send(.press, 27, 0);
    try h.send(.release, 27, 0);
    try std.testing.expectEqualStrings("k7m2qx", h.opened.items);
    try std.testing.expectEqual(@as(usize, 4), h.clicks.items.len);
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
    try h.transcript.widget().handleEvent(&h.ctx, .{ .mouse = .{ .col = 27, .row = 0, .button = .right, .mods = .{}, .type = .press } });
    try h.send(.motion, 27, 0);
    try std.testing.expect(!h.transcript.dragging());
    try std.testing.expectEqualStrings("", h.copies(&copied));
}

test "SUI-156 DocumentView focus loss cancels a held Session link gesture" {
    const peer = TerminalText.link_open ++ TerminalText.session_link ++ "k7m2qx" ++ TerminalText.link_end ++ "Plan" ++ TerminalText.link_close;
    for ([_][]const u8{ peer, TerminalText.body_on ++ peer ++ TerminalText.body_off }) |content| {
        const h = try Harness.init(content, .{ .width = 40, .height = 3 });
        defer h.deinit();
        _ = try h.frame();
        try h.send(.press, 2, 0);
        try std.testing.expect(h.transcript.dragging());
        try h.transcript.widget().handleEvent(&h.ctx, .focus_out);
        try std.testing.expect(!h.transcript.dragging());
        try h.send(.release, 2, 0);
        try std.testing.expectEqualStrings("", h.opened.items);
        try h.send(.press, 2, 0);
        try h.send(.release, 2, 0);
        try std.testing.expectEqualStrings("k7m2qx", h.opened.items);
    }
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
    try h.transcript.widget().handleEvent(&h.ctx, .tick);
    try std.testing.expectEqual(@as(i32, -2), h.scrolls);
    try std.testing.expectEqual(@as(usize, 0), h.ctx.cmds.items.len);
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
    try h.drag(.{ 6, 0 }, .{ 9, 0 });
    try h.transcript.widget().handleEvent(&h.ctx, .tick);
    _ = try h.frame();
    try h.send(.release, 9, 0);
    try std.testing.expectEqualStrings("beta", h.copies(&copied));
    h.clearCommands();
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
    try h.drag(.{ 0, 0 }, .{ 4, 1 });
    try std.testing.expectEqualStrings("################", Harness.reversed(try h.frame(), 0, &row));
    try h.transcript.widget().handleEvent(&h.ctx, .mouse_leave);
    try std.testing.expect(!h.transcript.dragging());
    try std.testing.expectEqualStrings("................", Harness.reversed(try h.frame(), 0, &row));
    try h.send(.release, 4, 1);
    try std.testing.expectEqualStrings("", h.copies(&copied));
    try h.send(.press, 0, 0);
    try h.transcript.widget().handleEvent(&h.ctx, .mouse_leave);
    try h.send(.release, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), h.clicks.items.len);
    try h.drag(.{ 0, 0 }, .{ 4, 1 });
    h.document.clear();
    try h.document.append("other text\nmore\n");
    try std.testing.expectEqualStrings("................", Harness.reversed(try h.frame(), 0, &row));
    try std.testing.expect(!h.transcript.dragging());
    try h.send(.release, 4, 1);
    try std.testing.expectEqualStrings("", h.copies(&copied));
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
    h.document.discardFront(h.document.origin + "first\n".len);
    try h.document.append("fourth\n");
    try h.send(.press, 0, 1);
    try h.send(.drag, 4, 1);
    try h.send(.release, 4, 1);
    try std.testing.expectEqualStrings("third", h.copies(&copied));
}

test "SUI-189 peer hover underlines one complete visible Session link" {
    const link = TerminalText.link_open ++ TerminalText.session_link ++ "k7m2qx" ++ TerminalText.link_end;
    const separated = "See " ++ link ++ "One two" ++ TerminalText.link_close ++ " / " ++ link ++ "Again" ++ TerminalText.link_close ++ "\n";
    const adjacent = "See " ++ link ++ "One two" ++ TerminalText.link_close ++ link ++ "Again" ++ TerminalText.link_close ++ "\n";
    for ([_]struct { width: u16, text: []const u8, other: Hover.Rect }{
        .{ .width = 24, .text = separated, .other = .{ .row = 0, .col = 14, .width = 5 } },
        .{ .width = 24, .text = adjacent, .other = .{ .row = 0, .col = 11, .width = 5 } },
        .{ .width = 7, .text = separated, .other = .{ .row = 2, .width = 5 } },
    }) |case| {
        const h = try Harness.init(case.text, .{ .width = case.width, .height = 4 });
        defer h.deinit();
        const wrapped = case.width == 7;
        const first: Hover.Rect = .{ .row = 0, .col = 4, .width = if (wrapped) 3 else 7 };
        const last: Hover.Rect = .{ .row = 1, .width = 3 };
        const PointCase = struct { col: i16, row: i16, active: enum { first, other, none } };
        for ([_]PointCase{
            .{ .col = 4, .row = 0, .active = .first },
            .{ .col = if (wrapped) 0 else 8, .row = if (wrapped) 1 else 0, .active = .first },
            .{ .col = @intCast(case.other.col), .row = @intCast(case.other.row), .active = .other },
            .{ .col = if (wrapped) 3 else 7, .row = if (wrapped) 1 else 0, .active = .none },
        }) |target| {
            try h.send(.motion, target.col, target.row);
            const frame = try h.frame();
            for (0..frame.size.height) |row| for (0..case.width) |col| {
                const x: i17 = @intCast(col);
                const y: i17 = @intCast(row);
                const expected = switch (target.active) {
                    .first => first.contains(x, y) or (wrapped and last.contains(x, y)),
                    .other => case.other.contains(x, y),
                    .none => false,
                };
                errdefer std.debug.print("width={d}, row={d}, col={d}\n", .{ case.width, row, col });
                try std.testing.expectEqual(expected, frame.readCell(col, row).style.ul_style == .single);
            };
            try h.send(.press, target.col, target.row);
            try h.send(.release, target.col, target.row);
            try std.testing.expectEqualStrings(if (target.active == .none) "" else "k7m2qx", h.opened.items);
            h.opened.clearRetainingCapacity();
        }
    }
    try widePeerHoverWitness();
}

test "SUI-191 DocumentView continuation hovers and activates its painted row" {
    const h = try Harness.init("first\nsecond\nthird\nfourth\n", .{ .width = 24, .height = 3 });
    defer h.deinit();
    h.document.top = .{};
    h.transcript.more = true;
    h.transcript.colours.selection = .{ .index = 2 };
    h.transcript.hover_style = .{ .bg = .{ .index = 5 } };
    _ = try h.frame();
    try std.testing.expectEqualSlices(Hover.Rect, &.{.{ .row = 2, .width = 24 }}, h.transcript.hover.targets);
    try h.send(.motion, 3, 1);
    const outside = try h.frame();
    try std.testing.expectEqual(h.transcript.style.bg, outside.readCell(3, 2).style.bg);
    try h.send(.motion, 3, 2);
    const continuation_hover = try h.frame();
    for (0..24) |col| try std.testing.expectEqual(h.transcript.hover_style.bg, continuation_hover.readCell(col, 2).style.bg);
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

fn widePeerHoverWitness() !void {
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
    try std.testing.expect(measured[1] <= 32 * measured[0]);
}
