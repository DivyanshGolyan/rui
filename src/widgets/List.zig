//! A lazy, variable-height list. The caller owns selection and all words.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Self = @This();
const Hover = @import("Hover.zig");

pub const Line = []const vaxis.Segment;
pub const Region = struct { start: u16, end: u16, target: u32 };
pub const Row = struct {
    /// At least one line. Borrowed until rowFn returns; copied into the frame arena.
    lines: []const Line,
    target: ?u32 = null,
    /// Column-specific actions override the whole-row target.
    regions: []const Region = &.{},
};

pub const Rows = struct {
    userdata: *const anyopaque,
    count: u32,
    rowFn: *const fn (*const anyopaque, usize, std.mem.Allocator) std.mem.Allocator.Error!Row,
    /// Number of selectable rows in [first, count), without building their text.
    /// Required when belowFn is set; must agree with row targets.
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
                for (all.*[first..]) |row| if (row.target != null or row.regions.len != 0) {
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
pub const Span = struct { row: i17, height: u16, target: ?u32, regions: []const Region = &.{} };
pub const Range = struct { first: u32 = 0, end: u32 = 0 };

rows: Rows = .none,
selected: ?u32 = null,
on_press: ?Press = null,
base_style: vaxis.Style = .{},
/// Only background and reverse override the row's styles; foregrounds stay intact.
selection_style: vaxis.Style = .{ .reverse = true },
/// The pointer's row, quieter than the selection; only background, reverse and underline apply.
/// A row that is both selected and hovered keeps the selection.
hover_style: vaxis.Style = .{ .ul_style = .single },
/// Optional presentation for the below line; row styles are unaffected.
below_style: ?vaxis.Style = null,
below_align: @FieldType(vxfw.RichText, "text_align") = .left,
belowFn: ?*const fn (count: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!Line = null,
list: vxfw.ListView = .{ .children = .{ .slice = &.{} }, .draw_cursor = false },
shown: Range = .{},
/// Borrowed from the latest draw's arena, invalidated by the next draw.
shown_at: []const Span = &.{},
last_size: ?vxfw.Size = null,
hover: Hover = .{},

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.hover.handleEvent(ctx, input);
    // Navigation belongs to the caller, never to ListView.
    if (input != .mouse) return;
    const mouse = input.mouse;
    if (mouse.button == .left and mouse.type == .press) {
        const press = self.on_press orelse return;
        const size = self.last_size orelse return;
        if (mouse.col < 0 or mouse.col >= size.width) return;
        for (self.shown_at) |span| {
            if (mouse.row >= span.row and mouse.row < span.row + span.height) {
                const target = for (span.regions) |region| {
                    if (mouse.col >= region.start and mouse.col < region.end) break region.target;
                } else span.target orelse return;
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
    hovered: bool = false,
    /// Snapshot of the owner's hover look; null while this row is selected, since selection wins.
    hover_style: ?vaxis.Style = null,

    fn widget(self: *Lazy) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawRow };
    }

    fn drawRow(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Lazy = @ptrCast(@alignCast(raw));
        if (self.row == null) {
            const row = try self.owner.rows.rowFn(self.owner.rows.userdata, self.index, ctx.arena);
            std.debug.assert(row.lines.len > 0 and row.lines.len <= std.math.maxInt(u16));
            const selected = self.owner.selected == self.index;
            self.hover_style = if (selected) null else self.owner.hover_style;
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
            self.row = .{ .lines = lines, .target = row.target, .regions = try ctx.arena.dupe(Region, row.regions) };
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
        if (self.hovered) if (self.hover_style) |hover| for (surface.buffer) |*cell| {
            cell.style = hovering(cell.style, hover);
        };
        return surface;
    }
};

fn selection(style: vaxis.Style, selected: vaxis.Style) vaxis.Style {
    var result = style;
    result.bg = selected.bg;
    result.reverse = selected.reverse;
    return result;
}

fn hovering(style: vaxis.Style, hover: vaxis.Style) vaxis.Style {
    var result = selection(style, hover);
    result.ul_style = hover.ul_style;
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
    self.hover.targets = &.{};
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
    if (self.belowFn) |below| {
        const count_from = self.rows.countFromFn orelse @panic("belowFn needs Rows.countFromFn");
        const count = count_from(self.rows.userdata, self.fullyShownEnd(surface));
        // Selection takes priority if a row cannot fit alongside the indicator.
        const selected_height = for (building.built.items) |row| {
            if (self.selected == row.index) break row.row.?.lines.len;
        } else 0;
        if (count > 0 and size.height > selected_height) {
            const wants_cursor = changed;
            if (wants_cursor) self.list.ensureScroll();
            surface = try self.list.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height - 1 }));
            if (building.failed) return error.OutOfMemory;
            const remaining = count_from(self.rows.userdata, self.fullyShownEnd(surface));
            // Count includes a row whose bottom line does not fit, not headings.
            var line = try below(remaining, ctx.arena);
            if (self.below_style) |style| {
                const styled = try ctx.arena.alloc(vaxis.Segment, line.len);
                for (line, styled) |segment, *dest| dest.* = .{ .text = segment.text, .style = style };
                line = styled;
            }
            const label = try ctx.arena.create(vxfw.RichText);
            label.* = .{ .text = line, .text_align = self.below_align, .base_style = self.base_style, .width_basis = .parent, .softwrap = false };
            const indicator = try label.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 }));
            const children = try ctx.arena.alloc(vxfw.SubSurface, surface.children.len + 1);
            @memcpy(children[0..surface.children.len], surface.children);
            children[surface.children.len] = .{ .origin = .{ .row = size.height - 1, .col = 0 }, .surface = indicator };
            surface.children = children;
            // Keep the content height until hit spans have been clipped below.
        }
    }
    var spans: std.ArrayList(Span) = .empty;
    var hover_targets: std.ArrayList(Hover.Rect) = .empty;
    for (surface.children, self.list.scroll.top..) |*child, index| {
        if (child.origin.row + child.surface.size.height <= 0 or child.origin.row >= surface.size.height) continue;
        if (self.shown.end == 0) self.shown.first = @intCast(index);
        self.shown.end = @intCast(index + 1);
        const built = for (building.built.items) |row| {
            if (row.index == index) break row.row;
        } else null;
        const target = if (built) |row| row.target else null;
        const regions = if (built) |row| row.regions else &.{};
        const top = @max(0, child.origin.row);
        const bottom = @min(surface.size.height, child.origin.row + child.surface.size.height);
        try spans.append(ctx.arena, .{ .row = top, .height = @intCast(bottom - top), .target = target, .regions = regions });
        if ((target != null or regions.len != 0) and self.on_press != null) {
            const rect: Hover.Rect = .{ .row = top, .width = size.width, .height = @intCast(bottom - top) };
            if (target != null) {
                try hover_targets.append(ctx.arena, rect);
            } else for (regions) |region| {
                if (region.start < size.width) try hover_targets.append(ctx.arena, .{ .row = top, .col = region.start, .width = @min(region.end, size.width) -| region.start, .height = @intCast(bottom - top) });
            }
            const hovered = if (target != null) self.hover.contains(rect) else for (regions) |region| {
                if (self.hover.contains(.{ .row = top, .col = region.start, .width = @min(region.end, size.width) -| region.start, .height = @intCast(bottom - top) })) break true;
            } else false;
            if (hovered) for (building.built.items) |row| {
                if (row.index != index) continue;
                row.hovered = true;
                child.surface = try row.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = child.surface.size.height }));
                break;
            };
        }
    }
    self.shown_at = spans.items;
    self.hover.targets = hover_targets.items;
    surface.size = size;
    surface.widget = self.widget();
    return surface;
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

    fn expectSelected(surface: vxfw.Surface, target_text: []const u8, height: u16) !void {
        var found = false;
        for (surface.children) |child| {
            if (child.origin.row < 0 or child.origin.row >= surface.size.height) continue;
            if (!std.mem.eql(u8, child.surface.readCell(0, 0).char.grapheme, target_text)) continue;
            found = true;
            try std.testing.expectEqual(height, child.surface.size.height);
            try std.testing.expect(child.origin.row + height <= surface.size.height);
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
    for (surface.children, list.list.scroll.top..) |child, index| {
        if (index >= rows.len or rows[index].target == null) continue;
        const top = @max(0, child.origin.row);
        const bottom = @min(surface.size.height, child.origin.row + child.surface.size.height);
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

test "List hover paints only clickable clipped rows without moving selection and clears on leave" {
    const rows: []const Row = &Testing.mixed;
    var pressed: Testing.Pressed = .{};
    var list: Self = .{ .rows = .of(&rows), .selected = 4, .selection_style = .{ .bg = .{ .index = 2 } }, .hover_style = .{ .bg = .{ .index = 5 } }, .on_press = .{ .userdata = &pressed, .pressed = Testing.Pressed.pressed } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Testing.context(arena.allocator(), 9);
    _ = try list.widget().draw(ctx);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try list.widget().handleEvent(&events, .mouse_enter);
    for ([_]i16{ 1, 2 }) |y| {
        for ([_]i16{ 0, 19 }) |x| {
            try list.widget().handleEvent(&events, .{ .mouse = .{ .col = x, .row = y, .button = .none, .type = .motion, .mods = .{} } });
            const hovered = try list.widget().draw(ctx);
            for (hovered.children[1].surface.buffer) |cell| try std.testing.expectEqual(list.hover_style.bg, cell.style.bg);
            for (hovered.children[4].surface.buffer) |cell| try std.testing.expectEqual(list.selection_style.bg, cell.style.bg);
            try std.testing.expectEqual(@as(?u32, 4), list.selected);
            try std.testing.expectEqual(@as(?u32, null), pressed.target);
            try std.testing.expect(list.hover.pointing);
        }
    }
    // The selected row keeps the selection under the pointer.
    try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 0, .row = 6, .button = .none, .type = .motion, .mods = .{} } });
    const both = try list.widget().draw(ctx);
    for (both.children[4].surface.buffer) |cell| try std.testing.expectEqual(list.selection_style.bg, cell.style.bg);
    try list.widget().handleEvent(&events, .mouse_leave);
    const plain = try list.widget().draw(ctx);
    try std.testing.expectEqual(list.base_style.bg, plain.children[1].surface.readCell(0, 0).style.bg);
    try std.testing.expect(!list.hover.pointing);
    for ([_]i16{ -1, 0, 3, 8, 9 }) |y| {
        try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 0, .row = y, .button = .none, .type = .motion, .mods = .{} } });
        _ = try list.widget().draw(ctx);
        try std.testing.expect(!list.hover.pointing);
    }
    for ([_]i16{ -1, 20 }) |x| {
        try list.widget().handleEvent(&events, .{ .mouse = .{ .col = x, .row = 2, .button = .left, .type = .press, .mods = .{} } });
        try std.testing.expectEqual(@as(?u32, null), pressed.target);
        try std.testing.expect(!list.hover.pointing);
    }
    try list.widget().handleEvent(&events, Testing.left(2));
    try std.testing.expectEqual(@as(?u32, 11), pressed.target);
    // A partially drawn two-line row has only its visible line as a target.
    list.selected = null;
    const clipped_ctx = ctx.withConstraints(.{}, .{ .width = 20, .height = 2 });
    _ = try list.widget().draw(clipped_ctx);
    try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 1, .row = 1, .button = .none, .type = .motion, .mods = .{} } });
    const clipped = try list.widget().draw(clipped_ctx);
    try std.testing.expectEqual(list.hover_style.bg, clipped.children[1].surface.readCell(0, 0).style.bg);
    try std.testing.expectEqual(@as(u16, 1), list.shown_at[1].height);
    try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 1, .row = 2, .button = .none, .type = .motion, .mods = .{} } });
    try std.testing.expect(!list.hover.pointing);
    list.on_press = null;
    _ = try list.widget().draw(clipped_ctx);
    try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 1, .row = 1, .button = .none, .type = .motion, .mods = .{} } });
    const inert = try list.widget().draw(clipped_ctx);
    try std.testing.expectEqual(list.base_style.bg, inert.children[1].surface.readCell(0, 0).style.bg);
    try std.testing.expect(!list.hover.pointing);
}

