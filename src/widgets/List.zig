//! A lazy, variable-height list. The caller owns selection and all words.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Self = @This();

pub const Line = []const vaxis.Segment;
pub const Row = struct {
    /// At least one line. Borrowed until rowFn returns; copied into the frame arena.
    lines: []const Line,
    target: ?u32 = null,
};

pub const Rows = struct {
    userdata: *const anyopaque,
    count: u32,
    rowFn: *const fn (*const anyopaque, usize, std.mem.Allocator) std.mem.Allocator.Error!Row,
    /// Number of selectable rows in [first, count), without building their text.
    /// Required when an indicator is set; excludes uncounted entries such as New Session.
    countFromFn: ?*const fn (*const anyopaque, first: u32) u32 = null,

    pub const none: Rows = .{ .userdata = undefined, .count = 0, .rowFn = undefined };

    pub fn of(rows: *const []const Row) Rows {
        return .{ .userdata = @ptrCast(rows), .count = @intCast(rows.len), .rowFn = struct {
            fn at(raw: *const anyopaque, index: usize, _: std.mem.Allocator) std.mem.Allocator.Error!Row {
                const all: *const []const Row = @ptrCast(@alignCast(raw));
                return all.*[index];
            }
        }.at, .countFromFn = struct {
            fn count(raw: *const anyopaque, first: u32) u32 {
                const all: *const []const Row = @ptrCast(@alignCast(raw));
                var result: u32 = 0;
                for (all.*[first..]) |row| if (row.target != null) {
                    result += 1;
                };
                return result;
            }
        }.count };
    }
};

pub const Press = struct {
    userdata: *anyopaque,
    pressed: *const fn (*anyopaque, *vxfw.EventContext, u32) anyerror!void,
};
pub const Span = struct { row: i17, height: u16, target: ?u32 };
pub const Range = struct { first: u32 = 0, end: u32 = 0 };

rows: Rows = .none,
selected: ?u32 = null,
on_press: ?Press = null,
base_style: vaxis.Style = .{},
/// Only background and reverse override the row's styles; foregrounds stay intact.
selection_style: vaxis.Style = .{ .reverse = true },
/// Shared presentation for the above and below lines; row styles are unaffected.
indicator_style: ?vaxis.Style = null,
indicator_align: @FieldType(vxfw.RichText, "text_align") = .left,
aboveFn: ?*const fn (count: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!Line = null,
belowFn: ?*const fn (count: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!Line = null,
list: vxfw.ListView = .{ .children = .{ .slice = &.{} }, .draw_cursor = false },
shown: Range = .{},
/// Borrowed from the latest draw's arena, invalidated by the next draw.
shown_at: []const Span = &.{},
last_size: ?vxfw.Size = null,

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    // Navigation belongs to the caller, never to ListView.
    if (input != .mouse) return;
    const mouse = input.mouse;
    if (mouse.button == .left and mouse.type == .press) {
        const press = self.on_press orelse return;
        for (self.shown_at) |span| {
            if (mouse.row >= span.row and mouse.row < span.row + span.height) {
                const target = span.target orelse return;
                ctx.consume_event = true;
                return press.pressed(press.userdata, ctx, target);
            }
        }
        return;
    }
    try self.list.handleEvent(ctx, input);
}

/// One arena-owned snapshot per built row, reused across layout passes and retained
/// child redraws. No row source or mutable segment text survives into the frame.
const Lazy = struct {
    owner: *const Self,
    index: u32,
    row: ?Row = null,
    base_style: vaxis.Style = .{},

    fn widget(self: *Lazy) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawRow };
    }

    fn drawRow(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Lazy = @ptrCast(@alignCast(raw));
        if (self.row == null) {
            const row = try self.owner.rows.rowFn(self.owner.rows.userdata, self.index, ctx.arena);
            std.debug.assert(row.lines.len > 0 and row.lines.len <= std.math.maxInt(u16));
            const selected = self.owner.selected == self.index;
            self.base_style = self.owner.base_style;
            if (selected) self.base_style = selection(self.base_style, self.owner.selection_style);
            const lines = try ctx.arena.alloc(Line, row.lines.len);
            for (row.lines, lines) |line, *copy| {
                const segments = try ctx.arena.alloc(vaxis.Segment, line.len);
                for (line, segments) |segment, *dest| {
                    dest.* = .{ .text = try ctx.arena.dupe(u8, segment.text), .style = if (selected) selection(segment.style, self.owner.selection_style) else segment.style };
                }
                copy.* = segments;
            }
            self.row = .{ .lines = lines, .target = row.target };
        }
        const row = self.row.?;
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = ctx.max.width.?, .height = @intCast(row.lines.len) });
        @memset(surface.buffer, .{ .style = self.base_style });
        if (surface.size.width == 0) return surface;
        for (row.lines, 0..) |line, y| {
            var label: vxfw.RichText = .{ .text = line, .base_style = self.base_style, .width_basis = .parent, .softwrap = false };
            const drawn = try label.widget().draw(ctx.withConstraints(.{}, .{ .width = surface.size.width, .height = 1 }));
            // RichText's widget is stack-local; only its cells escape.
            if (drawn.size.height != 0) @memcpy(surface.buffer[y * surface.size.width ..][0..surface.size.width], drawn.buffer[0..surface.size.width]);
        }
        return surface;
    }
};

