//! Continuous, bottom-aligned feed. Text stays in Window, reading position in
//! Feed; the activity Widget participates in the same layout even offscreen.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const viewport = @import("ConversationViewport.zig");
const resident = @import("feed_window.zig");
const Window = resident.Window;
const Feed = resident.Feed;
const View = @import("session_view.zig");
const selecting = @import("transcript_selection.zig");
const Row = selecting.RowFor(@FieldType(Window, "document"));
const Self = @This();
const Hover = @import("widgets/Hover.zig");

window: *Window,
anchor: *Feed,
tail: ?vxfw.Widget = null,
latest_ending: ?resident.LatestEnding = null,
retry_actionable: bool = false,
style: vaxis.Style = .{},
/// The pointer's tool or Message row, quieter than the selection background an open row keeps.
hover_style: vaxis.Style = .{ .ul_style = .single },
hover: Hover = .{},
colours: viewport.Colours = .{},
method: vaxis.gwidth.Method = .unicode,
colour: bool = true,
size: vxfw.Size = .{},
handler: ?Handler = null,
selection: ?Selection = null,
/// A retry press is not a text selection; a drag cancels it outright.
retry_press: ?struct { cell: Cell, ending: resident.Key } = null,
drawn: Drawn = .{},

pub const Handler = struct {
    userdata: *anyopaque,
    on_open: ?*const fn (*anyopaque, *vxfw.EventContext, []const u8) anyerror!void = null,
    on_notice: *const fn (*anyopaque, *vxfw.EventContext, []const u8) anyerror!void,
    on_scroll: *const fn (*anyopaque, *vxfw.EventContext, up: bool) anyerror!void,
    on_click: ?*const fn (*anyopaque, *vxfw.EventContext, resident.Point) anyerror!void = null,
    on_retry: ?*const fn (*anyopaque, *vxfw.EventContext) anyerror!void = null,
};
pub const Openable = union(enum) { message: View.Collapsed, session: [6]u8, tool: resident.Key };
const Cell = struct { row: i32, col: i32 };
// Both bounds of both clusters are keyed. No saved offset counts from the
// window's start/end; a prepend or removal of another row cannot move them.
const Spot = struct { start: resident.Point, end: resident.Point };
const Selection = struct {
    press: Cell,
    anchor: Spot,
    head: Spot,
    dragging: bool = false,
    edge: enum { none, up, down } = .none,
    ticking: bool = false,
    view: ?resident.Point = null,
    row: u32 = 0,
};
const Drawn = struct {
    first: ?resident.Point = null,
    row: u32 = 0,
    pad: u32 = 0,
    width: u16 = 0,
    height: u16 = 0,
};

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .drawFn = draw, .eventHandler = event };
}

pub fn presentation(self: *const Self) resident.Presentation {
    return .{ .latest_ending = self.latest_ending, .retry_actionable = self.retry_actionable };
}

fn layout(self: *const Self) viewport.Layout {
    return .{ .width = @max(1, self.size.width), .method = self.method };
}

pub fn need(self: *Self) Feed.Need {
    return self.anchor.need(self.window.layoutEntriesWith(self.layout(), self.presentation()), self.size.height, self.window.edges());
}

pub fn scroll(self: *Self, rows: i32) void {
    self.anchor.scroll(self.window.layoutEntriesWith(self.layout(), self.presentation()), self.size.height, rows, self.window.edges());
}

pub fn dragging(self: *const Self) bool {
    return self.selection != null;
}

pub fn messageAt(self: *const Self, point: resident.Point) ?View.Collapsed {
    return self.window.messageAt(point);
}

pub fn toolAt(self: *const Self, point: resident.Point) ?resident.Key {
    return self.window.toolAt(point);
}

/// Lowest actually painted mark/link, not an ordinal counted from the end.
/// Looking at source cells also excludes links on hidden wrapped rows.
pub fn openable(self: *Self, gpa: std.mem.Allocator) !?Openable {
    if (self.drawn.width == 0 or self.drawn.height == 0) return null;
    const cells = try gpa.alloc(vaxis.Cell, self.drawn.width);
    defer gpa.free(cells);
    const positions = try gpa.alloc(?viewport.Position, self.drawn.height);
    defer gpa.free(positions);
    var rows = self.laidRows();
    for (positions) |*position| position.* = rows.next() orelse null;
    var row: u16 = self.drawn.height;
    while (row > 0) {
        row -= 1;
        const position = positions[row] orelse continue;
        if (self.window.document.toolHeading(position.offset)) return .{ .tool = self.window.pointAt(position.offset).?.key };
        self.paintRow(cells, position);
        var column: usize = cells.len;
        while (column > 0) {
            column -= 1;
            const offset = self.window.document.cellOffset(cells[column]) orelse continue;
            if (self.window.document.sessionAt(offset)) |peer| {
                if (peer.len == 6) return .{ .session = peer[0..6].* };
            }
            const mark = self.window.document.collapsed(offset, offset + cells[column].char.grapheme.len).last orelse continue;
            // A final aggregate is a deliberate, unkeyed summary. Do not
            // fall through to an earlier Message when that is the lowest mark.
            const target = self.window.messageAt(self.window.pointAt(mark) orelse continue) orelse return null;
            return .{ .message = target };
        }
    }
    return null;
}

fn resolved(self: *const Self, spot: Spot) ?selecting.Spot {
    return .{ .start = self.window.offsetOf(spot.start) orelse return null, .end = self.window.offsetOf(spot.end) orelse return null };
}

fn keyed(self: *const Self, spot: selecting.Spot) ?Spot {
    return .{ .start = self.window.pointAt(@intCast(spot.start)) orelse return null, .end = self.window.pointAt(@intCast(spot.end)) orelse return null };
}

/// Remap the frame's first line by key after edits, before handling a pointer
/// over that frame. The line can be shortened, but never aliases a new row.
fn laidVisible(self: *const Self) Feed.Visible {
    const first = self.drawn.first orelse return .{ .first = self.window.count };
    if (first.key.order(resident.tail_key) == .eq) return .{ .first = self.window.count, .row = self.drawn.row, .pad = self.drawn.pad };
    const index = self.window.indexOf(first.key) orelse return .{ .first = self.window.count };
    const entry = self.window.entries[index];
    const end = entry.offset + @min(first.offset, entry.length -| 1);
    var offset = entry.offset;
    var line: u32 = 0;
    while (offset < end) {
        const next = self.window.document.lineEnd(offset) + 1;
        if (next > end) break;
        offset = next;
        line += 1;
    }
    const gap = if (self.window.document.lineEnd(offset) + 1 == entry.offset + entry.length) self.window.gapAfter(index) else 0;
    return .{ .first = index, .line = line, .row = @min(self.drawn.row, self.window.lineRows(entry, self.layout(), offset, self.presentation()) + gap -| 1), .pad = self.drawn.pad };
}