test "List column actions override row targets and region-only rows clip hover and clicks" {
    const rows: []const Row = &.{
        .{ .lines = &.{&.{.{ .text = "first controls" }}}, .target = 10, .regions = &.{.{ .start = 4, .end = 7, .target = 20 }} },
        .{ .lines = &.{&.{.{ .text = "second controls" }}}, .regions = &.{.{ .start = 4, .end = 30, .target = 30 }} },
        .{ .lines = &.{&.{.{ .text = "below" }}}, .regions = &.{.{ .start = 0, .end = 3, .target = 40 }} },
    };
    var pressed: Testing.Pressed = .{};
    var list: Self = .{ .rows = .of(&rows), .on_press = .{ .userdata = &pressed, .pressed = Testing.Pressed.pressed }, .belowFn = Testing.below };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const draw_ctx = Testing.context(arena.allocator(), 2);
    const first = try list.widget().draw(draw_ctx);
    try Testing.expectBelow(first, 2);
    // Full viewport for the region-only row and its clipped right edge.
    list.belowFn = null;
    _ = try list.widget().draw(Testing.context(arena.allocator(), 3));
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try list.widget().handleEvent(&ctx, .mouse_enter);
    var mouse: vaxis.Mouse = .{ .row = 1, .col = 5, .button = .none, .mods = .{}, .type = .motion };
    try list.widget().handleEvent(&ctx, .{ .mouse = mouse });
    const hovered = try list.widget().draw(Testing.context(arena.allocator(), 3));
    // Without colour the pointer's row underlines; reverse stays the selection's mark.
    try std.testing.expectEqual(vaxis.Style.Underline.single, hovered.children[1].surface.readCell(0, 0).style.ul_style);
    try std.testing.expect(!hovered.children[1].surface.readCell(0, 0).style.reverse);
    try std.testing.expect(list.selected == null and pressed.target == null);
    try std.testing.expectEqual(vaxis.Mouse.Shape.pointer, ctx.cmds.items[ctx.cmds.items.len - 1].set_mouse_shape);
    const Case = struct { row: i16, col: i16, expected: ?u32 };
    for ([_]Case{ .{ .row = 0, .col = 4, .expected = 20 }, .{ .row = 0, .col = 7, .expected = 10 }, .{ .row = 1, .col = 3, .expected = null }, .{ .row = 1, .col = 19, .expected = 30 }, .{ .row = 1, .col = 20, .expected = null }, .{ .row = 3, .col = 5, .expected = null } }) |case| {
        pressed.target = null;
        mouse.row = case.row;
        mouse.col = case.col;
        mouse.button = .left;
        mouse.type = .press;
        try list.widget().handleEvent(&ctx, .{ .mouse = mouse });
        try std.testing.expectEqual(case.expected, pressed.target);
    }
    try list.widget().handleEvent(&ctx, .mouse_leave);
    const left = try list.widget().draw(Testing.context(arena.allocator(), 3));
    try std.testing.expectEqual(vaxis.Style.Underline.off, left.children[1].surface.readCell(0, 0).style.ul_style);
    mouse.row = 1;
    mouse.col = 3;
    mouse.type = .motion;
    mouse.button = .none;
    try list.widget().handleEvent(&ctx, .{ .mouse = mouse });
    try std.testing.expect(!list.hover.pointing);
}

test "Hover leave never reads targets from a frame that may be freed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    var hover: Hover = .{ .targets = &.{.{ .row = 2, .width = 4 }} };
    try hover.handleEvent(&ctx, .{ .mouse = .{ .col = 1, .row = 2, .button = .none, .mods = .{}, .type = .motion } });
    try std.testing.expect(hover.pointing);
    // Stand-in for a reset frame arena: any read of these faults.
    const freed = @as([*]const Hover.Rect, @ptrFromInt(0x1000))[0..4];
    for ([_]bool{ true, false }) |was_pointing| {
        ctx.cmds = .empty;
        ctx.redraw = false;
        hover.targets = freed;
        try hover.handleEvent(&ctx, .mouse_leave);
        try std.testing.expect(!hover.pointing);
        try std.testing.expect(hover.point == null);
        try std.testing.expectEqual(was_pointing, ctx.redraw);
        // Only leaving a pointer restores the default shape.
        try std.testing.expectEqual(@as(usize, @intFromBool(was_pointing)), ctx.cmds.items.len);
        if (was_pointing) try std.testing.expectEqual(vaxis.Mouse.Shape.default, ctx.cmds.items[0].set_mouse_shape);
    }
}