fn selection(style: vaxis.Style, selected: vaxis.Style) vaxis.Style {
    var result = style;
    result.bg = selected.bg;
    result.reverse = selected.reverse;
    return result;
}

const Building = struct {
    owner: *const Self,
    arena: std.mem.Allocator,
    failed: bool = false,
    built: std.ArrayList(*Lazy) = .empty,

    fn build(raw: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
        const self: *Building = @ptrCast(@alignCast(@constCast(raw)));
        if (self.failed or index >= self.owner.rows.count) return null;
        for (self.built.items) |row| if (row.index == index) return row.widget();
        const row = self.arena.create(Lazy) catch {
            self.failed = true;
            return null;
        };
        row.* = .{ .owner = self.owner, .index = @intCast(index) };
        self.built.append(self.arena, row) catch {
            self.failed = true;
            return null;
        };
        return row.widget();
    }
};

fn fullyShownEnd(self: *const Self, surface: vxfw.Surface) u32 {
    var end = self.list.scroll.top;
    for (surface.children, self.list.scroll.top..) |child, index| {
        if (child.origin.row + child.surface.size.height > surface.size.height) break;
        end = @intCast(index + 1);
    }
    return end;
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.selected) |selected| std.debug.assert(selected < self.rows.count);
    const size = ctx.max.size();
    self.shown = .{};
    self.shown_at = &.{};
    if (size.width == 0 or size.height == 0 or self.rows.count == 0) {
        self.last_size = null;
        self.list.item_count = self.rows.count;
        self.list.cursor = self.selected orelse 0;
        if (self.rows.count == 0) self.list.scroll = .{};
        return .{ .widget = self.widget(), .size = size, .buffer = &.{}, .children = &.{} };
    }
    const cursor = self.selected orelse 0;
    const changed = self.list.item_count != self.rows.count or self.list.cursor != cursor or self.last_size == null or !std.meta.eql(self.last_size.?, size);
    self.last_size = size;
    var building: Building = .{ .owner = self, .arena = ctx.arena };
    self.list.children = .{ .builder = .{ .userdata = &building, .buildFn = Building.build } };
    defer self.list.children = .{ .slice = &.{} };
    self.list.item_count = self.rows.count;
    self.list.cursor = cursor;
    if (changed) {
        if (cursor > self.list.scroll.top + size.height) self.list.jumpToItem(cursor) else self.list.ensureScroll();
    }
    var surface = try self.list.draw(ctx);
    if (building.failed) return error.OutOfMemory;
    // Preserve a selection already on screen as well as a navigation change.
    // Wheel scrolling may intentionally leave the selection off screen.
    const keep_selected = changed or if (self.selected) |selected| visible: {
        for (surface.children, self.list.scroll.top..) |child, index| {
            if (index == selected) break :visible child.origin.row >= 0 and child.origin.row + child.surface.size.height <= surface.size.height;
        }
        break :visible false;
    } else false;
    var above_rows: u16 = 0;
    var below_rows: u16 = 0;
    if (self.aboveFn != null or self.belowFn != null) {
        const count_from = self.rows.countFromFn orelse @panic("indicators need Rows.countFromFn");
        // A marker yields to the selected row, or at least one content line.
        const selected_height = for (building.built.items) |row| {
            if (self.selected == row.index) break row.row.?.lines.len;
        } else 1;
        const available = size.height -| @max(1, selected_height);
        // Shrinking the content can hide more rows (including above when the
        // selection was at the bottom). Reserve each edge at most once; both
        // counts are read again from the resulting ListView scroll state.
        while (above_rows + below_rows < available) {
            const above = count_from(self.rows.userdata, 0) - count_from(self.rows.userdata, self.list.scroll.top);
            const below = count_from(self.rows.userdata, self.fullyShownEnd(surface));
            if (above_rows == 0 and self.aboveFn != null and above > 0) {
                above_rows = 1;
            } else if (below_rows == 0 and self.belowFn != null and below > 0) {
                below_rows = 1;
            } else break;
            if (keep_selected) self.list.ensureScroll();
            surface = try self.list.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height - above_rows - below_rows }));
            if (building.failed) return error.OutOfMemory;
        }
    }
    var spans: std.ArrayList(Span) = .empty;
    for (surface.children, self.list.scroll.top..) |child, index| {
        if (child.origin.row + child.surface.size.height <= 0 or child.origin.row >= surface.size.height) continue;
        if (self.shown.end == 0) self.shown.first = @intCast(index);
        self.shown.end = @intCast(index + 1);
        const target = for (building.built.items) |row| {
            if (row.index == index) break row.row.?.target;
        } else null;
        const top = @max(0, child.origin.row);
        const bottom = @min(surface.size.height, child.origin.row + child.surface.size.height);
        try spans.append(ctx.arena, .{ .row = top + above_rows, .height = @intCast(bottom - top), .target = target });
    }
    self.shown_at = spans.items;
    // Build press spans before adding markers: markers never have row targets.
    if (above_rows + below_rows > 0) {
        const count_from = self.rows.countFromFn.?;
        // Retain ListView's reduced clipping boundary. A partially visible
        // first/last row must not paint into either indicator's line.
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1 + above_rows + below_rows);
        children[0] = .{ .origin = .{ .row = above_rows, .col = 0 }, .surface = surface };
        if (above_rows > 0) children[1] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.indicator(ctx, self.aboveFn.?, count_from(self.rows.userdata, 0) - count_from(self.rows.userdata, self.list.scroll.top)) };
        if (below_rows > 0) children[children.len - 1] = .{ .origin = .{ .row = size.height - 1, .col = 0 }, .surface = try self.indicator(ctx, self.belowFn.?, count_from(self.rows.userdata, self.fullyShownEnd(surface))) };
        surface = .{ .widget = self.widget(), .size = size, .buffer = &.{}, .children = children };
    }
    surface.size = size;
    surface.widget = self.widget();
    return surface;
}

