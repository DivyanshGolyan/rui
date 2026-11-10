//! Shared virtual list for Session groups and model choices. The screen's
//! core selects rows and skips headings; ListView owns scrolling only.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Self = @This();
const overview_view = @import("overview_view.zig");
const widget_style = @import("widget_style.zig");

pub const Segment = overview_view.Segment;
pub const Row = struct {
    segments: []const Segment,
    heading: bool = false,
};

/// The list's rows, built one at a time as they come on screen, so a long
/// list costs only what shows.
pub const Rows = struct {
    userdata: *const anyopaque,
    count: u32,
    rowFn: *const fn (userdata: *const anyopaque, index: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!Row,

    pub const none: Rows = .{ .userdata = undefined, .count = 0, .rowFn = undefined };

    /// Rows already built, as `rows` holds them.
    pub fn of(rows: *const []const Row) Rows {
        return .{ .userdata = @ptrCast(rows), .count = @intCast(rows.len), .rowFn = struct {
            fn at(userdata: *const anyopaque, index: usize, _: std.mem.Allocator) std.mem.Allocator.Error!Row {
                const all: *const []const Row = @ptrCast(@alignCast(userdata));
                return all.*[index];
            }
        }.at };
    }
};

/// One row of a frame, built when ListView draws it.
const Lazy = struct {
    list: *const Self,
    index: u32,

    fn widget(self: *const Lazy) vxfw.Widget {
        return .{ .userdata = @constCast(self), .drawFn = drawRow };
    }

    fn drawRow(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const Lazy = @ptrCast(@alignCast(raw));
        const list = self.list;
        const row = try list.rows.rowFn(list.rows.userdata, self.index, ctx.arena);
        const selected = list.selected != null and list.selected.? == self.index;
        std.debug.assert(!(selected and row.heading));
        const spans = try ctx.arena.alloc(vaxis.Segment, row.segments.len);
        for (row.segments, spans) |segment, *span| {
            var role = segment.style;
            if (selected) role.background = .selection;
            span.* = .{ .text = try ctx.arena.dupe(u8, segment.text), .style = widget_style.of(list.caps, role) };
        }
        const label = try ctx.arena.create(vxfw.RichText);
        label.* = .{
            .text = spans,
            .base_style = widget_style.of(list.caps, .{ .background = if (selected) .selection else .ground }),
            .width_basis = .parent,
            .softwrap = false,
        };
        return label.widget().draw(ctx);
    }
};

/// ListView's builder for one draw. Its callback cannot fail, so a failed
/// allocation ends the rows and fails the draw after.
const Building = struct {
    list: *const Self,
    arena: std.mem.Allocator,
    failed: bool = false,

    fn build(raw: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
        const self: *Building = @ptrCast(@alignCast(@constCast(raw)));
        if (self.failed or index >= self.list.rows.count) return null;
        const row = self.arena.create(Lazy) catch {
            self.failed = true;
            return null;
        };
        row.* = .{ .list = self.list, .index = @intCast(index) };
        return row.widget();
    }
};

rows: Rows = .none,
selected: ?u32 = null,
caps: overview_view.Caps = .{},
list: vxfw.ListView = .{ .children = .{ .slice = &.{} }, .draw_cursor = false },
/// The rows the latest draw put on screen, `first` up to `end`.
shown: struct { first: u32 = 0, end: u32 = 0 } = .{},

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    // ListView's j/k, Ctrl-P/N and Esc must never steal composer input.
    if (input == .mouse) try self.list.handleEvent(ctx, input);
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.selected) |selected| std.debug.assert(selected < self.rows.count);
    const cursor = self.selected orelse 0;
    const count = self.rows.count;
    const changed = self.list.item_count != count or self.list.cursor != cursor;
    // ListView asks for the rows it draws, and only those get built.
    var building: Building = .{ .list = self, .arena = ctx.arena };
    self.list.children = .{ .builder = .{ .userdata = &building, .buildFn = Building.build } };
    defer self.list.children = .{ .slice = &.{} };
    self.list.item_count = count;
    self.list.cursor = cursor;
    // A jump past the screen starts drawing at the selected row, so the
    // rows between are never built; a nearer move scrolls as little as it
    // can.
    if (changed) {
        if (cursor > self.list.scroll.top + ctx.max.size().height) self.list.jumpToItem(cursor) else self.list.ensureScroll();
    }
    var surface = try self.list.draw(ctx);
    if (building.failed) return error.OutOfMemory;
    surface.widget = self.widget();
    // ListView's children are its rows from `scroll.top` on, some above or
    // below its edges.
    self.shown = .{};
    for (surface.children, self.list.scroll.top..) |child, at| {
        if (child.origin.row + child.surface.size.height <= 0 or child.origin.row >= surface.size.height) continue;
        if (self.shown.end == 0) self.shown.first = @intCast(at);
        self.shown.end = @intCast(at + 1);
    }
    return surface;
}

