const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const commands = @import("slash_commands.zig");
const slash_menu = @import("slash_menu.zig");
const overview = @import("overview_view.zig");
const Self = @This();
const Hover = @import("widgets/Hover.zig");
const widget_style = @import("widget_style.zig");

menu: *slash_menu.Menu,
caps: overview.Caps = .{ .width = .unicode },
style: vaxis.Style = .{},
quiet: vaxis.Style = .{ .dim = true },
matched: vaxis.Style = .{ .bold = true },
max_height: u16 = std.math.maxInt(u16),
hover_style: vaxis.Style = .{ .ul_style = .single },
userdata: ?*anyopaque = null,
on_select: ?*const fn (*anyopaque, *vxfw.EventContext, commands.Shown.Pick) anyerror!void = null,
hover: Hover = .{},
first: usize = 0,

/// Resolve the list's styles through the same screen roles as its surface.
pub fn setCaps(self: *Self, caps: overview.Caps) void {
    self.caps = caps;
    self.style = widget_style.of(caps, .{ .background = .input_surface });
    self.quiet = widget_style.of(caps, .{ .colour = .quiet, .background = .input_surface });
    self.matched = widget_style.of(caps, .{ .bold = true, .background = .input_surface });
    self.hover_style = widget_style.of(caps, .{ .background = .hover });
}

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.hover.handleEvent(ctx, input);
    if (input != .mouse) return;
    ctx.consumeEvent();
    const shown = if (self.menu.shown) |*shown| shown else return;
    if (shown.seen != .drawn) return;
    switch (input.mouse.button) {
        .left => if (input.mouse.type == .press) {
            const callback = self.on_select orelse return;
            for (self.hover.targets, 0..) |rect, index| {
                if (rect.contains(input.mouse.col, input.mouse.row)) {
                    var pressed = self.menu.drawn_pick orelse return;
                    pressed.index = self.first + index;
                    return callback(self.userdata.?, ctx, pressed);
                }
            }
        },
        .wheel_up, .wheel_down => {
            shown.move(input.mouse.button == .wheel_down);
            ctx.redraw = true;
        },
        else => {},
    }
}