fn indicator(self: *const Self, ctx: vxfw.DrawContext, words: *const fn (u32, std.mem.Allocator) std.mem.Allocator.Error!Line, count: u32) std.mem.Allocator.Error!vxfw.Surface {
    var line = try words(count, ctx.arena);
    if (self.indicator_style) |style| {
        const styled = try ctx.arena.alloc(vaxis.Segment, line.len);
        for (line, styled) |segment, *dest| dest.* = .{ .text = segment.text, .style = style };
        line = styled;
    }
    const label = try ctx.arena.create(vxfw.RichText);
    label.* = .{ .text = line, .text_align = self.indicator_align, .base_style = self.base_style, .width_basis = .parent, .softwrap = false };
    return label.widget().draw(ctx.withConstraints(.{}, .{ .width = ctx.max.width.?, .height = 1 }));
}

const Testing = struct {
    fn context(arena: std.mem.Allocator, height: u16) vxfw.DrawContext {
        return .{ .arena = arena, .min = .{}, .max = .{ .width = 20, .height = height }, .cell_size = .{} };
    }

    fn below(count: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!Line {
        return try arena.dupe(vaxis.Segment, &.{.{ .text = try std.fmt.allocPrint(arena, "below {d}", .{count}) }});
    }

    const mixed = [_]Row{
        .{ .lines = &.{&.{.{ .text = "Heading" }}} },
        .{ .lines = &.{ &.{.{ .text = "One" }}, &.{.{ .text = "detail" }} }, .target = 11 },
        .{ .lines = &.{&.{.{ .text = "Gap" }}} },
        .{ .lines = &.{ &.{.{ .text = "Three" }}, &.{.{ .text = "detail" }} }, .target = 33 },
        .{ .lines = &.{&.{.{ .text = "Four" }}}, .target = 44 },
    };

    fn content(surface: vxfw.Surface) vxfw.Surface {
        if (surface.children.len > 0 and surface.children[0].surface.buffer.len == 0) return surface.children[0].surface;
        return surface;
    }

    fn expectSelected(surface: vxfw.Surface, target_text: []const u8, height: u16) !void {
        var found = false;
        for (content(surface).children) |child| {
            if (child.origin.row < 0 or child.origin.row >= content(surface).size.height) continue;
            if (!std.mem.eql(u8, child.surface.readCell(0, 0).char.grapheme, target_text)) continue;
            found = true;
            try std.testing.expectEqual(height, child.surface.size.height);
            try std.testing.expect(child.origin.row + height <= content(surface).size.height);
            for (child.surface.buffer) |cell| try std.testing.expect(cell.style.reverse);
        }
        try std.testing.expect(found);
    }

    fn expectBelow(surface: vxfw.Surface, count: u32) !void {
        const child = surface.children[surface.children.len - 1];
        try std.testing.expectEqual(surface.size.height - 1, child.origin.row);
        const text = try std.fmt.allocPrint(std.testing.allocator, "below {d}", .{count});
        defer std.testing.allocator.free(text);
        for (text, 0..) |byte, column| try std.testing.expectEqualStrings(&.{byte}, child.surface.readCell(column, 0).char.grapheme);
    }

    fn left(row: i16) vxfw.Event {
        return .{ .mouse = .{ .col = 1, .row = row, .button = .left, .type = .press, .mods = .{} } };
    }

    const Pressed = struct {
        target: ?u32 = null,
        fn pressed(raw: *anyopaque, _: *vxfw.EventContext, target: u32) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.target = target;
        }
    };
};

