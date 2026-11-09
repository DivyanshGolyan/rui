//! Visible rows of the retained conversation. History and reading position
//! remain with the screen; drawing allocates cells only for this viewport.
//! With a `handler`, a drag across its rows copies their text (OSC 52) when
//! released, and a click on a peer's name opens that Session.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const viewport = @import("ConversationViewport.zig");
const TerminalText = @import("TerminalText.zig");
const Self = @This();

document: *const viewport.Document,
first: viewport.Position = .{},
next: viewport.Position = .end,
size: vxfw.Size = .{},
method: vaxis.gwidth.Method = .unicode,
colour: bool = true,
style: vaxis.Style = .{},
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
    on_open: *const fn (*anyopaque, *vxfw.EventContext, []const u8) anyerror!void,
    /// What a release did: `Copied N lines`, or why nothing was copied.
    on_notice: *const fn (*anyopaque, *vxfw.EventContext, []const u8) anyerror!void,
    /// A drag held at the top or bottom row moves the view one row, through
    /// rows already loaded (`up` toward older rows).
    on_scroll: *const fn (*anyopaque, *vxfw.EventContext, up: bool) anyerror!void,
    /// A click anywhere but a peer's name: the drawn row it landed on, as
    /// its logical line's origin-relative offset and wrapped row.
    on_click: ?*const fn (*anyopaque, *vxfw.EventContext, viewport.Position) anyerror!void = null,
};

/// A cell's place in the retained text, in absolute offsets (the document's
/// origin plus the byte), so scrolling and eviction mid-drag never move it.
/// A cell showing text spans its cluster; any other cell is the point
/// between the text before and after it.
const Spot = struct {
    start: u64,
    end: u64,

    fn point(at: u64) Spot {
        return .{ .start = at, .end = at };
    }

    fn within(self: Spot, from: u64, to: u64) bool {
        return if (self.start == self.end) from <= self.start and self.start < to else self.start < to and self.end > from;
    }
};

pub const Selection = struct {
    press: Point,
    anchor: Spot,
    head: Spot,
    /// A press becomes a drag once the pointer reaches another cell.
    dragging: bool = false,
    edge: enum { none, up, down } = .none,
    ticking: bool = false,

    fn from(self: Selection) u64 {
        return @min(self.anchor.start, self.head.start);
    }

    fn to(self: Selection) u64 {
        return @max(self.anchor.end, self.head.end);
    }
};

/// A cell in this widget's coordinates; a forwarded drag may be outside it.
const Point = struct { row: i32, col: i32 };

const Drawn = struct {
    cells: []vaxis.Cell = &.{},
    width: u16 = 0,
    height: u16 = 0,
    origin: u64 = 0,
    /// The retained bytes' address range while drawing: drawn text cells
    /// point into it.
    base: usize = 0,
    length: usize = 0,
};

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