const Layout = struct {
    panel: Hover.Rect,
    content: Hover.Rect,

    fn of(width: u16, height: u16, rows: usize) ?Layout {
        if (width <= 2 or height == 0 or rows == 0) return null;
        const border: u16 = if (width >= 7 and height >= 3) 1 else 0;
        const body: u16 = @intCast(@min(rows, height - 2 * border));
        return .{
            .panel = .{ .row = 0, .width = width, .height = body + 2 * border },
            .content = .{ .row = border, .col = 2 * border, .width = width - 4 * border, .height = body },
        };
    }

    fn bordered(self: Layout) bool {
        return self.content.row != self.panel.row;
    }

    fn row(self: Layout, index: usize) Hover.Rect {
        return .{ .row = self.content.row + @as(i17, @intCast(index)), .col = self.content.col, .width = self.content.width };
    }
};

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.hover.targets = &.{};
    const shown = &self.menu.shown.?;
    const layout = Layout.of(ctx.max.width.?, @min(self.max_height, ctx.max.height.?), shown.rows());
    self.menu.drew(layout != null, shown.pick(shown.highlight));
    const placed = layout orelse return .empty(self.widget());
    const width = placed.panel.width;
    const height = placed.panel.height;
    const surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), .{ .width = width, .height = height });
    @memset(surface.buffer, .{ .style = self.style });
    var screen: vaxis.Screen = .{ .width = width, .height = height, .width_method = self.caps.width, .buf = surface.buffer };
    const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen };
    if (placed.bordered()) {
        const glyphs: [6][]const u8 = if (self.caps.unicode) .{ "┌", "┐", "└", "┘", "─", "│" } else .{ "+", "+", "+", "+", "-", "|" };
        for (0..height) |row| for (0..width) |col| {
            const glyph = if (row == 0)
                (if (col == 0) glyphs[0] else if (col == width - 1) glyphs[1] else glyphs[4])
            else if (row == height - 1)
                (if (col == 0) glyphs[2] else if (col == width - 1) glyphs[3] else glyphs[4])
            else if (col == 0 or col == width - 1)
                glyphs[5]
            else
                continue;
            surface.writeCell(@intCast(col), @intCast(row), .{ .char = .{ .grapheme = glyph, .width = 1 }, .style = self.quiet });
        };
    }
    const body = window.child(.{ .x_off = @intCast(placed.content.col), .y_off = @intCast(placed.content.row), .width = placed.content.width, .height = placed.content.height });
    const list = &shown.list;
    const count = commands.named(list.count, placed.content.height);
    const first = list.firstShown(shown.highlight, placed.content.height);
    self.first = first;
    const targets = try ctx.arena.alloc(Hover.Rect, if (self.on_select != null) count else 0);
    for (targets, 0..) |*rect, index| rect.* = placed.row(index);
    self.hover.targets = targets;
    const column = list.descriptionColumn();
    const selected_style = widget_style.of(self.caps, .{ .background = .selection });
    const selected_matched = widget_style.of(self.caps, .{ .bold = true, .background = .selection });
    for (list.shown()[first..][0..count], first..) |entry, index| {
        const selected = index == shown.highlight;
        var style = if (selected) selected_style else self.style;
        const rect = placed.row(index - first);
        const hovered = !selected and self.on_select != null and self.hover.contains(rect);
        if (hovered) style = Hover.look(style, self.hover_style);
        const start = @as(usize, @intCast(rect.row)) * width + @as(usize, @intCast(rect.col));
        if (selected or hovered) @memset(surface.buffer[start..][0..rect.width], .{ .style = style });
        const line = body.child(.{ .y_off = @intCast(index - first), .height = 1 });
        var matched = if (selected) selected_matched else self.matched;
        if (hovered) matched = Hover.look(matched, self.hover_style);
        printMarked(line, entry.shown, entry.matches.name, style, matched);
        if (column < rect.width) {
            const source_span: ?overview.ByteSpan = if (entry.matches.description) |mark| .{ .start = mark.start, .len = mark.len } else null;
            const fitted = try overview.fittedMarked(ctx.arena, self.caps, entry.description, rect.width - column, .head, source_span);
            const span: ?commands.Span = if (fitted.span) |mark| .{ .start = mark.start, .len = mark.len } else null;
            printMarked(line.child(.{ .x_off = @intCast(column) }), fitted.piece.bytes, span, style, matched);
        }
    }
    if (count < list.count and count < placed.content.height) {
        const label = try std.fmt.allocPrint(ctx.arena, commands.more, .{list.count - count});
        _ = body.child(.{ .y_off = @intCast(count), .height = 1 }).printSegment(.{ .text = label, .style = self.quiet }, .{ .wrap = .none });
    }
    return surface;
}

/// Draw a row's matching bytes without changing its fitting or wrapping.
fn printMarked(line: vaxis.Window, text: []const u8, span: ?commands.Span, plain: vaxis.Style, strong: vaxis.Style) void {
    const mark = span orelse {
        _ = line.printSegment(.{ .text = text, .style = plain }, .{ .wrap = .none });
        return;
    };
    var start = @min(mark.start, text.len);
    var end = @min(mark.start + mark.len, text.len);
    if (start == end) {
        _ = line.printSegment(.{ .text = text, .style = plain }, .{ .wrap = .none });
        return;
    }
    // A byte match may end before a combining mark. Window segments start
    // fresh grapheme iterators, so expand to whole clusters before splitting.
    var clusters = vaxis.unicode.graphemeIterator(text);
    while (clusters.next()) |cluster| {
        if (cluster.start >= end) break;
        if (cluster.start + cluster.len <= start) continue;
        start = @min(start, cluster.start);
        end = @max(end, cluster.start + cluster.len);
    }
    _ = line.print(&.{
        .{ .text = text[0..start], .style = plain },
        .{ .text = text[start..end], .style = strong },
        .{ .text = text[end..], .style = plain },
    }, .{ .wrap = .none });
}