test "List builds only visible rows once even with a below line and a distant selection" {
    const Counted = struct {
        built: usize = 0,
        fn row(raw: *const anyopaque, index: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!Row {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            self.built += 1;
            const lines = try arena.alloc(Line, 1);
            lines[0] = try arena.dupe(vaxis.Segment, &.{.{ .text = if (index % 2 == 0) "even" else "odd" }});
            return .{ .lines = lines, .target = @intCast(index) };
        }
        fn count(_: *const anyopaque, first: u32) u32 {
            return 10_000 - first;
        }
    };
    var counted: Counted = .{};
    var list: Self = .{ .rows = .{ .userdata = &counted, .count = 10_000, .rowFn = Counted.row, .countFromFn = Counted.count }, .selected = 9_000 };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Testing.context(arena.allocator(), 5);
    const surface = try list.widget().draw(ctx);
    try std.testing.expectEqual(@as(usize, 5), counted.built);
    try std.testing.expectEqual(@as(u32, 9_005), list.shown.end);
    try std.testing.expectEqualStrings("e", surface.children[surface.children.len - 1].surface.readCell(0, 0).char.grapheme);
    counted.built = 0;
    list.belowFn = Testing.below;
    const below = try list.widget().draw(ctx);
    try std.testing.expectEqual(@as(usize, 5), counted.built);
    try Testing.expectBelow(below, 996);
}

test "List keeps both selected lines visible at small heights and leaves every key to the caller" {
    const rows: []const Row = &Testing.mixed;
    var list: Self = .{ .rows = .of(&rows), .selected = 3, .belowFn = Testing.below };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Testing.context(arena.allocator(), 5);
    for ([_]u16{ 5, 3, 2, 4, 3 }) |height| {
        const surface = try list.widget().draw(ctx.withConstraints(.{}, .{ .width = 20, .height = height }));
        try Testing.expectSelected(surface, "T", 2);
    }
    list.selected = 1;
    try Testing.expectSelected(try list.widget().draw(ctx.withConstraints(.{}, .{ .width = 20, .height = 3 })), "O", 2);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    // Exhaust the key codepoint domain, including ListView navigation and Escape.
    for (0..@as(usize, std.math.maxInt(u21)) + 1) |codepoint| {
        try list.widget().handleEvent(&events, .{ .key_press = .{ .codepoint = @intCast(codepoint) } });
        try std.testing.expect(!events.consume_event);
    }
    for ([_]u21{ 'p', 'n' }) |codepoint| {
        try list.widget().handleEvent(&events, .{ .key_press = .{ .codepoint = codepoint, .mods = .{ .ctrl = true } } });
        try std.testing.expect(!events.consume_event);
    }
    try std.testing.expectEqual(@as(?u32, 1), list.selected);
}

test "List below counts selectable rows including a clipped row and disappears at the end" {
    const rows: []const Row = &Testing.mixed;
    var list: Self = .{ .rows = .of(&rows), .belowFn = Testing.below };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Testing.context(arena.allocator(), 5);
    try Testing.expectBelow(try list.widget().draw(ctx), 2);
    // Content height two clips the two-line row: all three targets remain below.
    try Testing.expectBelow(try list.widget().draw(ctx.withConstraints(.{}, .{ .width = 20, .height = 3 })), 3);
    list.selected = 4;
    const end = try list.widget().draw(ctx);
    try Testing.expectSelected(end, "F", 1);
    try std.testing.expectEqual(@as(u32, 5), list.shown.end);
    try std.testing.expectEqualStrings("F", end.children[end.children.len - 1].surface.readCell(0, 0).char.grapheme);
    // A non-selectable tail alone must not cause an indicator.
    const heading_tail: []const Row = &.{ Testing.mixed[4], Testing.mixed[0], Testing.mixed[0] };
    list.rows = .of(&heading_tail);
    list.selected = 0;
    const tail = try list.widget().draw(ctx.withConstraints(.{}, .{ .width = 20, .height = 1 }));
    try std.testing.expectEqual(@as(usize, 1), tail.children.len);
    try std.testing.expectEqualStrings("F", tail.children[0].surface.readCell(0, 0).char.grapheme);
}

test "List presses use drawn targets on either line but never headings or the below line" {
    var rows_data = Testing.mixed;
    const rows: []const Row = &rows_data;
    var pressed: Testing.Pressed = .{};
    var list: Self = .{ .rows = .of(&rows), .belowFn = Testing.below, .on_press = .{ .userdata = &pressed, .pressed = Testing.Pressed.pressed } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try list.widget().draw(Testing.context(arena.allocator(), 5));
    rows_data[1].target = 99;
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]i16{ 1, 2 }) |y| {
        try list.widget().handleEvent(&events, Testing.left(y));
        try std.testing.expectEqual(@as(?u32, 11), pressed.target);
        try std.testing.expect(events.consume_event);
        pressed.target = null;
        events.consume_event = false;
    }
    for ([_]i16{ -1, 0, 3, 4, 5 }) |y| {
        try list.widget().handleEvent(&events, Testing.left(y));
        try std.testing.expectEqual(@as(?u32, null), pressed.target);
        try std.testing.expect(!events.consume_event);
    }
    try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 1, .row = 1, .button = .right, .type = .press, .mods = .{} } });
    try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 1, .row = 1, .button = .left, .type = .release, .mods = .{} } });
    try std.testing.expectEqual(@as(?u32, null), pressed.target);
}