fn rowPosition(self: *const Self, row: u16) ?viewport.Position {
    return self.window.positionAtWith(self.laidVisible(), row, self.layout(), self.presentation());
}

/// Every row `rowPosition` answers, in order, laying the frame out once.
fn laidRows(self: *const Self) resident.Window.Rows {
    return self.window.rowsWith(self.laidVisible(), self.layout(), self.presentation());
}

fn paintRow(self: *const Self, cells: []vaxis.Cell, position: viewport.Position) void {
    @memset(cells, .{});
    var screen: vaxis.Screen = .{ .width = @intCast(cells.len), .height = 1, .width_method = self.method, .buf = cells };
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = screen.width, .height = 1, .screen = &screen };
    _ = self.window.document.draw(win, position, true, false, .{}, .{});
}

fn spotAt(self: *const Self, gpa: std.mem.Allocator, at: Cell) !?Spot {
    if (self.drawn.width == 0 or self.drawn.height == 0) return null;
    const last: i32 = self.drawn.height - 1;
    var row: u16 = @intCast(std.math.clamp(at.row, 0, last));
    var col: i32 = if (at.row < 0) 0 else if (at.row > last) self.drawn.width else at.col;
    // A gap/pad/tail is a text boundary, not selectable activity text.
    var position = self.rowPosition(row);
    if (position == null) {
        var next = row;
        while (next < self.drawn.height) : (next += 1) if (self.rowPosition(next)) |found| {
            position = found;
            col = 0;
            break;
        };
        if (position == null) while (row > 0) {
            row -= 1;
            if (self.rowPosition(row)) |found| {
                position = found;
                col = self.drawn.width;
                break;
            }
        };
    }
    const line = position orelse return null;
    const cells = try gpa.alloc(vaxis.Cell, self.drawn.width);
    defer gpa.free(cells);
    self.paintRow(cells, line);
    return self.keyed((Row{ .document = &self.window.document, .cells = cells, .line = line.offset }).spot(col));
}

/// Hit-test only a cell inside the feed pane. No clamping to text boundaries:
/// blank space beside/below an ending must never become its retry link.
fn retryAt(self: *const Self, gpa: std.mem.Allocator, at: Cell) !?resident.RetryHit {
    if (!self.retry_actionable or at.row < 0 or at.col < 0 or at.row >= self.drawn.height or at.col >= self.drawn.width) return null;
    const position = self.rowPosition(@intCast(at.row)) orelse return null;
    const cells = try gpa.alloc(vaxis.Cell, self.drawn.width);
    defer gpa.free(cells);
    return self.window.retryAt(position, cells, @intCast(at.col), self.presentation());
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.hover.handleEvent(ctx, input);
    switch (input) {
        .mouse => |value| try self.mouse(ctx, value),
        .mouse_leave => {
            self.retry_press = null;
            if (self.selection != null) {
                self.selection = null;
                ctx.redraw = true;
            }
        },
        .tick => {
            const held = if (self.selection) |*selection| selection else return;
            if (!held.dragging or held.edge == .none) {
                held.ticking = false;
                return;
            }
            const handler = self.handler orelse return;
            try handler.on_scroll(handler.userdata, ctx, held.edge == .up);
            ctx.redraw = true;
            try ctx.tick(50, self.widget());
        },
        else => {},
    }
}

