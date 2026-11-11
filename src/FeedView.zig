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

window: *Window,
anchor: *Feed,
tail: ?vxfw.Widget = null,
style: vaxis.Style = .{},
colours: viewport.Colours = .{},
method: vaxis.gwidth.Method = .unicode,
colour: bool = true,
size: vxfw.Size = .{},
handler: ?Handler = null,
selection: ?Selection = null,
drawn: Drawn = .{},

pub const Handler = struct {
    userdata: *anyopaque,
    on_open: ?*const fn (*anyopaque, *vxfw.EventContext, []const u8) anyerror!void = null,
    on_notice: *const fn (*anyopaque, *vxfw.EventContext, []const u8) anyerror!void,
    on_scroll: *const fn (*anyopaque, *vxfw.EventContext, up: bool) anyerror!void,
    on_click: ?*const fn (*anyopaque, *vxfw.EventContext, resident.Point) anyerror!void = null,
};
pub const Openable = union(enum) { message: View.Collapsed, session: [6]u8 };
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

fn layout(self: *const Self) viewport.Layout {
    return .{ .width = @max(1, self.size.width), .method = self.method };
}

pub fn need(self: *Self) Feed.Need {
    return self.anchor.need(self.window.layoutEntries(self.layout()), self.size.height, self.window.edges());
}

pub fn scroll(self: *Self, rows: i32) void {
    self.anchor.scroll(self.window.layoutEntries(self.layout()), self.size.height, rows, self.window.edges());
}

pub fn dragging(self: *const Self) bool {
    return self.selection != null;
}

pub fn messageAt(self: *const Self, point: resident.Point) ?View.Collapsed {
    return self.window.messageAt(point);
}

/// Lowest actually painted mark/link, not an ordinal counted from the end.
/// Looking at source cells also excludes links on hidden wrapped rows.
pub fn openable(self: *Self, gpa: std.mem.Allocator) !?Openable {
    if (self.drawn.width == 0 or self.drawn.height == 0) return null;
    const cells = try gpa.alloc(vaxis.Cell, self.drawn.width);
    defer gpa.free(cells);
    var row: u16 = self.drawn.height;
    while (row > 0) {
        row -= 1;
        const position = self.rowPosition(row) orelse continue;
        self.paintRow(cells, position);
        var column: usize = cells.len;
        while (column > 0) {
            column -= 1;
            const offset = self.window.document.cellOffset(cells[column]) orelse continue;
            if (self.window.document.sessionAt(offset)) |peer| {
                if (peer.len == 6) return .{ .session = peer[0..6].* };
            }
            const mark = self.window.document.collapsed(offset, offset + cells[column].char.grapheme.len).last orelse continue;
            if (self.window.messageAt(self.window.pointAt(mark) orelse continue)) |target| return .{ .message = target };
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
    return .{ .first = index, .line = line, .row = @min(self.drawn.row, self.window.document.lineRows(self.layout(), offset) + gap -| 1), .pad = self.drawn.pad };
}

fn rowPosition(self: *const Self, row: u16) ?viewport.Position {
    return self.window.positionAt(self.laidVisible(), row, self.layout());
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

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (input) {
        .mouse => |value| try self.mouse(ctx, value),
        .mouse_leave => if (self.selection != null) {
            self.selection = null;
            ctx.redraw = true;
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
    switch (value.type) {
        .press => {
            if (value.button != .left) return;
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
    const entries = self.window.layoutEntries(self.layout());
    const visible = self.anchor.visible(entries, self.size.height);
    var screen: vaxis.Screen = .{ .width = self.size.width, .height = self.size.height, .width_method = self.method, .buf = surface.buffer };
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = screen.width, .height = screen.height, .screen = &screen };
    self.window.draw(visible, win, self.colour, self.style, self.colours);
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
            for (0..self.size.height) |row| {
                const position = self.rowPosition(@intCast(row)) orelse continue;
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