test "List zero and tiny sizes retain selection and clear stale press spans" {
    const rows: []const Row = &Testing.mixed;
    var list: Self = .{ .rows = .of(&rows), .selected = 3, .belowFn = Testing.below };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Testing.context(arena.allocator(), 5);
    _ = try list.widget().draw(ctx);
    for (0..4) |width| for (0..4) |height| {
        const surface = try list.widget().draw(ctx.withConstraints(.{}, .{ .width = @intCast(width), .height = @intCast(height) }));
        try std.testing.expectEqual(width, surface.size.width);
        try std.testing.expectEqual(height, surface.size.height);
        try std.testing.expectEqual(@as(?u32, 3), list.selected);
        if (width == 0 or height == 0) try std.testing.expectEqual(@as(usize, 0), list.shown_at.len);
    };
    try Testing.expectSelected(try list.widget().draw(ctx), "T", 2);
    list.rows = .none;
    list.selected = null;
    const empty = try list.widget().draw(ctx);
    try std.testing.expectEqual(@as(usize, 0), empty.children.len);
    try std.testing.expectEqual(@as(usize, 0), list.shown_at.len);
    list.rows = .of(&rows);
    list.selected = 1;
    try Testing.expectSelected(try list.widget().draw(ctx), "O", 2);
}