fn mouse(self: *Self, ctx: *vxfw.EventContext, value: vaxis.Mouse) !void {
    const handler = self.handler orelse return;
    const at: Cell = .{ .row = value.row, .col = value.col };
    if (self.retry_press) |pressed| switch (value.type) {
        .drag => {
            self.retry_press = null;
            ctx.consumeEvent();
            return;
        },
        .release => {
            self.retry_press = null;
            ctx.consumeEvent();
            // X10 releases name no button; custody comes from the left press.
            if ((value.button != .left and value.button != .none) or !std.meta.eql(at, pressed.cell)) return;
            const hit = try self.retryAt(ctx.alloc, at) orelse return;
            if (hit != .link or hit.link.order(pressed.ending) != .eq) return;
            if (handler.on_retry) |retry| try retry(handler.userdata, ctx);
            return;
        },
        .press => self.retry_press = null,
        .motion => {},
    };
    switch (value.type) {
        .press => {
            if (value.button != .left) return;
            if (handler.on_retry != null) if (try self.retryAt(ctx.alloc, at)) |hit| {
                // Synthetic-only wrap padding is not a resident text position.
                // Leave the existing selection path to original body cells.
                if (hit == .link) self.retry_press = .{ .cell = at, .ending = hit.link };
                ctx.consumeEvent();
                return;
            };
            const spot = try self.spotAt(ctx.alloc, at) orelse return;
            self.selection = .{ .press = at, .anchor = spot, .head = spot };
            ctx.consumeEvent();
        },
        .drag => {
            const held = if (self.selection) |*selection| selection else return;
            if (!held.dragging and std.meta.eql(at, held.press)) return;
            held.dragging = true;
            held.head = try self.spotAt(ctx.alloc, at) orelse return;
            held.view = self.drawn.first;
            held.row = self.drawn.row;
            held.edge = if (at.row <= 0) .up else if (at.row >= self.drawn.height - 1) .down else .none;
            if (held.edge != .none and !held.ticking) {
                held.ticking = true;
                try ctx.tick(50, self.widget());
            }
            ctx.consumeAndRedraw();
        },
        .release => {
            const held = self.selection orelse return;
            self.selection = null;
            ctx.consumeAndRedraw();
            const anchor = self.resolved(held.anchor) orelse return;
            const head = self.resolved(held.head) orelse return;
            if (held.dragging) {
                const result = try selecting.copy(ctx.alloc, &self.window.document, .of(anchor, head));
                if (result == .text) try ctx.addCmd(.{ .copy_to_clipboard = result.text.bytes });
                var buffer: [64]u8 = undefined;
                if (selecting.notice(result, &buffer)) |text| try handler.on_notice(handler.userdata, ctx, text);
                return;
            }
            if (!std.meta.eql(at, held.press)) return;
            if (selecting.opens(&self.window.document, anchor)) |peer| {
                if (handler.on_open) |open| try open(handler.userdata, ctx, peer);
                return;
            }
            if (handler.on_click) |click| try click(handler.userdata, ctx, held.anchor.start);
        },
        .motion => {},
    }
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
    self.size = surface.size;
    // Measure with the same full pane regardless of the anchor. A scrolled
    // frame must not remove the tail and change its own scroll geometry.
    const tail = if (self.tail) |child| try child.draw(ctx.withConstraints(.{}, ctx.max)) else null;
    self.window.tail_rows = if (tail) |child| child.size.height else 0;
    const entries = self.window.layoutEntriesWith(self.layout(), self.presentation());
    const visible = self.anchor.visible(entries, self.size.height);
    var screen: vaxis.Screen = .{ .width = self.size.width, .height = self.size.height, .width_method = self.method, .buf = surface.buffer };
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = screen.width, .height = screen.height, .screen = &screen };
    try self.window.drawWith(visible, win, self.colour, self.style, self.colours, self.presentation(), ctx.arena);
    var first: ?resident.Point = null;
    if (visible.first < self.window.count) {
        const entry = self.window.entries[visible.first];
        var offset = entry.offset;
        for (0..visible.line) |_| offset = self.window.document.lineEnd(offset) + 1;
        first = .{ .key = entry.key, .offset = offset - entry.offset };
    } else if (visible.first < entries.len) first = .{ .key = resident.tail_key, .offset = 0 };
    self.drawn = .{ .first = first, .row = visible.row, .pad = visible.pad, .width = self.size.width, .height = self.size.height };
    if (tail) |child| {
        var row: i64 = visible.pad;
        for (entries[@min(visible.first, entries.len)..], @min(visible.first, entries.len)..) |entry, i| {
            if (entry.key.order(resident.tail_key) == .eq) {
                if (i == visible.first) row -= visible.row;
                if (row < self.size.height and row + child.size.height > 0) {
                    surface.children = try ctx.arena.alloc(vxfw.SubSurface, 1);
                    surface.children[0] = .{ .origin = .{ .row = @intCast(row), .col = 0 }, .surface = child };
                }
                break;
            }
            for (entry.lines, 0..) |height, line| {
                if (i == visible.first and line < visible.line) continue;
                row += height;
                if (i == visible.first and line == visible.line) row -= visible.row;
            }
        }
    }
    try self.drawHover(ctx.arena, surface);
    if (self.selection) |*held| {
        const anchor = self.resolved(held.anchor) orelse {
            self.selection = null;
            return surface;
        };
        _ = self.resolved(held.head) orelse {
            self.selection = null;
            return surface;
        };
        if (held.dragging and self.size.width > 0 and self.size.height > 0) {
            if (!std.meta.eql(held.view, first) or held.row != visible.row) switch (held.edge) {
                .none => {},
                .up => if (try self.spotAt(ctx.arena, .{ .row = 0, .col = 0 })) |spot| {
                    held.head = spot;
                },
                .down => if (try self.spotAt(ctx.arena, .{ .row = self.size.height - 1, .col = self.size.width })) |spot| {
                    held.head = spot;
                },
            };
            held.view = first;
            held.row = visible.row;
            const range: selecting.Range = .of(anchor, self.resolved(held.head).?);
            const columns = try ctx.arena.alloc(bool, self.size.width);
            var rows = self.laidRows();
            for (0..self.size.height) |row| {
                const position = (rows.next() orelse break) orelse continue;
                const cells = surface.buffer[row * self.size.width ..][0..self.size.width];
                (Row{ .document = &self.window.document, .cells = cells, .line = position.offset }).covered(range, columns);
                for (cells, columns) |*cell, selected| if (selected) {
                    cell.style.reverse = true;
                };
            }
        }
    }
    return surface;
}

/// Build hover from the same clipped rows and retry decorator as hit testing.
/// Tool rows take the hover look unless open, where the selection background wins;
/// retry chips keep underline.
fn drawHover(self: *Self, arena: std.mem.Allocator, surface: vxfw.Surface) !void {
    self.hover.targets = &.{};
    const handler = self.handler orelse return;
    if (surface.size.width == 0) return;
    var targets: std.ArrayList(Hover.Rect) = .empty;
    const scratch = try arena.alloc(vaxis.Cell, surface.size.width);
    var rows = self.laidRows();
    for (0..surface.size.height) |row| {
        const position = (rows.next() orelse break) orelse continue;
        const point = self.window.pointAt(position.offset);
        const open_row = handler.on_click != null and (self.window.document.toolHeading(position.offset) or (if (point) |p| self.messageAt(p) != null else false));
        const retry = if (handler.on_retry != null) self.window.retryColumns(position, scratch, self.presentation()) else null;
        const cells = surface.buffer[row * surface.size.width ..][0..surface.size.width];
        if (open_row) {
            const rect: Hover.Rect = .{ .row = @intCast(row), .width = surface.size.width };
            try targets.append(arena, rect);
            const open = self.colour and self.window.document.toolIsOpen(position.offset);
            if (!open and self.hover.contains(rect)) for (cells) |*cell| {
                cell.style.bg = self.hover_style.bg;
                cell.style.reverse = self.hover_style.reverse;
                cell.style.ul_style = self.hover_style.ul_style;
            };
        }
        if (retry) |columns| {
            const rect: Hover.Rect = .{ .row = @intCast(row), .col = columns.start, .width = columns.end - columns.start };
            try targets.append(arena, rect);
            if (self.hover.contains(rect)) for (cells[columns.start..columns.end]) |*cell| {
                cell.style.ul_style = .single;
            };
        }
        if (handler.on_open != null) for (try selecting.peers(&self.window.document, cells, arena)) |span| {
            const rect: Hover.Rect = .{ .row = @intCast(row), .col = span.start, .width = span.end - span.start };
            try targets.append(arena, rect);
            if (self.hover.contains(rect)) for (cells[span.start..span.end]) |*cell| {
                cell.style.ul_style = .single;
            };
        };
    }
    self.hover.targets = targets.items;
}