test "Palette keeps the selected command visible at one row and hides closed or clipped choices" {
    var menu: slash_menu.Menu = .{ .shown = commands.Shown.next(null, 7, commands.conversation.listed()) };
    const shown = &menu.shown.?;
    shown.highlight = shown.list.count - 1;
    var palette: Self = .{ .menu = &menu };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 1 }, .cell_size = .{} };
    const surface = try palette.widget().draw(ctx);
    try std.testing.expectEqual(.drawn, shown.seen);
    try std.testing.expectEqual(shown.pick(shown.highlight), menu.drawn_pick.?);
    try std.testing.expectEqual(@as(u16, 1), surface.size.height);
    try std.testing.expectEqual(widget_style.of(palette.caps, .{ .background = .selection }), surface.readCell(0, 0).style);
    var text: [80]u8 = undefined;
    var used: usize = 0;
    for (surface.buffer) |cell| {
        if (cell.char.grapheme.len == 0) continue;
        @memcpy(text[used..][0..cell.char.grapheme.len], cell.char.grapheme);
        used += cell.char.grapheme.len;
    }
    try std.testing.expect(std.mem.startsWith(u8, text[0..used], shown.list.entries[shown.highlight].shown));
    const clipped = try palette.widget().draw(ctx.withConstraints(.{}, .{ .width = 2, .height = 1 }));
    try std.testing.expectEqual(@as(usize, 0), clipped.buffer.len);
    try std.testing.expectEqual(.hidden, shown.seen);
    try std.testing.expectEqual(null, menu.drawn_pick);
    shown.close();
    const closed = try palette.widget().draw(ctx);
    try std.testing.expectEqual(@as(usize, 0), closed.buffer.len);
    try std.testing.expectEqual(.closed, shown.seen);
    try std.testing.expectEqual(null, menu.drawn_pick);
}

test "Palette hover is transient and clicks activate only visible command rows" {
    const Selected = struct {
        index: ?usize = null,
        revision: ?u64 = null,
        fn select(raw: *anyopaque, _: *vxfw.EventContext, pressed: commands.Shown.Pick) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.index = pressed.index;
            self.revision = pressed.revision;
        }
    };
    var selected: Selected = .{};
    var menu: slash_menu.Menu = .{ .shown = commands.Shown.next(null, 7, commands.conversation.listed()) };
    const shown = &menu.shown.?;
    var palette: Self = .{ .menu = &menu, .userdata = &selected, .on_select = Selected.select, .style = .{ .fg = .{ .index = 3 } } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 5 }, .cell_size = .{} };
    const initial = try palette.widget().draw(draw_ctx);
    try std.testing.expect(!initial.readCell(2, 2).style.reverse);
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try palette.widget().handleEvent(&ctx, .mouse_enter);
    const motion: vaxis.Mouse = .{ .row = 2, .col = 2, .button = .none, .mods = .{}, .type = .motion };
    try palette.widget().handleEvent(&ctx, .{ .mouse = motion });
    const hovered = try palette.widget().draw(draw_ctx);
    try std.testing.expect(!hovered.readCell(2, 2).style.reverse);
    try std.testing.expectEqual(vaxis.Style.Underline.single, hovered.readCell(2, 2).style.ul_style);
    try std.testing.expectEqual(widget_style.of(palette.caps, .{ .background = .selection }), hovered.readCell(2, 1).style);
    try std.testing.expectEqual(palette.style.fg, hovered.readCell(2, 2).style.fg);
    palette.hover_style = .{ .bg = .{ .index = 5 } };
    const coloured = try palette.widget().draw(draw_ctx);
    for (2..78) |col| try std.testing.expectEqual(vaxis.Color{ .index = 5 }, coloured.readCell(@intCast(col), 2).style.bg);
    try std.testing.expectEqual(widget_style.of(palette.caps, .{ .background = .selection }), coloured.readCell(2, 1).style);
    try std.testing.expectEqual(@as(usize, 0), shown.highlight);
    try std.testing.expect(selected.index == null);
    try std.testing.expectEqual(vaxis.Mouse.Shape.pointer, ctx.cmds.items[ctx.cmds.items.len - 1].set_mouse_shape);
    var press = motion;
    press.button = .left;
    press.type = .press;
    try palette.widget().handleEvent(&ctx, .{ .mouse = press });
    try std.testing.expectEqual(@as(?usize, 1), selected.index);
    shown.revision = 8;
    try palette.widget().handleEvent(&ctx, .{ .mouse = press });
    try std.testing.expectEqual(@as(?u64, 7), selected.revision);
    shown.revision = 7;
    try palette.widget().handleEvent(&ctx, .mouse_leave);
    const left = try palette.widget().draw(draw_ctx);
    try std.testing.expectEqual(initial.readCell(2, 2).style, left.readCell(2, 2).style);
    try std.testing.expectEqual(vaxis.Mouse.Shape.default, ctx.cmds.items[ctx.cmds.items.len - 1].set_mouse_shape);
    shown.highlight = shown.list.count - 1;
    _ = try palette.widget().draw(draw_ctx.withConstraints(.{}, .{ .width = 80, .height = 1 }));
    press.row = 0;
    try palette.widget().handleEvent(&ctx, .{ .mouse = press });
    try std.testing.expectEqual(@as(?usize, shown.highlight), selected.index);
    selected.index = null;
    _ = try palette.widget().draw(draw_ctx.withConstraints(.{}, .{ .width = 2, .height = 1 }));
    try palette.widget().handleEvent(&ctx, .{ .mouse = press });
    try std.testing.expect(selected.index == null);
    palette.on_select = null;
    _ = try palette.widget().draw(draw_ctx);
    try std.testing.expectEqual(@as(usize, 0), palette.hover.targets.len);
    shown.close();
    _ = try palette.widget().draw(draw_ctx);
    try palette.widget().handleEvent(&ctx, .{ .mouse = press });
    try std.testing.expect(selected.index == null);
}

