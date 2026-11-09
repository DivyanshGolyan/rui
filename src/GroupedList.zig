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

rows: []Row = &.{},
selected: ?u32 = null,
caps: overview_view.Caps = .{},
list: vxfw.ListView = .{ .children = .{ .slice = &.{} }, .draw_cursor = false },

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
    if (self.selected) |selected| {
        std.debug.assert(selected < self.rows.len and !self.rows[selected].heading);
    }
    const cursor = self.selected orelse 0;
    const count: u32 = @intCast(self.rows.len);
    const changed = self.list.item_count != count or self.list.cursor != cursor;
    const labels = try ctx.arena.alloc(vxfw.RichText, self.rows.len);
    const children = try ctx.arena.alloc(vxfw.Widget, self.rows.len);
    for (self.rows, labels, children, 0..) |row, *label, *child, index| {
        const selected = self.selected != null and self.selected.? == index;
        const spans = try ctx.arena.alloc(vaxis.Segment, row.segments.len);
        for (row.segments, spans) |segment, *span| {
            var role = segment.style;
            if (selected) role.background = .selection;
            span.* = .{ .text = try ctx.arena.dupe(u8, segment.text), .style = widget_style.of(self.caps, role) };
        }
        label.* = .{
            .text = spans,
            .base_style = widget_style.of(self.caps, .{ .background = if (selected) .selection else .ground }),
            .width_basis = .parent,
            .softwrap = false,
        };
        child.* = label.widget();
    }
    self.list.children = .{ .slice = children };
    defer self.list.children = .{ .slice = &.{} };
    self.list.item_count = count;
    self.list.cursor = cursor;
    if (changed) self.list.ensureScroll();
    var surface = try self.list.draw(ctx);
    surface.widget = self.widget();
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
    var list: Self = .{ .rows = &rows, .selected = 4 };
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
    list.rows = &.{};
    list.selected = null;
    const empty = try list.widget().draw(ctx);
    try std.testing.expectEqual(@as(usize, 0), empty.children.len);
}

test "GroupedList retains frame children when row data refreshes before a mouse event" {
    var text = "Before".*;
    var segments = [_]Segment{.{ .text = &text, .style = .{} }};
    var rows = [_]Row{.{ .segments = &segments }};
    var replacement = [_]Row{.{ .segments = &.{.{ .text = "After", .style = .{} }} }};
    var list: Self = .{ .rows = &rows };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 2 }, .cell_size = .{} };
    const before = try list.widget().draw(ctx);
    list.rows = &replacement;
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
    var list: Self = .{ .rows = &rows, .selected = 0 };
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