fn testFrame(self: *Self, arena: std.mem.Allocator, width: u16, height: u16) !vxfw.Surface {
    vxfw.DrawContext.init(.unicode);
    return self.widget().draw(.{ .arena = arena, .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} });
}

fn testWindow() !*Window {
    const window = try std.testing.allocator.create(Window);
    window.* = .{};
    window.at_start = true;
    window.at_end = true;
    return window;
}

fn testCell(surface: vxfw.Surface, row: usize, col: usize) []const u8 {
    return surface.buffer[row * surface.size.width + col].char.grapheme;
}

test "FeedView bottom alignment and scroll round trip include the activity tail away from end" {
    const window = try testWindow();
    defer std.testing.allocator.destroy(window);
    try window.append(&.{.{ .key = .{ .position = 10 }, .text = .{ .bytes = "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\na\nb\n" } }});
    var anchor: Feed = .{};
    const tail: vxfw.Text = .{ .text = "work\nqueued" };
    var view: Self = .{ .window = window, .anchor = &anchor, .tail = tail.widget() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const initial = try testFrame(&view, arena.allocator(), 12, 5);
    try std.testing.expectEqualStrings("9", testCell(initial, 0, 0));
    try std.testing.expectEqual(@as(i17, 3), initial.children[0].origin.row);
    try std.testing.expectEqual(@as(u32, 2), window.tail_rows);
    view.scroll(-3);
    const older = try testFrame(&view, arena.allocator(), 12, 5);
    try std.testing.expectEqualStrings("6", testCell(older, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), older.children.len);
    try std.testing.expectEqual(@as(u32, 2), window.tail_rows);
    try std.testing.expectEqual(Feed.Need.none, view.need());
    view.scroll(3);
    const restored = try testFrame(&view, arena.allocator(), 12, 5);
    try std.testing.expect(anchor.following());
    try std.testing.expectEqualDeep(initial.buffer, restored.buffer);
    try std.testing.expectEqual(initial.children[0].origin, restored.children[0].origin);
    try std.testing.expectEqualDeep(initial.children[0].surface.buffer, restored.children[0].surface.buffer);
    // A short feed is aligned against input, tail included.
    window.trim(0, 1);
    try window.append(&.{.{ .key = .{ .position = 20 }, .text = .{ .bytes = "short\n" } }});
    const short = try testFrame(&view, arena.allocator(), 12, 5);
    try std.testing.expectEqualStrings("s", testCell(short, 2, 0));
    try std.testing.expectEqual(@as(i17, 3), short.children[0].origin.row);
}

test "FeedView selection endpoints survive prepends and edits but not eviction" {
    const window = try testWindow();
    defer std.testing.allocator.destroy(window);
    try window.append(&.{.{ .key = .{ .position = 20 }, .text = .{ .bytes = "alpha beta\ngamma delta\n" } }});
    var anchor: Feed = .{};
    var view: Self = .{ .window = window, .anchor = &anchor };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try testFrame(&view, arena.allocator(), 16, 2);
    const start = (try view.spotAt(arena.allocator(), .{ .row = 0, .col = 6 })).?;
    const end = (try view.spotAt(arena.allocator(), .{ .row = 1, .col = 4 })).?;
    view.selection = .{ .press = .{ .row = 0, .col = 6 }, .anchor = start, .head = end, .dragging = true };
    view.scroll(-1);
    try window.prepend(&.{.{ .key = .{ .position = 10 }, .text = .{ .bytes = "older\n" } }});
    const first_copy = try selecting.copy(std.testing.allocator, &window.document, .of(view.resolved(start).?, view.resolved(end).?));
    defer std.testing.allocator.free(first_copy.text.bytes);
    try std.testing.expectEqualStrings("beta\ngamma", first_copy.text.bytes);
    _ = try testFrame(&view, arena.allocator(), 16, 2);
    try std.testing.expect(view.dragging());
    // Replacing a retained entry remaps/clamps each keyed endpoint.
    try window.replace(.{ .position = 20 }, .{ .bytes = "a\n" });
    _ = try testFrame(&view, arena.allocator(), 16, 2);
    try std.testing.expect(view.dragging());
    try std.testing.expectEqual(window.document.length, view.resolved(end).?.end);
    window.trim(0, 1);
    _ = try testFrame(&view, arena.allocator(), 16, 2);
    try std.testing.expect(!view.dragging());
}

test "FeedView multiple collapsed targets and lowest visible peer use keyed byte positions" {
    const window = try testWindow();
    defer std.testing.allocator.destroy(window);
    var prepared: viewport.Sized(1024, true) = .{};
    try prepared.append("first\n" ++ View.Mark.summary ++ "┄ 9 more lines" ++ View.Mark.reset ++ "\nsecond\n" ++ View.Mark.summary ++ "┄ 8 more lines" ++ View.Mark.reset ++ "\n");
    try prepared.prepare();
    const first_mark = prepared.collapsed(0, prepared.text().len).last.?;
    const first = std.mem.indexOf(u8, prepared.text(), "┄").?;
    const a: View.Collapsed = .{ .source = .activity, .position = 11, .ordinal = 0, .content = .{ .length = 0, .digest = @splat(0) }, .row = true };
    var b = a;
    b.position = 12;
    try window.append(&.{.{ .key = .{ .position = 20 }, .text = resident.Text.fromDocument(&prepared), .messages = &.{ .{ .offset = first, .target = a }, .{ .offset = first_mark, .target = b } } }});
    var anchor: Feed = .{};
    var view: Self = .{ .window = window, .anchor = &anchor };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try testFrame(&view, arena.allocator(), 30, 4);
    try std.testing.expectEqual(@as(u64, 12), (try view.openable(arena.allocator())).?.message.position);
    try std.testing.expectEqual(@as(u64, 11), view.messageAt(.{ .key = .{ .position = 20 }, .offset = first }).?.position);
    try std.testing.expect(view.messageAt(.{ .key = .{ .position = 20 }, .offset = 0 }) == null);
    // Trimming/reloading the same key cannot leave a stale Message target.
    window.trim(1, 0);
    try window.append(&.{.{ .key = .{ .position = 20 }, .text = resident.Text.fromDocument(&prepared), .messages = &.{.{ .offset = first, .target = b }} }});
    try std.testing.expectEqual(@as(u64, 12), view.messageAt(.{ .key = .{ .position = 20 }, .offset = first }).?.position);
    try std.testing.expect(view.messageAt(.{ .key = .{ .position = 20 }, .offset = first_mark }) == null);
    const TerminalText = @import("TerminalText.zig");
    try prepared.append("peer " ++ TerminalText.link_open ++ TerminalText.session_link ++ "k7m2qx" ++ TerminalText.link_end ++ "Plan" ++ TerminalText.link_close ++ "\n");
    try prepared.prepare();
    window.trim(1, 0);
    try window.append(&.{.{ .key = .{ .position = 30 }, .text = resident.Text.fromDocument(&prepared), .messages = &.{.{ .offset = first, .target = a }} }});
    _ = try testFrame(&view, arena.allocator(), 30, 4);
    try std.testing.expectEqualStrings("k7m2qx", &(try view.openable(arena.allocator())).?.session);
}

test "FeedView retry tail is frame-local, latest-key-only and gated by cause and actionability at every width" {
    const window = try testWindow();
    defer std.testing.allocator.destroy(window);
    const words = "× Provider unreachable\n";
    try window.append(&.{
        .{ .key = .{ .position = 10 }, .text = .{ .bytes = words } },
        .{ .key = .{ .position = 20 }, .text = .{ .bytes = words } },
        .{ .key = .{ .position = 20, .ordinal = 1 }, .text = .{ .bytes = words } },
    });
    var anchor: Feed = .{};
    var view: Self = .{ .window = window, .anchor = &anchor };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const original = try std.testing.allocator.dupe(u8, window.document.text());
    defer std.testing.allocator.free(original);
    const marks = @import("marks.zig");
    // All cause policies are covered by marks' independent exhaustive domain;
    // cross keyed/unkeyed, every entry identity (including ordinal) and bool.
    for ([_]?resident.LatestEnding{
        null,
        .{ .key = .{ .position = 10 }, .cause = marks.cause("provider_http_500") },
        .{ .key = .{ .position = 20 }, .cause = marks.cause("provider_http_500") },
        .{ .key = .{ .position = 20, .ordinal = 1 }, .cause = marks.cause("provider_http_500") },
        .{ .key = .{ .position = 30 }, .cause = marks.cause("provider_http_500") },
        .{ .key = .{ .position = 20 }, .cause = marks.cause("provider_quota") },
    }) |latest| for ([_]bool{ false, true }) |actionable| {
        view.latest_ending = latest;
        view.retry_actionable = actionable;
        for (1..141) |width| {
            const surface = try testFrame(&view, arena.allocator(), @intCast(width), 180);
            // Compare each stored entry against an independently prepared line.
            // The explicit expectation doesn't call the production decorator.
            for (window.entries[0..window.count], 0..) |entry, index| {
                const expected_hint = actionable and latest != null and latest.?.cause.key != null and std.meta.eql(entry.key, latest.?.key);
                var expected: viewport.Sized(128, true) = .{};
                try expected.append(if (expected_hint) "× Provider unreachable · ctrl+r retries\n" else words);
                try expected.prepare();
                const rows = expected.lineRows(.{ .width = @intCast(width), .method = .unicode }, 0);
                try std.testing.expectEqual(@as(u32, rows) + window.gapAfter(index), window.dimensions[index].lines[0]);
                var top: u32 = anchor.visible(window.dimensions[0..window.count], 180).pad;
                for (window.dimensions[0..index]) |before| for (before.lines) |height| {
                    top += height;
                };
                const cells = try arena.allocator().alloc(vaxis.Cell, rows * width);
                @memset(cells, .{});
                var screen: vaxis.Screen = .{ .width = @intCast(width), .height = rows, .width_method = .unicode, .buf = cells };
                const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = screen.width, .height = rows, .screen = &screen };
                _ = expected.printLine(win, 0, 0, true, false, .{}, .{});
                const drawn = surface.buffer[top * width ..][0 .. rows * width];
                for (cells, drawn) |want, got| try std.testing.expectEqualStrings(want.char.grapheme, got.char.grapheme);
            }
            try std.testing.expectEqualStrings(original, window.document.text());
            // Bound test scratch independently of the exhaustive width domain.
            _ = arena.reset(.retain_capacity);
        }
    };
}