test "Palette selection uses the shared ink wash for plain and matching cells in every skin and depth" {
    const Select = struct {
        fn select(_: *anyopaque, _: *vxfw.EventContext, _: commands.Shown.Pick) !void {}
    };
    for ([_]?overview.Rgb{ .{ 255, 255, 255 }, null }) |terminal| {
        for ([_]overview.Caps.Depth{ .direct, .indexed, .none }) |depth| for ([_]bool{ true, false }) |unicode| {
            const caps: overview.Caps = .{ .background = terminal, .depth = depth, .unicode = unicode };
            var menu: slash_menu.Menu = .{ .shown = commands.Shown.next(null, 1, commands.conversation.listed()) };
            const shown = &menu.shown.?;
            shown.list.count = 2;
            shown.list.entries[0].matches = .{ .name = .{ .start = 1, .len = 3 }, .description = .{ .start = 0, .len = 2 } };
            var palette: Self = .{ .menu = &menu, .on_select = Select.select };
            palette.setCaps(caps);
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 4 }, .cell_size = .{} };
            const plain = widget_style.of(caps, .{ .background = .selection });
            const strong = widget_style.of(caps, .{ .bold = true, .background = .selection });
            const column = shown.list.descriptionColumn();
            // Moving onto the selected row never replaces its ink wash with hover.
            for ([_]i17{ 1, 2 }) |pointed| {
                palette.hover.point = .{ .col = 2, .row = pointed };
                const surface = try palette.widget().draw(ctx);
                for (2..78) |col| {
                    const marked = (col >= 3 and col < 6) or (col >= column + 2 and col < column + 4);
                    try std.testing.expectEqual(if (marked) strong else plain, surface.readCell(@intCast(col), 1).style);
                }
                try std.testing.expectEqual(depth == .none, surface.readCell(2, 1).style.reverse);
                const other = if (pointed == 2) Hover.look(palette.style, palette.hover_style) else palette.style;
                try std.testing.expectEqual(other, surface.readCell(2, 2).style);
                for ([_]u16{ 0, 79 }) |col| try std.testing.expectEqual(palette.quiet, surface.readCell(col, 1).style);
            }
        };
    }
}

test "Palette renders every chat command and description in the same normal style" {
    const cases = .{
        .{ commands.conversation, &[_][]const u8{ "/archive", "/clear", "/copy", "/effort", "/model", "/new", "/pin", "/reload-skills", "/rename", "/requests", "/result", "/setup", "/unarchive", "/unpin" } },
    };
    inline for (cases) |case| {
        var menu: slash_menu.Menu = .{ .shown = commands.Shown.next(null, 1, case[0].listed()) };
        const shown = &menu.shown.?;
        var palette: Self = .{ .menu = &menu };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
        const surface = try palette.widget().draw(ctx);
        try std.testing.expectEqual(case[1].len + 2, surface.size.height);
        for (case[1], 0..) |expected, row| {
            var text: [256]u8 = undefined;
            var used: usize = 0;
            for (surface.buffer[(row + 1) * 80 + 2 ..][0..76]) |cell| {
                @memcpy(text[used..][0..cell.char.grapheme.len], cell.char.grapheme);
                used += cell.char.grapheme.len;
            }
            const line = std.mem.trimEnd(u8, text[0..used], " ");
            try std.testing.expect(std.mem.startsWith(u8, line, expected));
            try std.testing.expect(shown.list.entries[row].description.len != 0);
            try std.testing.expect(std.mem.indexOf(u8, line, shown.list.entries[row].description[0..@min(20, shown.list.entries[row].description.len)]) != null);
            if (shown.list.entries[row].description.len != 0) {
                try std.testing.expect(!surface.readCell(2, @intCast(row + 1)).style.dim);
                try std.testing.expectEqual(surface.readCell(2, @intCast(row + 1)).style, surface.readCell(@intCast(shown.list.descriptionColumn() + 2), @intCast(row + 1)).style);
            }
        }
    }
}