test "List retains frame text and styles when source rows change before child redraw" {
    var text = "Before".*;
    var segments = [_]vaxis.Segment{.{ .text = &text, .style = .{ .fg = .{ .index = 1 }, .bold = true } }};
    var lines = [_]Line{&segments};
    var rows_data = [_]Row{.{ .lines = &lines, .target = 9 }};
    const rows: []const Row = &rows_data;
    var list: Self = .{ .rows = .of(&rows), .selected = 0, .selection_style = .{ .bg = .{ .index = 2 } } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Testing.context(arena.allocator(), 2);
    const before = try list.widget().draw(ctx);
    @memset(&text, 'X');
    segments[0] = .{ .text = "After" };
    list.selected = null;
    const retained = try before.children[0].surface.widget.draw(ctx);
    try std.testing.expectEqualStrings("B", retained.readCell(0, 0).char.grapheme);
    try std.testing.expectEqual(vaxis.Color{ .index = 1 }, retained.readCell(0, 0).style.fg);
    try std.testing.expectEqual(vaxis.Color{ .index = 2 }, retained.readCell(19, 0).style.bg);
    try std.testing.expect(retained.readCell(0, 0).style.bold);
    const after = try list.widget().draw(ctx);
    try std.testing.expectEqualStrings("A", after.children[0].surface.readCell(0, 0).char.grapheme);
}

test "List wheel scrolls without changing selection and presses match the visible two-line row" {
    const rows: []const Row = &Testing.mixed;
    var pressed: Testing.Pressed = .{};
    var list: Self = .{ .rows = .of(&rows), .belowFn = Testing.below, .on_press = .{ .userdata = &pressed, .pressed = Testing.Pressed.pressed } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Testing.context(arena.allocator(), 4);
    _ = try list.widget().draw(ctx);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 0, .row = 1, .button = .wheel_down, .type = .press, .mods = .{} } });
    try std.testing.expect(events.consume_event);
    const surface = try list.widget().draw(ctx);
    try std.testing.expect(list.shown.first > 0);
    try std.testing.expectEqual(@as(?u32, null), list.selected);
    var checked = false;
    for (Testing.content(surface).children, list.list.scroll.top..) |child, index| {
        if (index >= rows.len or rows[index].target == null) continue;
        const top = @max(0, child.origin.row);
        const bottom = @min(Testing.content(surface).size.height, child.origin.row + child.surface.size.height);
        var y = top;
        while (y < bottom) : (y += 1) {
            events.consume_event = false;
            pressed.target = null;
            try list.widget().handleEvent(&events, Testing.left(@intCast(y)));
            try std.testing.expectEqual(rows[index].target, pressed.target);
            try std.testing.expect(events.consume_event);
            checked = true;
        }
    }
    try std.testing.expect(checked);
}

test "List preserves each segment foreground while selecting every line and blank cell" {
    const rows: []const Row = &.{.{ .lines = &.{
        &.{ .{ .text = "!", .style = .{ .fg = .{ .index = 1 }, .bold = true } }, .{ .text = " name", .style = .{ .fg = .{ .index = 3 } } } },
        &.{.{ .text = "detail", .style = .{ .fg = .{ .index = 4 } } }},
        &.{},
    }, .target = 1 }};
    var list: Self = .{ .rows = .of(&rows), .selected = 0, .selection_style = .{ .bg = .{ .index = 2 } } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Testing.context(arena.allocator(), 3);
    const surface = try list.widget().draw(ctx);
    const cells = surface.children[0].surface;
    try std.testing.expectEqual(@as(u16, 3), cells.size.height);
    try std.testing.expectEqual(vaxis.Color{ .index = 1 }, cells.readCell(0, 0).style.fg);
    try std.testing.expectEqual(vaxis.Color{ .index = 3 }, cells.readCell(2, 0).style.fg);
    try std.testing.expectEqual(vaxis.Color{ .index = 4 }, cells.readCell(0, 1).style.fg);
    try std.testing.expect(cells.readCell(0, 0).style.bold);
    try std.testing.expect(!cells.readCell(2, 0).style.bold);
    for (cells.buffer) |cell| try std.testing.expectEqual(vaxis.Color{ .index = 2 }, cell.style.bg);
    list.selection_style = .{ .reverse = true };
    const plain = try list.widget().draw(ctx);
    for (plain.children[0].surface.buffer) |cell| try std.testing.expect(cell.style.reverse);
}

test "List updates its row count through exhausted resizes without building rows" {
    const Source = struct {
        fn row(_: *const anyopaque, _: usize, _: std.mem.Allocator) std.mem.Allocator.Error!Row {
            return error.OutOfMemory; // An exhausted viewport must never ask for text.
        }
    };
    var list: Self = .{};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Testing.context(arena.allocator(), 0);
    for ([_]vxfw.Size{ .{ .width = 20, .height = 0 }, .{ .width = 0, .height = 3 } }) |size| {
        for ([_]u32{ 3, 0, 1, 4 }) |count| {
            list.rows = .{ .userdata = undefined, .count = count, .rowFn = Source.row };
            _ = try list.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height }));
            try std.testing.expectEqual(@as(?u32, count), list.list.item_count);
            try std.testing.expectEqual(@as(usize, 0), list.shown_at.len);
        }
    }
}