const RetryClicks = struct {
    count: usize = 0,
    fn retry(raw: *anyopaque, _: *vxfw.EventContext) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.count += 1;
    }
    fn notice(_: *anyopaque, _: *vxfw.EventContext, _: []const u8) !void {}
    fn scroll(_: *anyopaque, _: *vxfw.EventContext, _: bool) !void {
        return error.UnexpectedRetryScroll;
    }
    fn handler(self: *@This()) Handler {
        return .{ .userdata = self, .on_retry = retry, .on_notice = notice, .on_scroll = @This().scroll };
    }
};

fn retryMouse(view: *Self, ctx: *vxfw.EventContext, at: Cell, kind: vaxis.Mouse.Type) !void {
    try view.widget().handleEvent(ctx, .{ .mouse = .{ .col = @intCast(at.col), .row = @intCast(at.row), .button = .left, .mods = .{}, .type = kind } });
}

test "FeedView retry click hits only painted suffix cells including wrapped tails at every width" {
    const gpa = std.testing.allocator;
    const window = try testWindow();
    defer gpa.destroy(window);
    const words = "× Model reply unreadable\n";
    // A lookalike in retained text must not become a link.
    const older = "ctrl+r retries elsewhere\n";
    try window.append(&.{
        .{ .key = .{ .position = 10 }, .text = .{ .bytes = older }, .tight = true },
        .{ .key = .{ .position = 20 }, .text = .{ .bytes = words }, .tight = true },
    });
    var anchor: Feed = .{};
    var clicks: RetryClicks = .{};
    var view: Self = .{ .window = window, .anchor = &anchor, .handler = clicks.handler(), .retry_actionable = true, .latest_ending = .{ .key = .{ .position = 20 }, .cause = @import("marks.zig").cause("malformed_provider_output") } };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = gpa, .cmds = .empty };
    defer ctx.cmds.deinit(gpa);
    // Independent literal and Document layout, not the production decorator or
    // hit-query: every body, separator, indent, margin and link cell is checked.
    const shown = older ++ "× Model reply unreadable · ctrl+r retries\n";
    const start = std.mem.lastIndexOf(u8, shown, "ctrl+r retries").?;
    var expected: viewport.Sized(256, true) = .{ .sidenotes = true, .quotes = true };
    try expected.append(shown);
    try expected.prepare();
    for (1..141) |width| {
        const surface = try testFrame(&view, arena.allocator(), @intCast(width), 180);
        const height = expected.measure(.{ .width = @intCast(width), .method = .unicode }, .{}, 180).rows;
        const cells = try gpa.alloc(vaxis.Cell, width * height);
        defer gpa.free(cells);
        @memset(cells, .{});
        var screen: vaxis.Screen = .{ .width = @intCast(width), .height = @intCast(height), .width_method = .unicode, .buf = cells };
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = screen.width, .height = screen.height, .screen = &screen };
        _ = expected.draw(win, .{}, true, false, .{}, .{});
        const pad = 180 - height;
        for (cells, 0..) |cell, index| {
            const row = index / width;
            const col = index % width;
            try std.testing.expectEqualStrings(cell.char.grapheme, testCell(surface, pad + row, col));
            const offset = expected.cellOffset(cell);
            const link = if (offset) |at| at >= start and at < start + "ctrl+r retries".len else false;
            const before = clicks.count;
            const at: Cell = .{ .row = @intCast(pad + row), .col = @intCast(col) };
            try retryMouse(&view, &ctx, at, .press);
            try std.testing.expectEqual(before, clicks.count);
            try retryMouse(&view, &ctx, at, .release);
            try std.testing.expectEqual(before + @intFromBool(link), clicks.count);
            try std.testing.expect(view.selection == null and view.retry_press == null);
        }
        try std.testing.expect(anchor.following());
        try std.testing.expectEqualStrings(older ++ words, window.document.text());
        _ = arena.reset(.retain_capacity);
    }
}