test "Palette description clipping ends with the list row ellipsis at every width and selection" {
    const description = "Verify the project and review the implementation";
    for ([_]bool{ true, false }) |unicode| {
        for (0..2) |selected| {
            for (0..81) |width| {
                var menu: slash_menu.Menu = .{ .shown = commands.Shown.next(null, 1, commands.conversation.listed()) };
                const shown = &menu.shown.?;
                shown.list.count = 2;
                shown.highlight = selected;
                for (shown.list.entries[0..2]) |*entry| entry.description = description;
                var palette: Self = .{ .menu = &menu, .caps = .{ .unicode = unicode, .width = .unicode } };
                var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena.deinit();
                const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = 2 }, .cell_size = .{} };
                const surface = try palette.widget().draw(ctx);
                try std.testing.expect(surface.size.width <= width);
                const column = shown.list.descriptionColumn();
                const room = width -| column;
                if (room == 0) continue;
                const clipped = description.len > room;
                const kept = @min(description.len, room - @intFromBool(clipped));
                for (0..2) |row| {
                    for (description[0..kept], 0..) |byte, index| {
                        const cell = surface.readCell(@intCast(column + index), @intCast(row));
                        try std.testing.expectEqualStrings(&.{byte}, cell.char.grapheme);
                        try std.testing.expect(!cell.style.dim);
                        try std.testing.expectEqual(if (row == selected) widget_style.of(palette.caps, .{ .background = .selection }) else palette.style, cell.style);
                    }
                    if (clipped) {
                        const cell = surface.readCell(@intCast(width - 1), @intCast(row));
                        try std.testing.expectEqualStrings(if (unicode) "…" else ".", cell.char.grapheme);
                        try std.testing.expect(!cell.style.dim);
                        try std.testing.expectEqual(if (row == selected) widget_style.of(palette.caps, .{ .background = .selection }) else palette.style, cell.style);
                    }
                }
            }
        }
    }
}

test "Palette description fitting keeps whole wide and combining clusters" {
    const cases = [_]struct { text: []const u8, room: u16, expected: []const u8, unicode: bool = true, query: ?[]const u8 = null, bold: bool = false }{
        .{ .text = "archive this chat", .room = 8, .expected = "archive…" },
        .{ .text = "archive this chat", .room = 1, .expected = "…" },
        .{ .text = "archive this chat", .room = 17, .expected = "archive this chat" },
        .{ .text = "界ab界c", .room = 6, .expected = "界ab…" },
        .{ .text = "e\u{301}clair", .room = 5, .expected = "e\u{301}cla…", .query = "e", .bold = true },
        .{ .text = "e\u{301}clair", .room = 1, .expected = "…", .query = "e" },
        .{ .text = "abcd e", .room = 4, .expected = "abc…", .query = "e" },
        .{ .text = "archive this chat", .room = 8, .expected = "archive.", .unicode = false },
        .{ .text = "界abcd", .room = 3, .expected = "?a.", .unicode = false },
        .{ .text = "", .room = 1, .expected = "" },
    };
    for (std.enums.values(vaxis.gwidth.Method)) |method| {
        for (cases) |case| {
            var menu: slash_menu.Menu = .{ .shown = commands.Shown.next(null, 1, commands.conversation.listed()) };
            const shown = &menu.shown.?;
            shown.list.count = 1;
            shown.list.entries[0].description = case.text;
            if (case.query) |query| shown.list.entries[0].matches = @import("skill_completion.zig").match(query, "archive", case.text).?.spans;
            const column = shown.list.descriptionColumn();
            const width: u16 = @intCast(column + case.room);
            var palette: Self = .{ .menu = &menu, .caps = .{ .unicode = case.unicode, .width = method } };
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} };
            const surface = try palette.widget().draw(ctx);
            var text: std.Io.Writer.Allocating = .init(arena.allocator());
            var col = column;
            while (col < width) {
                const cell = surface.readCell(@intCast(col), 0);
                try std.testing.expect(col + cell.char.width <= width);
                try text.writer.writeAll(cell.char.grapheme);
                col += @max(1, cell.char.width);
            }
            try std.testing.expectEqualStrings(case.expected, std.mem.trimEnd(u8, text.written(), " "));
            if (case.query != null) try std.testing.expectEqual(case.bold, surface.readCell(@intCast(column), 0).style.bold);
        }
    }
}