test "GroupedList keeps a selected item visible while its keys stay with the composer" {
    var rows = [_]Row{
        .{ .segments = &.{.{ .text = "Needs you", .style = .{ .bold = true } }}, .heading = true },
        .{ .segments = &.{.{ .text = "Approve a tool", .style = .{} }} },
        .{ .segments = &.{.{ .text = "Active", .style = .{ .bold = true } }}, .heading = true },
        .{ .segments = &.{.{ .text = "First task", .style = .{} }} },
        .{ .segments = &.{.{ .text = "Last task", .style = .{} }} },
    };
    const all: []const Row = &rows;
    var list: Self = .{ .rows = .of(&all), .selected = 4 };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 2 }, .cell_size = .{} };
    const surface = try list.widget().draw(ctx);
    var visible = false;
    for (surface.children) |child| {
        if (child.origin.row >= surface.size.height or child.origin.row < 0) continue;
        if (std.mem.eql(u8, child.surface.readCell(0, 0).char.grapheme, "L")) {
            visible = true;
            try std.testing.expectEqualStrings("L", child.surface.readCell(0, 0).char.grapheme);
            try std.testing.expectEqual(widget_style.of(list.caps, .{ .background = .selection }).bg, child.surface.readCell(0, 0).style.bg);
        }
    }
    try std.testing.expect(visible);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]vaxis.Key{
        .{ .codepoint = 'j' },                            .{ .codepoint = 'k' },              .{ .codepoint = 'p', .mods = .{ .ctrl = true } },
        .{ .codepoint = 'n', .mods = .{ .ctrl = true } }, .{ .codepoint = vaxis.Key.escape },
    }) |key| {
        try list.widget().handleEvent(&events, .{ .key_press = key });
        try std.testing.expect(!events.consume_event);
        try std.testing.expectEqual(@as(?u32, 4), list.selected);
    }
    list.selected = 1;
    const first = try list.widget().draw(ctx);
    try std.testing.expect(first.children.len > 0);
    var returned = false;
    for (first.children) |child| {
        if (child.origin.row >= first.size.height or child.origin.row < 0) continue;
        if (std.mem.eql(u8, child.surface.readCell(0, 0).char.grapheme, "N")) try std.testing.expect(!child.surface.readCell(0, 0).style.reverse);
        if (std.mem.eql(u8, child.surface.readCell(0, 0).char.grapheme, "A") and std.mem.eql(u8, child.surface.readCell(1, 0).char.grapheme, "p")) {
            returned = true;
            try std.testing.expectEqualStrings("A", child.surface.readCell(0, 0).char.grapheme);
            try std.testing.expectEqual(widget_style.of(list.caps, .{ .background = .selection }).bg, child.surface.readCell(0, 0).style.bg);
        }
    }
    try std.testing.expect(returned);
    for ([_]vxfw.Size{ .{ .width = 1, .height = 1 }, .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 0 } }) |size| {
        const resized = try list.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height }));
        try std.testing.expect(resized.size.width <= size.width and resized.size.height <= size.height);
        try std.testing.expectEqual(@as(?u32, 1), list.selected);
    }
    const restored = try list.widget().draw(ctx);
    returned = false;
    for (restored.children) |child| {
        if (child.origin.row >= restored.size.height or child.origin.row < 0) continue;
        if (std.mem.eql(u8, child.surface.readCell(0, 0).char.grapheme, "A") and std.mem.eql(u8, child.surface.readCell(1, 0).char.grapheme, "p")) returned = true;
    }
    try std.testing.expect(returned);
    list.rows = .none;
    list.selected = null;
    const empty = try list.widget().draw(ctx);
    try std.testing.expectEqual(@as(usize, 0), empty.children.len);
}