test "FeedView retry click cancels drag departure and lost eligibility or ending identity" {
    const gpa = std.testing.allocator;
    const window = try testWindow();
    defer gpa.destroy(window);
    try window.append(&.{.{ .key = .{ .position = 20 }, .text = .{ .bytes = "× Model reply unreadable\n" } }});
    var anchor: Feed = .{};
    var clicks: RetryClicks = .{};
    const latest: resident.LatestEnding = .{ .key = .{ .position = 20 }, .cause = @import("marks.zig").cause("malformed_provider_output") };
    var view: Self = .{ .window = window, .anchor = &anchor, .handler = clicks.handler(), .retry_actionable = true, .latest_ending = latest };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = gpa, .cmds = .empty };
    defer ctx.cmds.deinit(gpa);
    _ = try testFrame(&view, arena.allocator(), 80, 4);
    // Literal line: 24 ending columns, 3 separator columns, then the key.
    const at: Cell = .{ .row = 3, .col = 27 };
    const Cases = enum { drag_same, drag_away_back, release_elsewhere, leave, held, unkeyed, other_ending, hidden_press, disabled, no_press };
    for (std.enums.values(Cases)) |case| {
        view.retry_actionable = case != .disabled;
        view.latest_ending = latest;
        _ = try testFrame(&view, arena.allocator(), 80, 4);
        if (case == .hidden_press) view.retry_actionable = false;
        if (case != .no_press) try retryMouse(&view, &ctx, at, .press);
        switch (case) {
            .drag_same => try retryMouse(&view, &ctx, at, .drag),
            .drag_away_back => {
                try retryMouse(&view, &ctx, .{ .row = 3, .col = 0 }, .drag);
                try retryMouse(&view, &ctx, at, .drag);
            },
            .leave => try view.widget().handleEvent(&ctx, .mouse_leave),
            .held => view.retry_actionable = false,
            .unkeyed => view.latest_ending.?.cause = @import("marks.zig").cause("provider_quota"),
            .other_ending => view.latest_ending.?.key.ordinal += 1,
            .release_elsewhere, .hidden_press, .disabled, .no_press => {},
        }
        if (case == .hidden_press) view.retry_actionable = true;
        try retryMouse(&view, &ctx, if (case == .release_elsewhere) .{ .row = 3, .col = 0 } else at, .release);
        try std.testing.expectEqual(@as(usize, 0), clicks.count);
        try std.testing.expect(view.retry_press == null and view.selection == null);
    }
}

test "FeedView retry click accepts left and legacy no-button release only" {
    const gpa = std.testing.allocator;
    const window = try testWindow();
    defer gpa.destroy(window);
    try window.append(&.{.{ .key = .{ .position = 20 }, .text = .{ .bytes = "× Model reply unreadable\n" } }});
    var anchor: Feed = .{};
    var clicks: RetryClicks = .{};
    var view: Self = .{ .window = window, .anchor = &anchor, .handler = clicks.handler(), .retry_actionable = true, .latest_ending = .{ .key = .{ .position = 20 }, .cause = @import("marks.zig").cause("malformed_provider_output") } };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = gpa, .cmds = .empty };
    defer ctx.cmds.deinit(gpa);
    _ = try testFrame(&view, arena.allocator(), 80, 4);
    for (std.enums.values(vaxis.Mouse.Button)) |button| {
        clicks.count = 0;
        try retryMouse(&view, &ctx, .{ .row = 3, .col = 27 }, .press);
        try view.widget().handleEvent(&ctx, .{ .mouse = .{ .row = 3, .col = 27, .button = button, .mods = .{}, .type = .release } });
        try std.testing.expectEqual(@as(usize, @intFromBool(button == .left or button == .none)), clicks.count);
        try std.testing.expect(view.retry_press == null);
    }
}