test "Palette panel keeps every selected row visible across tiny bounds budgets and terminal capabilities" {
    const Select = struct {
        fn select(_: *anyopaque, _: *vxfw.EventContext, _: commands.Shown.Pick) !void {}
    };
    for ([_]bool{ false, true }) |unicode| {
        for (0..14) |width_index| {
            const width: u16 = if (width_index == 13) 80 else @intCast(width_index);
            for (0..9) |height| for (0..9) |budget| {
                var menu: slash_menu.Menu = .{ .shown = commands.Shown.next(null, 7, commands.conversation.listed()) };
                const shown = &menu.shown.?;
                for (0..shown.list.count) |selected| {
                    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                    defer arena.deinit();
                    shown.highlight = selected;
                    const caps: overview.Caps = .{ .unicode = unicode, .depth = .none, .width = .unicode };
                    var palette: Self = .{
                        .menu = &menu,
                        .caps = caps,
                        .style = widget_style.of(caps, .{ .background = .input_surface }),
                        .quiet = widget_style.of(caps, .{ .colour = .quiet, .background = .input_surface }),
                        .max_height = @intCast(budget),
                        .on_select = Select.select,
                    };
                    const surface = try palette.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = @intCast(height) }, .cell_size = .{} });
                    const available = @min(height, budget);
                    if (width <= 2 or available == 0) {
                        try std.testing.expectEqual(.hidden, shown.seen);
                        try std.testing.expectEqual(@as(usize, 0), surface.buffer.len);
                        try std.testing.expectEqual(@as(usize, 0), palette.hover.targets.len);
                        continue;
                    }
                    const framed = width >= 7 and available >= 3;
                    const inset: u16 = if (framed) 2 else 0;
                    const top: u16 = if (framed) 1 else 0;
                    const body = @min(shown.list.count, available - 2 * top);
                    const count = if (shown.list.count <= body) body else if (body >= 2) body - 1 else body;
                    try std.testing.expectEqual(.drawn, shown.seen);
                    try std.testing.expectEqual(width, surface.size.width);
                    try std.testing.expectEqual(body + 2 * top, surface.size.height);
                    try std.testing.expectEqual(count, palette.hover.targets.len);
                    try std.testing.expect(palette.first <= selected and selected < palette.first + count);
                    const row = top + selected - palette.first;
                    for (inset..width - inset) |col| {
                        const cell = surface.readCell(@intCast(col), @intCast(row));
                        try std.testing.expect(cell.style.reverse);
                        try std.testing.expect(!cell.style.dim and !cell.style.bold);
                        try std.testing.expectEqual(vaxis.Color.default, cell.style.fg);
                        try std.testing.expectEqual(vaxis.Color.default, cell.style.bg);
                    }
                    try std.testing.expectEqualStrings("/", surface.readCell(inset, @intCast(row)).char.grapheme);
                    for (palette.hover.targets, 0..) |rect, index| {
                        try std.testing.expectEqual(@as(i17, @intCast(top + index)), rect.row);
                        try std.testing.expectEqual(inset, rect.col);
                        try std.testing.expectEqual(width - 2 * inset, rect.width);
                        try std.testing.expectEqual(@as(u16, 1), rect.height);
                    }
                    if (framed) {
                        try std.testing.expectEqualStrings(if (unicode) "┌" else "+", surface.readCell(0, 0).char.grapheme);
                        try std.testing.expectEqualStrings(if (unicode) "┐" else "+", surface.readCell(width - 1, 0).char.grapheme);
                        try std.testing.expectEqualStrings(if (unicode) "└" else "+", surface.readCell(0, surface.size.height - 1).char.grapheme);
                        try std.testing.expectEqualStrings(if (unicode) "┘" else "+", surface.readCell(width - 1, surface.size.height - 1).char.grapheme);
                        for (1..surface.size.height - 1) |edge_row| {
                            for ([_]u16{ 0, width - 1 }) |col| {
                                const cell = surface.readCell(col, @intCast(edge_row));
                                try std.testing.expectEqualStrings(if (unicode) "│" else "|", cell.char.grapheme);
                                try std.testing.expect(!cell.style.reverse);
                            }
                        }
                        for (1..width - 1) |col| {
                            for ([_]u16{ 0, surface.size.height - 1 }) |edge_row| {
                                const cell = surface.readCell(@intCast(col), edge_row);
                                try std.testing.expectEqualStrings(if (unicode) "─" else "-", cell.char.grapheme);
                                try std.testing.expectEqual(palette.quiet, cell.style);
                            }
                        }
                    }
                }
            };
        }
    }
}