/// Whether a drag is under way. While it is, the screen forwards mouse
/// events outside this widget to `mouse`, so a release anywhere ends it.
pub fn dragging(self: *const Self) bool {
    return self.selection != null;
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (input) {
        .mouse => |value| try self.mouse(ctx, value),
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

/// One mouse event in this widget's coordinates.
pub fn mouse(self: *Self, ctx: *vxfw.EventContext, value: vaxis.Mouse) anyerror!void {
    const handler = self.handler orelse return;
    if (self.drawn.cells.len == 0) return;
    const at: Point = .{ .row = value.row, .col = value.col };
    switch (value.type) {
        .press => {
            if (value.button != .left) return;
            const spot = self.spotAt(at);
            self.selection = .{ .press = at, .anchor = spot, .head = spot };
            ctx.consumeEvent();
        },
        .drag => {
            const selection = if (self.selection) |*held| held else return;
            if (!selection.dragging and std.meta.eql(at, selection.press)) return;
            selection.dragging = true;
            selection.head = self.spotAt(at);
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
            if (selection.dragging) return self.copy(ctx, handler, selection);
            if (!std.meta.eql(at, selection.press)) return;
            if (self.relative(selection.anchor.start)) |offset| {
                if (selection.anchor.start != selection.anchor.end) if (self.document.sessionAt(offset)) |id| return handler.on_open(handler.userdata, ctx, id);
            }
            const clicked = handler.on_click orelse return;
            if (self.rowAt(@intCast(at.row))) |position| try clicked(handler.userdata, ctx, position);
        },
        .motion => {},
    }
}

/// Copies the selection once and says what happened. An empty selection
/// copies nothing and says nothing.
fn copy(self: *Self, ctx: *vxfw.EventContext, handler: Handler, selection: Selection) !void {
    const text_length = self.document.text().len;
    const from = self.relative(selection.from()) orelse 0;
    const to = self.relative(selection.to()) orelse text_length;
    if (from >= to) return;
    const text = try self.document.shownText(ctx.alloc, from, to, TerminalText.clipboard_limit) orelse
        return handler.on_notice(handler.userdata, ctx, "Too large for the clipboard · /copy file");
    if (text.len == 0) return ctx.alloc.free(text);
    var lines: usize = 1 + std.mem.count(u8, text, "\n");
    if (text[text.len - 1] == '\n') lines -= 1;
    // App frees the command's bytes once written.
    try ctx.addCmd(.{ .copy_to_clipboard = text });
    var buffer: [64]u8 = undefined;
    try handler.on_notice(handler.userdata, ctx, std.fmt.bufPrint(&buffer, "Copied {d} line{s}", .{ lines, if (lines == 1) "" else "s" }) catch unreachable);
}

/// An absolute offset in the current text, or null once it has left it.
fn relative(self: *const Self, at: u64) ?usize {
    const origin = self.document.origin;
    if (at < origin) return null;
    const offset = at - origin;
    return if (offset <= self.document.text().len) @intCast(offset) else null;
}

/// Where a drawn text cell's cluster starts, or null for a cell that shows
/// no body text: blank, indent, margin time, `…` or `┆`.
fn source(self: *const Self, cell: vaxis.Cell) ?u64 {
    const address = @intFromPtr(cell.char.grapheme.ptr);
    if (cell.char.grapheme.len == 0 or address < self.drawn.base or address >= self.drawn.base + self.drawn.length) return null;
    const offset = address - self.drawn.base;
    if (!self.document.selectable(offset)) return null;
    return self.drawn.origin + offset;
}

/// Each cell's spot along one drawn row, left to right.
const RowSpots = struct {
    transcript: *const Self,
    cells: []const vaxis.Cell,
    /// The spot of cells before any text, and after the last.
    boundary: ?u64,
    covered: usize = 0,
    cover: Spot = undefined,
    column: usize = 0,

    fn init(transcript: *const Self, row: u16) RowSpots {
        const width = transcript.drawn.width;
        const cells = transcript.drawn.cells[@as(usize, row) * width ..][0..width];
        var spots: RowSpots = .{ .transcript = transcript, .cells = cells, .boundary = null };
        for (cells) |cell| {
            if (transcript.source(cell)) |at| {
                spots.boundary = at;
                break;
            }
        }
        return spots;
    }

    fn next(self: *RowSpots) ?Spot {
        if (self.column == self.cells.len) return null;
        defer self.column += 1;
        const cell = self.cells[self.column];
        if (self.transcript.source(cell)) |at| {
            self.cover = .{ .start = at, .end = at + cell.char.grapheme.len };
            self.covered = self.column + @max(cell.char.width, 1);
            self.boundary = self.cover.end;
            return self.cover;
        }
        if (self.column < self.covered) return self.cover;
        return Spot.point(self.boundary orelse return null);
    }
};

fn spotAt(self: *const Self, at: Point) Spot {
    const last_row: i32 = self.drawn.height - 1;
    if (at.row < 0) return self.spotAt(.{ .row = 0, .col = 0 });
    if (at.row > last_row) return self.spotAt(.{ .row = last_row, .col = self.drawn.width });
    const row: u16 = @intCast(at.row);
    var spots: RowSpots = .init(self, row);
    if (spots.boundary == null) return Spot.point(self.lineOf(row));
    var column: i32 = 0;
    var spot: Spot = Spot.point(spots.boundary.?);
    while (spots.next()) |value| : (column += 1) {
        spot = value;
        if (column >= at.col) return spot;
    }
    // Past the row's last cell: after its text.
    return Spot.point(spot.end);
}

/// The logical line and wrapped row drawn at `row`, or null below the text.
fn rowAt(self: *const Self, row: u16) ?viewport.Position {
    const document = self.document;
    const layout: viewport.Layout = .{ .width = self.drawn.width, .method = self.method };
    const text = document.text();
    var reached: i64 = -@as(i64, self.first.row);
    var line: ?usize = if (self.first.offset < text.len) self.first.offset else null;
    while (line) |offset| : (line = document.nextLine(offset)) {
        const start = reached;
        reached += document.lineRows(layout, offset);
        if (row < reached) return .{ .offset = offset, .row = @intCast(row - start) };
    }
    return null;
}

/// Where a row with no body text sits: the start of its logical line (an
/// empty line, or a line whose only text is a margin time), or the text's
/// end below the last line.
fn lineOf(self: *const Self, row: u16) u64 {
    const document = self.document;
    const layout: viewport.Layout = .{ .width = self.drawn.width, .method = self.method };
    const text = document.text();
    var reached: i64 = -@as(i64, self.first.row);
    var line: ?usize = if (self.first.offset < text.len) self.first.offset else null;
    while (line) |offset| : (line = document.nextLine(offset)) {
        reached += document.lineRows(layout, offset);
        if (row < reached) return document.origin + offset;
    }
    return document.origin + text.len;
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    self.size = surface.size;
    self.first = self.document.first(.{ .width = @max(1, self.size.width), .method = self.method }, self.size.height);
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
    self.next = self.document.draw(window, self.first, true, self.colour, self.style).next;
    self.drawn = .{
        .cells = surface.buffer,
        .width = surface.size.width,
        .height = surface.size.height,
        .origin = self.document.origin,
        .base = @intFromPtr(&self.document.bytes),
        .length = self.document.text().len,
    };
    if (self.selection) |*selection| if (selection.dragging and self.drawn.cells.len != 0) {
        // Held at an edge, the selection follows the rows scrolled in.
        switch (selection.edge) {
            .none => {},
            .up => selection.head = self.spotAt(.{ .row = 0, .col = 0 }),
            .down => selection.head = self.spotAt(.{ .row = self.drawn.height - 1, .col = self.drawn.width }),
        }
        const from = selection.from();
        const to = selection.to();
        for (0..self.drawn.height) |row| {
            var spots: RowSpots = .init(self, @intCast(row));
            if (spots.boundary == null) spots.boundary = self.lineOf(@intCast(row));
            for (surface.buffer[row * surface.size.width ..][0..surface.size.width]) |*cell| {
                if (spots.next().?.within(from, to)) cell.style.reverse = true;
            }
        }
    };
    return surface;
}

test "Transcript draws only the requested rows and retains the first unread row" {
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
        const layout: viewport.Layout = .{ .width = self.size.width, .method = self.transcript.method };
        self.transcript.first = if (up) self.document.up(layout, self.transcript.first, 1) else self.document.down(layout, self.transcript.first, 1).min(self.document.bottom(layout, self.size.height));
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

test "a drag held at an edge scrolls one row a tick and selects the rows it brings in" {
    var text: [10 * 7]u8 = undefined;
    for (0..10) |index| _ = std.fmt.bufPrint(text[index * 7 ..][0..7], "line {d}\n", .{index}) catch unreachable;
    const h = try Harness.init(&text, .{ .width = 10, .height = 3 });
    defer h.deinit();
    h.transcript.first = .{ .offset = 4 * 7 };
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
    // Down past the last row, as forwarded from below the widget.
    try h.drag(.{ 0, 1 }, .{ 3, 5 });
    try h.transcript.widget().handleEvent(&h.ctx, .tick);
    _ = try h.frame();
    try h.send(.release, 3, 5);
    try std.testing.expectEqual(@as(i32, -1), h.scrolls);
    try std.testing.expectEqualStrings("line 3\nline 4\nline 5", h.copies(&copied));
}

test "a drag past the clipboard limit copies nothing and says why" {
    const gpa = std.testing.allocator;
    const line = @as([99]u8, @splat('x')) ++ "\n";
    const text = try gpa.alloc(u8, line.len * (TerminalText.clipboard_limit / line.len + 1));
    defer gpa.free(text);
    for (0..text.len / line.len) |index| @memcpy(text[index * line.len ..][0..line.len], line);
    const h = try Harness.init(text, .{ .width = 100, .height = 2 });
    defer h.deinit();
    h.transcript.first = .{};
    _ = try h.frame();
    try h.drag(.{ 0, 0 }, .{ 0, 1 });
    // Held at the bottom edge until every row has been selected.
    h.transcript.selection.?.head = .{ .start = text.len, .end = text.len };
    h.transcript.selection.?.edge = .none;
    try h.send(.release, 0, 1);
    var copied: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", h.copies(&copied));
    try std.testing.expectEqualStrings("Too large for the clipboard · /copy file", h.notices.items[0]);
}