test "FeedView terminal aggregate blocks Ctrl-O and clicks without opening earlier Messages" {
    const window = try testWindow();
    defer std.testing.allocator.destroy(window);
    var prepared: viewport.Sized(1024, true) = .{};
    try prepared.append(View.Mark.summary ++ "┄ 9 more lines" ++ View.Mark.reset ++ "\n" ++ View.Mark.summary ++ "┄ 4 more summaries" ++ View.Mark.reset ++ "\n");
    try prepared.prepare();
    const aggregate = prepared.collapsed(0, prepared.length).last.?;
    const target: View.Collapsed = .{ .source = .activity, .position = 44, .ordinal = 3, .content = .{ .length = 10, .digest = @splat(2) }, .row = false };
    try window.append(&.{.{ .key = .{ .position = 50 }, .text = resident.Text.fromDocument(&prepared), .messages = &.{.{ .offset = 0, .target = target }} }});
    var anchor: Feed = .{};
    var view: Self = .{ .window = window, .anchor = &anchor };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try testFrame(&view, arena.allocator(), 30, 2);
    try std.testing.expect((try view.openable(arena.allocator())) == null);
    try std.testing.expect(view.messageAt(.{ .key = .{ .position = 50 }, .offset = aggregate }) == null);
    try std.testing.expectEqualDeep(target, view.messageAt(.{ .key = .{ .position = 50 }, .offset = 0 }).?);
    // The same rule holds if only the aggregate fits in the painted frame.
    _ = try testFrame(&view, arena.allocator(), 30, 1);
    try std.testing.expect((try view.openable(arena.allocator())) == null);
    window.trim(1, 0);
    try window.append(&.{.{ .key = .{ .position = 50 }, .text = resident.Text.fromDocument(&prepared), .messages = &.{.{ .offset = 0, .target = target }} }});
    _ = try testFrame(&view, arena.allocator(), 30, 2);
    try std.testing.expect((try view.openable(arena.allocator())) == null);
    try std.testing.expect(view.messageAt(.{ .key = .{ .position = 50 }, .offset = aggregate }) == null);
}

test "FeedView tool rows and retry chips hover only their painted targets without selecting" {
    const Actions = struct {
        tools: usize = 0,
        retries: usize = 0,
        fn tool(raw: *anyopaque, _: *vxfw.EventContext, _: resident.Point) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tools += 1;
        }
        fn retry(raw: *anyopaque, _: *vxfw.EventContext) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.retries += 1;
        }
    };
    const window = try testWindow();
    defer std.testing.allocator.destroy(window);
    var heading: viewport.Sized(256, true) = .{};
    try heading.append(@import("tool_fold.zig").heading_marker ++ "$ Bash done\n");
    try heading.prepare();
    try window.append(&.{
        .{ .key = .{ .position = 10 }, .text = resident.Text.fromDocument(&heading), .tight = true },
        .{ .key = .{ .position = 20 }, .text = .{ .bytes = "× Model reply unreadable\n" }, .tight = true },
    });
    var anchor: Feed = .{};
    var actions: Actions = .{};
    var view: Self = .{
        .window = window,
        .anchor = &anchor,
        .handler = .{ .userdata = &actions, .on_click = Actions.tool, .on_retry = Actions.retry, .on_notice = RetryClicks.notice, .on_scroll = RetryClicks.scroll },
        .retry_actionable = true,
        .latest_ending = .{ .key = .{ .position = 20 }, .cause = @import("marks.zig").cause("malformed_provider_output") },
        .hover_style = .{ .bg = .{ .index = 2 } },
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]u16{ 16, 80 }) |width| {
        const initial = try testFrame(&view, arena.allocator(), width, 8);
        try std.testing.expect(view.hover.targets.len >= 2);
        const tool = view.hover.targets[0];
        const retry = view.hover.targets[view.hover.targets.len - 1];
        const before_tools = actions.tools;
        const before_retries = actions.retries;
        for ([_]struct { rect: Hover.Rect, tool: bool }{ .{ .rect = tool, .tool = true }, .{ .rect = retry, .tool = false } }) |case| {
            try view.widget().handleEvent(&ctx, .mouse_enter);
            const motion: vaxis.Mouse = .{ .row = @intCast(case.rect.row), .col = @intCast(case.rect.col), .button = .none, .mods = .{}, .type = .motion };
            try view.widget().handleEvent(&ctx, .{ .mouse = motion });
            const hovered = try testFrame(&view, arena.allocator(), width, 8);
            const cell = hovered.readCell(@intCast(case.rect.col), @intCast(case.rect.row));
            const original = initial.readCell(@intCast(case.rect.col), @intCast(case.rect.row));
            if (case.tool) {
                try std.testing.expectEqual(view.hover_style.bg, cell.style.bg);
                try std.testing.expectEqual(original.style.fg, cell.style.fg);
            } else try std.testing.expectEqual(.single, cell.style.ul_style);
            try std.testing.expect(view.selection == null);
            try std.testing.expectEqual(before_tools, actions.tools);
            try std.testing.expectEqual(before_retries, actions.retries);
            try std.testing.expectEqual(vaxis.Mouse.Shape.pointer, ctx.cmds.items[ctx.cmds.items.len - 1].set_mouse_shape);
            try view.widget().handleEvent(&ctx, .mouse_leave);
            const left = try testFrame(&view, arena.allocator(), width, 8);
            try std.testing.expectEqual(original.style, left.readCell(@intCast(case.rect.col), @intCast(case.rect.row)).style);
        }
        try retryMouse(&view, &ctx, .{ .row = tool.row, .col = tool.col }, .press);
        try retryMouse(&view, &ctx, .{ .row = tool.row, .col = tool.col }, .release);
        try std.testing.expectEqual(before_tools + 1, actions.tools);
        try retryMouse(&view, &ctx, .{ .row = retry.row, .col = retry.col }, .press);
        try retryMouse(&view, &ctx, .{ .row = retry.row, .col = retry.col }, .release);
        try std.testing.expectEqual(before_retries + 1, actions.retries);
        view.retry_actionable = false;
        _ = try testFrame(&view, arena.allocator(), width, 8);
        for (view.hover.targets) |target| try std.testing.expectEqual(@as(u16, 0), @as(u16, @intCast(target.col)));
        view.retry_actionable = true;
    }
}