test "Palette border padding and overflow consume clicks without activating rows" {
    const Selected = struct {
        pick: ?commands.Shown.Pick = null,
        fn select(raw: *anyopaque, _: *vxfw.EventContext, pick: commands.Shown.Pick) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.pick = pick;
        }
    };
    for ([_]bool{ false, true }) |unicode| {
        var selected: Selected = .{};
        var menu: slash_menu.Menu = .{ .shown = commands.Shown.next(null, 7, commands.conversation.listed()) };
        const shown = &menu.shown.?;
        shown.highlight = shown.list.count - 1;
        var palette: Self = .{ .menu = &menu, .caps = .{ .unicode = unicode }, .userdata = &selected, .on_select = Selected.select };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const surface = try palette.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 5 }, .cell_size = .{} });
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        shown.move(false);
        for (0..surface.size.height) |row| for (0..surface.size.width) |col| {
            selected.pick = null;
            ctx.consume_event = false;
            try palette.widget().handleEvent(&ctx, .{ .mouse = .{ .row = @intCast(row), .col = @intCast(col), .button = .left, .type = .press, .mods = .{} } });
            try std.testing.expect(ctx.consume_event);
            const named_row = row >= 1 and row < 3 and col >= 2 and col < 38;
            try std.testing.expectEqual(named_row, palette.hover.pointing);
            if (named_row) {
                try std.testing.expectEqual(palette.first + row - 1, selected.pick.?.index);
                try std.testing.expectEqual(@as(u64, 7), selected.pick.?.revision);
            } else try std.testing.expectEqual(null, selected.pick);
        };
        try std.testing.expectEqualStrings("+", surface.readCell(2, 3).char.grapheme);
        try std.testing.expectEqual(palette.quiet, surface.readCell(2, 3).style);
    }
}

test "Palette publishes menu picks and keeps the drawn identity across wheel movement" {
    const Selected = struct {
        pick: ?commands.Shown.Pick = null,
        fn select(raw: *anyopaque, _: *vxfw.EventContext, pick: commands.Shown.Pick) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.pick = pick;
        }
    };
    var selected: Selected = .{};
    var menu: slash_menu.Menu = .{ .shown = commands.Shown.nextOf(null, 7, 23, commands.conversation.listed()) };
    const shown = &menu.shown.?;
    var palette: Self = .{ .menu = &menu, .userdata = &selected, .on_select = Selected.select };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 5 }, .cell_size = .{} };
    _ = try palette.widget().draw(draw_ctx);
    const drawn = menu.drawn_pick.?;
    try std.testing.expectEqual(commands.Shown.Pick{ .index = 0, .revision = 7, .source = 23 }, drawn);
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try palette.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .wheel_down, .type = .press, .mods = .{}, .row = 1, .col = 2 } });
    try std.testing.expectEqual(@as(usize, 1), shown.highlight);
    try std.testing.expectEqual(drawn, menu.drawn_pick.?);
    try palette.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = 1, .col = 2 } });
    try std.testing.expectEqual(drawn, selected.pick.?);
    _ = try palette.widget().draw(draw_ctx);
    try std.testing.expectEqual(shown.pick(1), menu.drawn_pick.?);
    _ = try palette.widget().draw(draw_ctx.withConstraints(.{}, .{ .width = 2, .height = 5 }));
    try std.testing.expectEqual(null, menu.drawn_pick);
    menu.reset();
    selected.pick = null;
    try palette.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = 1, .col = 2 } });
    try std.testing.expectEqual(null, selected.pick);
}