test "List both markers count rows and preserve selection at viewport edges" {
    const Source = struct {
        fn row(_: *const anyopaque, index: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!Row {
            const lines = try arena.alloc(Line, 1);
            lines[0] = try arena.dupe(vaxis.Segment, &.{.{ .text = try std.fmt.allocPrint(arena, "{c}", .{@as(u8, @intCast(index)) + 'A'}) }});
            return .{ .lines = lines, .target = if (index == 0) null else @intCast(index) };
        }
        fn count(raw: *const anyopaque, first: u32) u32 {
            const total: *const u32 = @ptrCast(@alignCast(raw));
            return total.* -| @max(1, first);
        }
        fn above(count_: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!Line {
            return try arena.dupe(vaxis.Segment, &.{.{ .text = try std.fmt.allocPrint(arena, "↑ {d} more", .{count_}) }});
        }
        fn below(count_: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!Line {
            return try arena.dupe(vaxis.Segment, &.{.{ .text = try std.fmt.allocPrint(arena, "↓ {d} more", .{count_}) }});
        }
        fn marker(surface: vxfw.Surface, y: i17, text: []const u8) !void {
            const child = for (surface.children) |child| {
                if (child.origin.row == y) break child;
            } else return error.MissingMarker;
            var actual: std.ArrayList(u8) = .empty;
            defer actual.deinit(std.testing.allocator);
            var first: ?u16 = null;
            for (0..surface.size.width) |x| {
                const cell = child.surface.readCell(@intCast(x), 0);
                try actual.appendSlice(std.testing.allocator, cell.char.grapheme);
                if (!std.mem.eql(u8, cell.char.grapheme, " ") and first == null) first = @intCast(x);
                if (!std.mem.eql(u8, cell.char.grapheme, " ")) try std.testing.expectEqual(vaxis.Color{ .index = 8 }, cell.style.fg);
            }
            try std.testing.expectEqualStrings(text, std.mem.trim(u8, actual.items, " "));
            try std.testing.expectEqual((surface.size.width - (text.len - 2)) / 2, first.?);
        }
    };
    const Case = struct { count: u32 = 13, top: u32, selected: u32, first: u32, end: u32, above: ?[]const u8, below: ?[]const u8 };
    const cases = [_]Case{
        .{ .count = 3, .top = 0, .selected = 2, .first = 0, .end = 3, .above = null, .below = null },
        .{ .top = 0, .selected = 1, .first = 0, .end = 5, .above = null, .below = "↓ 8 more" },
        .{ .top = 4, .selected = 4, .first = 4, .end = 8, .above = "↑ 3 more", .below = "↓ 5 more" },
        .{ .top = 4, .selected = 7, .first = 4, .end = 8, .above = "↑ 3 more", .below = "↓ 5 more" },
        .{ .top = 4, .selected = 8, .first = 5, .end = 9, .above = "↑ 4 more", .below = "↓ 4 more" },
        .{ .top = 8, .selected = 12, .first = 8, .end = 13, .above = "↑ 7 more", .below = null },
    };
    for ([_]u16{ 140, 46 }) |width| for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var pressed: Testing.Pressed = .{};
        var list: Self = .{
            .rows = .{ .userdata = &case.count, .count = case.count, .rowFn = Source.row, .countFromFn = Source.count },
            .selected = case.selected,
            .on_press = .{ .userdata = &pressed, .pressed = Testing.Pressed.pressed },
            .aboveFn = Source.above,
            .belowFn = Source.below,
            .indicator_align = .center,
            .indicator_style = .{ .fg = .{ .index = 8 } },
        };
        list.list.scroll.top = case.top;
        const ctx = Testing.context(arena.allocator(), 6).withConstraints(.{}, .{ .width = width, .height = 6 });
        // An unchanged redraw must resolve to exactly the same window.
        for (0..2) |_| {
            const surface = try list.widget().draw(ctx);
            try std.testing.expectEqual(case.first, list.shown.first);
            try std.testing.expectEqual(case.end, list.shown.end);
            try std.testing.expectEqual(case.end - case.first, Testing.content(surface).children.len);
            try std.testing.expectEqual(if (case.above != null or case.below != null) 1 + @as(usize, @intFromBool(case.above != null)) + @as(usize, @intFromBool(case.below != null)) else case.end - case.first, surface.children.len);
            if (case.above) |text| try Source.marker(surface, 0, text);
            if (case.below) |text| try Source.marker(surface, 5, text);
            try Testing.expectSelected(surface, &.{@as(u8, @intCast(case.selected)) + 'A'}, 1);
            const span = list.shown_at[case.selected - case.first];
            try std.testing.expectEqual(@as(?u32, case.selected), span.target);
            try std.testing.expect(span.row >= @intFromBool(case.above != null));
            try std.testing.expect(span.row + span.height <= 6 - @as(u16, @intFromBool(case.below != null)));
            var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
            try list.widget().handleEvent(&events, Testing.left(@intCast(span.row)));
            try std.testing.expectEqual(@as(?u32, case.selected), pressed.target);
            for ([_]?i16{ if (case.above != null) 0 else null, if (case.below != null) 5 else null }) |marker_row| {
                if (marker_row) |y| {
                    pressed.target = null;
                    events.consume_event = false;
                    try list.widget().handleEvent(&events, Testing.left(y));
                    try std.testing.expectEqual(@as(?u32, null), pressed.target);
                    try std.testing.expect(!events.consume_event);
                }
            }
        }
    };
}

test "List both markers yield to two-line selections through navigation and resizes" {
    const rows: []const Row = &Testing.mixed;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var list: Self = .{ .rows = .of(&rows), .aboveFn = Testing.below, .belowFn = Testing.below };
    for (2..11) |height| {
        const ctx = Testing.context(arena.allocator(), @intCast(height));
        for ([_]u32{ 1, 3, 4, 3, 1 }) |selected| {
            list.selected = selected;
            for (0..2) |_| {
                const surface = try list.widget().draw(ctx);
                try Testing.expectSelected(surface, if (selected == 1) "O" else if (selected == 3) "T" else "F", if (selected == 4) 1 else 2);
                const span = for (list.shown_at) |span| {
                    if (span.target == rows[selected].target) break span;
                } else return error.SelectionMissing;
                try std.testing.expect(span.row >= 0);
                try std.testing.expect(span.row + span.height <= height);
            }
        }
    }
}

test "List clips partially scrolled two-line rows between rendered markers" {
    const Words = struct {
        fn above(count: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!Line {
            return try arena.dupe(vaxis.Segment, &.{.{ .text = try std.fmt.allocPrint(arena, "↑ {d} more", .{count}) }});
        }
    };
    const data: [8]Row = @splat(.{ .lines = &.{ &.{.{ .text = "first" }}, &.{.{ .text = "second" }} }, .target = 0 });
    const rows: []const Row = &data;
    for ([_]u16{ 140, 46 }) |width| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var list: Self = .{ .rows = .of(&rows), .aboveFn = Words.above, .belowFn = Testing.below };
        const ctx = Testing.context(arena.allocator(), 7).withConstraints(.{}, .{ .width = width, .height = 7 });
        // A settled wheel position with the first row's first line off screen.
        list.last_size = ctx.max.size();
        list.list.item_count = @intCast(rows.len);
        list.list.scroll = .{ .top = 3, .offset = 1 };
        const surface = try list.widget().draw(ctx);
        try std.testing.expectEqual(@as(u32, 3), list.list.scroll.top);
        try std.testing.expectEqual(@as(i17, 1), list.list.scroll.offset);
        var screen: vaxis.Screen = try .init(arena.allocator(), .{ .cols = width, .rows = 7, .x_pixel = 0, .y_pixel = 0 });
        surface.render(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 7, .screen = &screen }, list.widget());
        for ([_]struct { y: u16, text: []const u8 }{ .{ .y = 0, .text = "↑ 3 more" }, .{ .y = 1, .text = "second" }, .{ .y = 6, .text = "below 2" } }) |expected| {
            var actual: std.ArrayList(u8) = .empty;
            for (0..width) |x| try actual.appendSlice(arena.allocator(), screen.readCell(@intCast(x), expected.y).?.char.grapheme);
            try std.testing.expectEqualStrings(expected.text, std.mem.trim(u8, actual.items, " "));
        }
    }
}