test "FeedView open tool heading keeps its selection background under the pointer" {
    const Actions = struct {
        fn tool(_: *anyopaque, _: *vxfw.EventContext, _: resident.Point) !void {}
    };
    const window = try testWindow();
    defer std.testing.allocator.destroy(window);
    const fold = @import("tool_fold.zig");
    var tools: viewport.Sized(256, true) = .{};
    try tools.append(fold.heading_marker ++ "$ Bash open\n" ++ fold.output_marker ++ "out\n" ++ fold.heading_marker ++ "$ Bash shut\n");
    try tools.prepare();
    try window.append(&.{.{ .key = .{ .position = 10 }, .text = resident.Text.fromDocument(&tools), .tight = true }});
    var anchor: Feed = .{};
    var unused: u8 = 0;
    var view: Self = .{
        .window = window,
        .anchor = &anchor,
        .handler = .{ .userdata = &unused, .on_click = Actions.tool, .on_notice = RetryClicks.notice, .on_scroll = RetryClicks.scroll },
        .colours = .{ .selection = .{ .index = 9 } },
        .hover_style = .{ .bg = .{ .index = 2 } },
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const initial = try testFrame(&view, arena.allocator(), 40, 3);
    try std.testing.expectEqual(vaxis.Color{ .index = 9 }, initial.readCell(0, 0).style.bg);
    try view.widget().handleEvent(&ctx, .mouse_enter);
    for ([_]struct { row: u16, bg: vaxis.Color }{ .{ .row = 0, .bg = .{ .index = 9 } }, .{ .row = 2, .bg = .{ .index = 2 } } }) |case| {
        try view.widget().handleEvent(&ctx, .{ .mouse = .{ .row = @intCast(case.row), .col = 1, .button = .none, .mods = .{}, .type = .motion } });
        const hovered = try testFrame(&view, arena.allocator(), 40, 3);
        for (0..40) |col| try std.testing.expectEqual(case.bg, hovered.readCell(@intCast(col), case.row).style.bg);
        try std.testing.expectEqual(vaxis.Color{ .index = 9 }, hovered.readCell(0, 0).style.bg);
    }
}

test "FeedView Message summaries and wrapped peer links hover without making aggregate or prose actionable" {
    const Actions = struct {
        messages: usize = 0,
        opened: usize = 0,
        fn click(raw: *anyopaque, _: *vxfw.EventContext, _: resident.Point) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.messages += 1;
        }
        fn open(raw: *anyopaque, _: *vxfw.EventContext, id: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqualStrings("k7m2qx", id);
            self.opened += 1;
        }
    };
    const window = try testWindow();
    defer std.testing.allocator.destroy(window);
    const Text = @import("TerminalText.zig");
    var prepared: viewport.Sized(1024, true) = .{};
    try prepared.append(View.Mark.summary ++ "┄ 9 more lines" ++ View.Mark.reset ++ "\n" ++ View.Mark.summary ++ "┄ 4 more summaries" ++ View.Mark.reset ++ "\nplain " ++ Text.link_open ++ Text.session_link ++ "k7m2qx" ++ Text.link_end ++ "Review this plan" ++ Text.link_close ++ " end\n");
    try prepared.prepare();
    const message: View.Collapsed = .{ .source = .activity, .position = 44, .ordinal = 3, .content = .{ .length = 10, .digest = @splat(2) }, .row = false };
    try window.append(&.{.{ .key = .{ .position = 50 }, .text = resident.Text.fromDocument(&prepared), .messages = &.{.{ .offset = 0, .target = message }} }});
    var anchor: Feed = .{};
    var actions: Actions = .{};
    var view: Self = .{ .window = window, .anchor = &anchor, .handler = .{ .userdata = &actions, .on_click = Actions.click, .on_open = Actions.open, .on_notice = RetryClicks.notice, .on_scroll = RetryClicks.scroll }, .hover_style = .{ .bg = .{ .index = 2 } } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]u16{ 14, 80 }) |width| {
        _ = try testFrame(&view, arena.allocator(), width, 12);
        var links: usize = 0;
        var summaries: usize = 0;
        for (view.hover.targets) |rect| {
            const position = view.rowPosition(@intCast(rect.row)).?;
            const is_summary = prepared.collapsed(0, prepared.lineEnd(0)).last != null and position.offset == 0;
            if (is_summary) {
                summaries += 1;
            } else {
                links += 1;
                try std.testing.expect(rect.width > 1);
            }
            try view.widget().handleEvent(&ctx, .mouse_enter);
            try view.widget().handleEvent(&ctx, .{ .mouse = .{ .row = @intCast(rect.row), .col = @intCast(rect.col), .button = .none, .mods = .{}, .type = .motion } });
            const hovered = try testFrame(&view, arena.allocator(), width, 12);
            if (is_summary) {
                try std.testing.expectEqual(view.hover_style.bg, hovered.readCell(0, @intCast(rect.row)).style.bg);
            } else for (@as(usize, @intCast(rect.col))..@as(usize, @intCast(rect.col)) + rect.width) |col| try std.testing.expectEqual(.single, hovered.readCell(col, @intCast(rect.row)).style.ul_style);
            try std.testing.expect(view.selection == null and actions.messages == 0 and actions.opened == 0);
            try view.widget().handleEvent(&ctx, .mouse_leave);
        }
        try std.testing.expect(summaries > 0 and links > 0);
        if (width == 14) try std.testing.expect(links > 1);
    }
}

test "FeedView hover and drag highlight measure each visible line a bounded number of times" {
    const Actions = struct {
        fn click(_: *anyopaque, _: *vxfw.EventContext, _: resident.Point) !void {}
        fn open(_: *anyopaque, _: *vxfw.EventContext, _: []const u8) !void {}
    };
    var unused: u8 = 0;
    var measured: [2]usize = undefined;
    const heights = [_]u16{ 64, 2048 };
    for (heights, &measured) |height, *count| {
        const window = try testWindow();
        defer std.testing.allocator.destroy(window);
        const text = try std.testing.allocator.alloc(u8, 2 * @as(usize, height));
        defer std.testing.allocator.free(text);
        for (0..height) |line| @memcpy(text[2 * line ..][0..2], "x\n");
        try window.append(&.{.{ .key = .{ .position = 10 }, .text = .{ .bytes = text } }});
        var anchor: Feed = .{};
        var view: Self = .{ .window = window, .anchor = &anchor, .handler = .{ .userdata = &unused, .on_click = Actions.click, .on_open = Actions.open, .on_retry = RetryClicks.retry, .on_notice = RetryClicks.notice, .on_scroll = RetryClicks.scroll } };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        _ = try testFrame(&view, arena.allocator(), 8, height);
        const start = (try view.spotAt(arena.allocator(), .{ .row = 0, .col = 0 })).?;
        view.selection = .{ .press = .{ .row = 0, .col = 0 }, .anchor = start, .head = start, .dragging = true };
        viewport.measured_lines = 0;
        const frame = try testFrame(&view, arena.allocator(), 8, height);
        try std.testing.expect(frame.buffer[0].style.reverse);
        count.* = viewport.measured_lines;
    }
    // Every line is one row, so a linear frame costs at most 32 times as
    // much for 32 times the rows; the quadratic walk cost about 1000 times.
    try std.testing.expect(measured[1] <= 32 * measured[0]);
}