test "GroupedList retains frame children when row data refreshes before a mouse event" {
    var text = "Before".*;
    var segments = [_]Segment{.{ .text = &text, .style = .{} }};
    var rows = [_]Row{.{ .segments = &segments }};
    var replacement = [_]Row{.{ .segments = &.{.{ .text = "After", .style = .{} }} }};
    const before_rows: []const Row = &rows;
    const after_rows: []const Row = &replacement;
    var list: Self = .{ .rows = .of(&before_rows) };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 2 }, .cell_size = .{} };
    const before = try list.widget().draw(ctx);
    list.rows = .of(&after_rows);
    @memset(&text, 'X');
    segments[0] = .{ .text = "Recycled", .style = .{ .colour = .failure } };
    rows[0] = replacement[0];
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try before.children[0].surface.widget.handleEvent(&events, .{ .mouse = .{ .col = 0, .row = 0, .button = .left, .type = .press, .mods = .{} } });
    const retained = try before.children[0].surface.widget.draw(ctx);
    try std.testing.expectEqualStrings("B", retained.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("B", before.children[0].surface.readCell(0, 0).char.grapheme);
    const after = try list.widget().draw(ctx);
    try std.testing.expectEqualStrings("A", after.children[0].surface.readCell(0, 0).char.grapheme);
}

test "GroupedList selection preserves each segment foreground" {
    var rows = [_]Row{.{ .segments = &.{
        .{ .text = "!", .style = .{ .colour = .failure, .bold = true } },
        .{ .text = " task", .style = .{ .colour = .strong } },
    } }};
    const all: []const Row = &rows;
    var list: Self = .{ .rows = .of(&all), .selected = 0 };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 12, .height = 2 }, .cell_size = .{} };
    const surface = try list.widget().draw(ctx);
    const cells = surface.children[0].surface;
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0xff, 0x8f, 0x7d } }, cells.readCell(0, 0).style.fg);
    try std.testing.expect(cells.readCell(0, 0).style.bold);
    try std.testing.expect(!cells.readCell(2, 0).style.bold);
    try std.testing.expect(!std.meta.eql(cells.readCell(0, 0).style.fg, cells.readCell(2, 0).style.fg));
    for ([_]u16{ 0, 2, 11 }) |column| {
        try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0x2b, 0x35, 0x68 } }, cells.readCell(column, 0).style.bg);
    }
    list.caps.depth = .none;
    const plain = try list.widget().draw(ctx);
    for ([_]u16{ 0, 2, 11 }) |column| {
        const cell = plain.children[0].surface.readCell(column, 0);
        try std.testing.expectEqual(vaxis.Color.default, cell.style.fg);
        try std.testing.expectEqual(vaxis.Color.default, cell.style.bg);
        try std.testing.expect(cell.style.reverse);
    }
}

test "GroupedList builds only the rows on screen" {
    const Counted = struct {
        built: usize = 0,

        fn row(userdata: *const anyopaque, index: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!Row {
            const self: *@This() = @ptrCast(@alignCast(@constCast(userdata)));
            self.built += 1;
            return .{ .segments = try arena.dupe(Segment, &.{.{ .text = if (index % 2 == 0) "even" else "odd", .style = .{} }}) };
        }
    };
    var counted: Counted = .{};
    var list: Self = .{ .rows = .{ .userdata = &counted, .count = 10_000, .rowFn = Counted.row }, .selected = 9_000 };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const surface = try list.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 5 }, .cell_size = .{} });
    // Five rows show, around the selected one; ListView may build a row or
    // two past each edge, never the list.
    try std.testing.expect(counted.built <= 10);
    try std.testing.expectEqual(@as(u32, 9_005), list.shown.end);
    try std.testing.expectEqualStrings("e", surface.children[surface.children.len - 1].surface.readCell(0, 0).char.grapheme);
}
