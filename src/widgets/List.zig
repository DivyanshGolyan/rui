const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Hover = @import("Hover.zig");
const RowInset = @import("RowInset.zig");

pub fn List(comptime Target: type) type {
    return struct {
        const Self = @This();
        pub const Line = []const vaxis.Segment;
        pub const Region = struct {
            start: u16,
            end: u16,
            target: Target,
            selected: bool = false,
            tint_start: ?u16 = null,
            tint_end: ?u16 = null,
        };
        pub const Row = struct {
            lines: []const Line,
            target: ?Target = null,
            alternate_target: ?Target = null,
            regions: []const Region = &.{},
        };

        pub const Rows = struct {
            userdata: *const anyopaque,
            count: u32,
            rowFn: *const fn (*const anyopaque, usize, std.mem.Allocator) std.mem.Allocator.Error!Row,
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
            pressed: *const fn (*anyopaque, *vxfw.EventContext, Target) anyerror!void,
        };
        pub const Span = struct { row: i17, height: u16, target: ?Target, alternate_target: ?Target = null, regions: []const Region = &.{} };
        pub const Range = struct { first: u32 = 0, end: u32 = 0 };
        pub const Presence = struct { userdata: *anyopaque, changed: *const fn (*anyopaque, *vxfw.EventContext, bool) anyerror!void };
        /// The top line and the lines shown by the draw after a wheel scroll.
        pub const Scroll = struct { top: u32, height: u32 };
        pub const Edge = enum { above, below };
        pub const Counts = struct { above: u32, below: u32 };
        pub const Edges = struct { userdata: *const anyopaque, lineFn: *const fn (*const anyopaque, Edge, Range, Counts, std.mem.Allocator) std.mem.Allocator.Error!?Line };

        rows: Rows = .none,
        inset_rows: bool = false,
        selected: ?u32 = null,
        anchor: ?struct { index: u32, row: u16 } = null,
        on_presence: ?Presence = null,
        /// A wheel event asked for a scroll report; `wheel_drawn` is set once a draw has applied it.
        wheel_due: bool = false,
        wheel_drawn: bool = false,
        /// Whether the last draw moved the list by a wheel scroll rather than a selection or a trim.
        wheel_applied: bool = false,
        edges: ?Edges = null,
        on_press: ?Press = null,
        base_style: vaxis.Style = .{},
        selection_style: vaxis.Style = .{ .reverse = true },
        indicator_style: ?vaxis.Style = null,
        indicator_align: @FieldType(vxfw.RichText, "text_align") = .left,
        aboveFn: ?*const fn (count: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!Line = null,
        hover_style: vaxis.Style = .{ .ul_style = .single },
        belowFn: ?*const fn (count: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!Line = null,
        list: vxfw.ListView = .{ .children = .{ .slice = &.{} }, .draw_cursor = false },
        shown: Range = .{},
        shown_at: []const Span = &.{},
        last_size: ?vxfw.Size = null,
        hover: Hover = .{},

        pub fn widget(self: *Self) vxfw.Widget {
            return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
        }

        fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            try self.hover.handleEvent(ctx, input);
            if (self.on_presence) |presence| switch (input) {
                .mouse_enter => try presence.changed(presence.userdata, ctx, true),
                .mouse_leave => try presence.changed(presence.userdata, ctx, false),
                else => {},
            };
            if (input != .mouse) return;
            const mouse = input.mouse;
            if ((mouse.button == .left or mouse.button == .right) and mouse.type == .press) {
                const press = self.on_press orelse return;
                const size = self.last_size orelse return;
                if (mouse.col < 0 or mouse.col >= size.width) return;
                for (self.shown_at) |span| {
                    if (mouse.row >= span.row and mouse.row < span.row + span.height) {
                        const alternate = mouse.button == .right or mouse.mods.alt;
                        const target = if (alternate) span.alternate_target orelse return else for (span.regions) |region| {
                            if (mouse.col >= region.start and mouse.col < region.end) break region.target;
                        } else span.target orelse return;
                        ctx.consume_event = true;
                        return press.pressed(press.userdata, ctx, target);
                    }
                }
                return;
            }
            // The wheel's shown rows are reported after the draw applies it (scrollReport), never from here:
            // the content surface's own handler consumes the wheel, and the top moves only at the next draw.
            try self.list.handleEvent(ctx, input);
            if (mouse.button == .wheel_up or mouse.button == .wheel_down) self.wheel_due = true;
        }

        /// The shown rows after a wheel scroll, once a draw has applied it. Returns null until then, and once per scroll.
        pub fn scrollReport(self: *Self) ?Scroll {
            if (!self.wheel_drawn) return null;
            self.wheel_due = false;
            self.wheel_drawn = false;
            return .{ .top = self.list.scroll.top, .height = self.shown.end -| self.shown.first };
        }

        const Lazy = struct {
            owner: *const Self,
            index: u32,
            row: ?Row = null,
            base_style: vaxis.Style = .{},
            hovered: ?struct { start: u16, end: u16 } = null,
            selection_style: vaxis.Style = .{},
            hover_style: ?vaxis.Style = null,

            fn widget(self: *Lazy) vxfw.Widget {
                return .{ .userdata = self, .drawFn = drawRow };
            }

            fn load(self: *Lazy, arena: std.mem.Allocator) std.mem.Allocator.Error!void {
                if (self.row == null) {
                    const row = try self.owner.rows.rowFn(self.owner.rows.userdata, self.index, arena);
                    std.debug.assert(row.lines.len > 0 and row.lines.len <= std.math.maxInt(u16));
                    const selected = self.owner.selected == self.index;
                    self.hover_style = if (selected) null else self.owner.hover_style;
                    self.selection_style = self.owner.selection_style;
                    self.base_style = self.owner.base_style;
                    if (selected) self.base_style = selection(self.base_style, self.owner.selection_style);
                    const lines = try arena.alloc(Line, row.lines.len);
                    for (row.lines, lines) |line, *copy| {
                        const segments = try arena.alloc(vaxis.Segment, line.len);
                        for (line, segments) |segment, *dest| {
                            dest.* = .{ .text = try arena.dupe(u8, segment.text), .style = if (selected) selection(segment.style, self.owner.selection_style) else segment.style };
                        }
                        copy.* = segments;
                    }
                    self.row = .{ .lines = lines, .target = row.target, .alternate_target = row.alternate_target, .regions = try arena.dupe(Region, row.regions) };
                }
            }

            fn drawRow(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
                const self: *Lazy = @ptrCast(@alignCast(raw));
                try self.load(ctx.arena);
                const row = self.row.?;
                const surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), .{ .width = ctx.max.width.?, .height = @intCast(row.lines.len) });
                @memset(surface.buffer, .{ .style = self.base_style });
                if (surface.size.width == 0) return surface;
                for (row.lines, 0..) |line, y| {
                    if (self.owner.inset_rows) {
                        try RowInset.draw(ctx, surface, @intCast(y), line, self.base_style);
                    } else {
                        var label: vxfw.RichText = .{ .text = line, .base_style = self.base_style, .width_basis = .parent, .softwrap = false };
                        const drawn = try label.widget().draw(ctx.withConstraints(.{}, .{ .width = surface.size.width, .height = 1 }));
                        if (drawn.size.height != 0) @memcpy(surface.buffer[y * surface.size.width ..][0..surface.size.width], drawn.buffer[0..surface.size.width]);
                    }
                }
                if (self.hovered) |range| if (self.hover_style) |hover| for (0..surface.size.height) |y| {
                    for (range.start..range.end) |x| {
                        const focused = for (row.regions) |region| {
                            if (region.selected and x >= (region.tint_start orelse region.start) and x < (region.tint_end orelse region.end)) break true;
                        } else false;
                        if (!focused) {
                            const cell = &surface.buffer[y * surface.size.width + x];
                            cell.style = hovering(cell.style, hover);
                        }
                    }
                };
                for (row.regions) |region| if (region.selected and (region.tint_start orelse region.start) < surface.size.width) {
                    for (0..surface.size.height) |y| for ((region.tint_start orelse region.start)..@min(region.tint_end orelse region.end, surface.size.width)) |x| {
                        const cell = &surface.buffer[y * surface.size.width + x];
                        cell.style = selection(cell.style, self.selection_style);
                    };
                };
                return surface;
            }
        };

        fn selection(style: vaxis.Style, selected: vaxis.Style) vaxis.Style {
            var result = style;
            result.bg = selected.bg;
            result.reverse = selected.reverse;
            result.dim = false;
            return result;
        }

        fn hovering(style: vaxis.Style, hover: vaxis.Style) vaxis.Style {
            var result = Hover.look(style, hover);
            result.dim = false;
            return result;
        }

        const Building = struct {
            owner: *const Self,
            arena: std.mem.Allocator,
            built: std.ArrayList(*Lazy) = .empty,

            fn at(self: *Building, index: u32) std.mem.Allocator.Error!*Lazy {
                for (self.built.items) |row| if (row.index == index) return row;
                const row = try self.arena.create(Lazy);
                row.* = .{ .owner = self.owner, .index = index };
                try row.load(self.arena);
                try self.built.append(self.arena, row);
                return row;
            }

            fn height(self: *Building, index: u32) std.mem.Allocator.Error!u16 {
                return @intCast((try self.at(index)).row.?.lines.len);
            }

            fn fit(self: *Building, first: u32, room: u16) std.mem.Allocator.Error!Window {
                var window: Window = .{ .first = first, .end = first };
                while (window.end < self.owner.rows.count and window.height < room) {
                    const rows = try self.height(window.end);
                    if (rows > room - window.height) break;
                    window.height += rows;
                    window.end += 1;
                }
                return window;
            }
        };

        const Window = struct {
            first: u32,
            end: u32,
            height: u16 = 0,
            above: u16 = 0,
            below: u16 = 0,
        };

        fn edgeLine(self: *const Self, side: Edge, range: Range, arena: std.mem.Allocator) std.mem.Allocator.Error!?Line {
            const edges = self.edges orelse {
                const count_from = self.rows.countFromFn orelse return null;
                const count = switch (side) {
                    .above => count_from(self.rows.userdata, 0) -| count_from(self.rows.userdata, range.first),
                    .below => count_from(self.rows.userdata, range.end),
                };
                if (count == 0) return null;
                const words = switch (side) {
                    .above => self.aboveFn,
                    .below => self.belowFn,
                } orelse return null;
                return try words(count, arena);
            };
            const count_from = self.rows.countFromFn orelse return edges.lineFn(edges.userdata, side, range, .{ .above = range.first, .below = self.rows.count -| range.end }, arena);
            const counts: Counts = .{
                .above = count_from(self.rows.userdata, 0) -| count_from(self.rows.userdata, range.first),
                .below = count_from(self.rows.userdata, range.end),
            };
            return edges.lineFn(edges.userdata, side, range, counts, arena);
        }

        fn measure(self: *const Self, building: *Building, first: u32, height: u16, keep_selected: bool) std.mem.Allocator.Error!Window {
            const minimum = try building.height(if (keep_selected) self.selected.? else first);
            const marker_room = height -| minimum;
            var above: u16 = 0;
            var below: u16 = 0;
            var window = try building.fit(first, height);
            while (true) {
                var changed = false;
                const range: Range = .{ .first = window.first, .end = window.end };
                if (above == 0 and marker_room > above + below and try self.edgeLine(.above, range, building.arena) != null) {
                    above = 1;
                    changed = true;
                }
                if (below == 0 and marker_room > above + below and try self.edgeLine(.below, range, building.arena) != null) {
                    below = 1;
                    changed = true;
                }
                if (!changed) break;
                window = try building.fit(first, height - above - below);
            }
            window.above = above;
            window.below = below;
            return window;
        }

        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *Self = @ptrCast(@alignCast(raw));
            // A wheel's pending lines are applied by this draw; the anchor then follows the new top, not the old one.
            self.wheel_applied = self.list.scroll.pending_lines != 0;
            defer if (self.wheel_due) {
                self.wheel_drawn = true;
            };
            if (self.selected) |selected| std.debug.assert(selected < self.rows.count);
            const size = ctx.max.size();
            const previously_shown = self.shown;
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
            self.list.item_count = self.rows.count;
            self.list.cursor = cursor;
            var building: Building = .{ .owner = self, .arena = ctx.arena };
            var first = @min(self.list.scroll.top, self.rows.count - 1);
            var offset: i32 = @as(i32, self.list.scroll.offset) + self.list.scroll.pending_lines;
            const keep_selected = if (self.selected) |selected| self.anchor == null and self.list.scroll.pending_lines == 0 and (changed or (previously_shown.first <= selected and selected < previously_shown.end)) else false;
            if (keep_selected and (cursor < first or cursor - first > size.height)) first = cursor;
            if (offset < 0) {
                while (offset < 0 and first > 0) {
                    first -= 1;
                    offset += try building.height(first);
                }
            } else {
                while (offset > 0 and first + 1 < self.rows.count) {
                    offset -= try building.height(first);
                    first += 1;
                }
            }
            if (keep_selected and self.selected.? < first) first = self.selected.?;
            var window = try self.measure(&building, first, size.height, keep_selected);
            if (keep_selected) {
                const selected = self.selected.?;
                while (selected >= window.end and window.first < selected) {
                    window = try self.measure(&building, window.first + 1, size.height, true);
                }
            }
            if (self.anchor != null and !self.wheel_applied) {
                const anchor = self.anchor.?;
                // Keep the captured physical row, including marker rows and mixed heights.
                // A boundary can make the exact offset impossible; choose the closest one.
                var best = window;
                var best_distance: u32 = std.math.maxInt(u32);
                var candidate = window.first;
                var direction: i8 = 0;
                while (true) {
                    const measured = try self.measure(&building, candidate, size.height, false);
                    var position: u32 = measured.above;
                    if (candidate <= anchor.index) {
                        for (candidate..anchor.index) |index| position += try building.height(@intCast(index));
                    } else {
                        position = 0;
                    }
                    const distance: u32 = if (candidate > anchor.index) std.math.maxInt(u32) else if (position > anchor.row) position - anchor.row else anchor.row - position;
                    if (distance < best_distance) {
                        best = measured;
                        best_distance = distance;
                    }
                    if (distance == 0) break;
                    const next_direction: i8 = if (candidate > anchor.index or position < anchor.row) -1 else 1;
                    if (direction != 0 and direction != next_direction) break;
                    direction = next_direction;
                    if (direction < 0) {
                        if (candidate == 0) break;
                        candidate -= 1;
                    } else {
                        if (candidate >= anchor.index) break;
                        candidate += 1;
                    }
                }
                window = best;
            } else while (window.end == self.rows.count and window.first > 0) {
                const previous = try self.measure(&building, window.first - 1, size.height, keep_selected);
                if (previous.end != self.rows.count) break;
                window = previous;
            }
            self.list.scroll = .{ .top = window.first, .has_more = window.end < self.rows.count };
            self.shown = .{ .first = window.first, .end = window.end };
            const above_rows = window.above;
            const below_rows = window.below;
            const content = try ctx.arena.alloc(vxfw.SubSurface, window.end - window.first);
            const spans = try ctx.arena.alloc(Span, content.len);
            var hover_targets: std.ArrayList(Hover.Rect) = .empty;
            var y: u16 = 0;
            for (content, spans, window.first..) |*child, *span, index| {
                const row = try building.at(@intCast(index));
                const target = row.row.?.target;
                const regions = row.row.?.regions;
                const rect: Hover.Rect = .{ .row = y + above_rows, .width = size.width, .height = @intCast(row.row.?.lines.len) };
                if ((target != null or regions.len != 0) and self.on_press != null) {
                    if (target != null) {
                        try hover_targets.append(ctx.arena, rect);
                        row.hovered = if (self.hover.contains(rect)) .{ .start = 0, .end = size.width } else null;
                    } else for (regions) |region| {
                        if (region.start >= size.width) continue;
                        const region_rect: Hover.Rect = .{ .row = rect.row, .col = region.start, .width = @min(region.end, size.width) - region.start, .height = rect.height };
                        try hover_targets.append(ctx.arena, region_rect);
                        if (self.hover.contains(region_rect)) row.hovered = .{ .start = @min(region.tint_start orelse region.start, size.width), .end = @min(region.tint_end orelse region.end, size.width) };
                    }
                }
                const drawn = try row.widget().draw(ctx);
                child.* = .{ .origin = .{ .row = y, .col = 0 }, .surface = drawn };
                span.* = .{ .row = y + above_rows, .height = drawn.size.height, .target = target, .alternate_target = row.row.?.alternate_target, .regions = regions };
                y += drawn.size.height;
            }
            var surface: vxfw.Surface = .{ .widget = self.widget(), .size = .{ .width = size.width, .height = window.height }, .buffer = &.{}, .children = content };
            self.shown_at = spans;
            self.hover.targets = hover_targets.items;
            if (above_rows + below_rows > 0) {
                const children = try ctx.arena.alloc(vxfw.SubSurface, 1 + above_rows + below_rows);
                children[0] = .{ .origin = .{ .row = above_rows, .col = 0 }, .surface = surface };
                if (above_rows > 0) children[1] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.indicator(ctx, (try self.edgeLine(.above, self.shown, ctx.arena)) orelse &.{}) };
                if (below_rows > 0) children[children.len - 1] = .{ .origin = .{ .row = above_rows + window.height, .col = 0 }, .surface = try self.indicator(ctx, (try self.edgeLine(.below, self.shown, ctx.arena)) orelse &.{}) };
                surface = .{ .widget = self.widget(), .size = size, .buffer = &.{}, .children = children };
            }
            surface.size = size;
            surface.widget = self.widget();
            return surface;
        }

        fn indicator(self: *const Self, ctx: vxfw.DrawContext, words: Line) std.mem.Allocator.Error!vxfw.Surface {
            var line = words;
            if (self.indicator_style) |style| {
                const styled = try ctx.arena.alloc(vaxis.Segment, line.len);
                for (line, styled) |segment, *dest| dest.* = .{ .text = segment.text, .style = if (std.meta.eql(segment.style, vaxis.Style{})) style else segment.style };
                line = styled;
            }
            const label = try ctx.arena.create(vxfw.RichText);
            label.* = .{ .text = line, .text_align = self.indicator_align, .base_style = self.base_style, .width_basis = .parent, .softwrap = false };
            return label.widget().draw(ctx.withConstraints(.{}, .{ .width = ctx.max.width.?, .height = 1 }));
        }
    };
}

const TestList = List(u32);
const TestLine = TestList.Line;
const TestRow = TestList.Row;
const testHovering = TestList.hovering;
const TestRegion = TestList.Region;

const Testing = struct {
    fn context(arena: std.mem.Allocator, height: u16) vxfw.DrawContext {
        return .{ .arena = arena, .cell_arena = arena, .min = .{}, .max = .{ .width = 20, .height = height }, .cell_size = .{} };
    }

    fn below(count: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!TestLine {
        return try arena.dupe(vaxis.Segment, &.{.{ .text = try std.fmt.allocPrint(arena, "below {d}", .{count}) }});
    }

    const mixed = [_]TestRow{
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
        var occupied: u16 = 0;
        for (content(surface).children) |row| occupied += row.surface.size.height;
        try std.testing.expectEqual(occupied, child.origin.row);
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
        fn row(raw: *const anyopaque, index: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!TestRow {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            self.built += 1;
            const lines = try arena.alloc(TestLine, 1);
            lines[0] = try arena.dupe(vaxis.Segment, &.{.{ .text = if (index % 2 == 0) "even" else "odd" }});
            return .{ .lines = lines, .target = @intCast(index) };
        }
        fn count(_: *const anyopaque, first: u32) u32 {
            return 10_000 - first;
        }
    };
    var counted: Counted = .{};
    var list: TestList = .{ .rows = .{ .userdata = &counted, .count = 10_000, .rowFn = Counted.row, .countFromFn = Counted.count }, .selected = 9_000 };
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
    const rows: []const TestRow = &Testing.mixed;
    var list: TestList = .{ .rows = .of(&rows), .selected = 3, .belowFn = Testing.below };
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

test "List below counts fully hidden selectable rows and disappears at the end" {
    const rows: []const TestRow = &Testing.mixed;
    var list: TestList = .{ .rows = .of(&rows), .belowFn = Testing.below };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Testing.context(arena.allocator(), 5);
    try Testing.expectBelow(try list.widget().draw(ctx), 2);
    try Testing.expectBelow(try list.widget().draw(ctx.withConstraints(.{}, .{ .width = 20, .height = 3 })), 3);
    list.selected = 4;
    const end = try list.widget().draw(ctx);
    try Testing.expectSelected(end, "F", 1);
    try std.testing.expectEqual(@as(u32, 5), list.shown.end);
    try std.testing.expectEqualStrings("F", end.children[end.children.len - 1].surface.readCell(0, 0).char.grapheme);
    const heading_tail: []const TestRow = &.{ Testing.mixed[4], Testing.mixed[0], Testing.mixed[0] };
    list.rows = .of(&heading_tail);
    list.selected = 0;
    const tail = try list.widget().draw(ctx.withConstraints(.{}, .{ .width = 20, .height = 1 }));
    try std.testing.expectEqual(@as(usize, 1), tail.children.len);
    try std.testing.expectEqualStrings("F", tail.children[0].surface.readCell(0, 0).char.grapheme);
}

test "List presses use drawn targets on either line but never headings or the below line" {
    var rows_data = Testing.mixed;
    const rows: []const TestRow = &rows_data;
    var pressed: Testing.Pressed = .{};
    var list: TestList = .{ .rows = .of(&rows), .belowFn = Testing.below, .on_press = .{ .userdata = &pressed, .pressed = Testing.Pressed.pressed } };
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
    const rows: []const TestRow = &Testing.mixed;
    var list: TestList = .{ .rows = .of(&rows), .selected = 3, .belowFn = Testing.below };
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
    var lines = [_]TestLine{&segments};
    var rows_data = [_]TestRow{.{ .lines = &lines, .target = 9 }};
    const rows: []const TestRow = &rows_data;
    var list: TestList = .{ .rows = .of(&rows), .selected = 0, .selection_style = .{ .bg = .{ .index = 2 } } };
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
    const rows: []const TestRow = &Testing.mixed;
    var pressed: Testing.Pressed = .{};
    var list: TestList = .{ .rows = .of(&rows), .belowFn = Testing.below, .on_press = .{ .userdata = &pressed, .pressed = Testing.Pressed.pressed } };
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

test "List reports a wheel scroll after the draw applies it, even when the content surface takes the wheel" {
    const rows: []const TestRow = &Testing.mixed;
    var list: TestList = .{ .rows = .of(&rows), .belowFn = Testing.below };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Testing.context(arena.allocator(), 4);
    const drawn = try list.widget().draw(ctx);
    try std.testing.expectEqual(@as(?TestList.Scroll, null), list.scrollReport());
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    // The App's hit test sends the wheel to the widget the content surface draws with, as it would on screen.
    try Testing.content(drawn).widget.handleEvent(&events, .{ .mouse = .{ .col = 0, .row = 1, .button = .wheel_down, .type = .press, .mods = .{} } });
    try std.testing.expect(events.consume_event);
    // Nothing is reported before the draw that moves the top.
    try std.testing.expectEqual(@as(?TestList.Scroll, null), list.scrollReport());
    _ = try list.widget().draw(ctx);
    const report = list.scrollReport() orelse return error.TestExpectedEqual;
    try std.testing.expect(report.top > 0);
    try std.testing.expectEqual(list.list.scroll.top, report.top);
    try std.testing.expectEqual(list.shown.end -| list.shown.first, report.height);
    // One report per scroll.
    try std.testing.expectEqual(@as(?TestList.Scroll, null), list.scrollReport());
}

test "List wheel moves past an anchored top row, and the anchor then follows the new top" {
    const rows: []const TestRow = &Testing.mixed;
    var list: TestList = .{ .rows = .of(&rows), .belowFn = Testing.below };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Testing.context(arena.allocator(), 4);
    _ = try list.widget().draw(ctx);
    // The shell anchors the top row it shows; a wheel scroll must still move the list past it, not snap back to it.
    list.anchor = .{ .index = list.list.scroll.top, .row = 0 };
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try Testing.content(try list.widget().draw(ctx)).widget.handleEvent(&events, .{ .mouse = .{ .col = 0, .row = 1, .button = .wheel_down, .type = .press, .mods = .{} } });
    _ = try list.widget().draw(ctx);
    try std.testing.expect(list.list.scroll.top > 0);
}

test "List preserves each segment foreground while selecting every line and blank cell" {
    const rows: []const TestRow = &.{.{ .lines = &.{
        &.{ .{ .text = "!", .style = .{ .fg = .{ .index = 1 }, .bold = true } }, .{ .text = " name", .style = .{ .fg = .{ .index = 3 }, .dim = true } } },
        &.{.{ .text = "detail", .style = .{ .fg = .{ .index = 4 }, .dim = true } }},
        &.{},
    }, .target = 1 }};
    var list: TestList = .{ .rows = .of(&rows), .selected = 0, .selection_style = .{ .bg = .{ .index = 2 } } };
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
    for (cells.buffer) |cell| {
        try std.testing.expectEqual(vaxis.Color{ .index = 2 }, cell.style.bg);
        try std.testing.expect(!cell.style.dim);
    }
    try std.testing.expect(!testHovering(.{ .dim = true }, .{}).dim);
    try std.testing.expect(testHovering(.{ .dim = true }, .{}).ul_style == .off);
    list.selection_style = .{ .reverse = true };
    const plain = try list.widget().draw(ctx);
    for (plain.children[0].surface.buffer) |cell| try std.testing.expect(cell.style.reverse);
}

test "List updates its row count through exhausted resizes without building rows" {
    const Source = struct {
        fn row(_: *const anyopaque, _: usize, _: std.mem.Allocator) std.mem.Allocator.Error!TestRow {
            return error.OutOfMemory;
        }
    };
    var list: TestList = .{};
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
        fn row(_: *const anyopaque, index: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!TestRow {
            const lines = try arena.alloc(TestLine, 1);
            lines[0] = try arena.dupe(vaxis.Segment, &.{.{ .text = try std.fmt.allocPrint(arena, "{c}", .{@as(u8, @intCast(index)) + 'A'}) }});
            return .{ .lines = lines, .target = if (index == 0) null else @intCast(index) };
        }
        fn count(raw: *const anyopaque, first: u32) u32 {
            const total: *const u32 = @ptrCast(@alignCast(raw));
            return total.* -| @max(1, first);
        }
        fn above(count_: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!TestLine {
            return try arena.dupe(vaxis.Segment, &.{.{ .text = try std.fmt.allocPrint(arena, "↑ {d} more", .{count_}) }});
        }
        fn below(count_: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!TestLine {
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
        var list: TestList = .{
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
    const rows: []const TestRow = &Testing.mixed;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var list: TestList = .{ .rows = .of(&rows), .aboveFn = Testing.below, .belowFn = Testing.below };
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

test "List every two-line scroll offset shows whole rows and accounts for every Session" {
    const Words = struct {
        fn above(count: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!TestLine {
            return try arena.dupe(vaxis.Segment, &.{.{ .text = try std.fmt.allocPrint(arena, "↑ {d} more", .{count}) }});
        }
        fn below(count: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!TestLine {
            return try arena.dupe(vaxis.Segment, &.{.{ .text = try std.fmt.allocPrint(arena, "↓ {d} more", .{count}) }});
        }
    };
    var data: [12]TestRow = @splat(.{ .lines = &.{ &.{.{ .text = "first" }}, &.{.{ .text = "second" }} }, .target = 0 });
    for (&data, 0..) |*row, index| row.target = @intCast(index);
    const rows: []const TestRow = &data;
    for ([_]u16{ 46, 140 }) |width| for ([_]u16{ 4, 5, 6, 7, 21, 22, 30, 40 }) |height| for (0..data.len * 2) |offset| for ([_]?u32{ null, 0, 6, 11 }) |selected| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: TestList = .{ .rows = .of(&rows), .selected = selected, .aboveFn = Words.above, .belowFn = Words.below };
        const ctx = Testing.context(alloc, height).withConstraints(.{}, .{ .width = width, .height = height });
        list.list.item_count = @intCast(rows.len);
        list.list.cursor = selected orelse 0;
        if (selected == null) list.last_size = ctx.max.size();
        list.list.scroll = .{ .top = @intCast(offset / 2), .offset = @intCast(offset % 2) };
        for (0..2) |_| {
            const surface = try list.widget().draw(ctx);
            const content = Testing.content(surface);
            for (content.children) |child| {
                try std.testing.expect(child.origin.row >= 0);
                try std.testing.expectEqual(@as(u16, 2), child.surface.size.height);
                try std.testing.expect(child.origin.row + child.surface.size.height <= content.size.height);
            }
            for (list.shown_at) |span| try std.testing.expectEqual(@as(u16, 2), span.height);
            try std.testing.expectEqual(content.children.len, list.shown_at.len);
            if (selected) |index| {
                try std.testing.expect(list.shown.first <= index and index < list.shown.end);
            }
            var screen: vaxis.Screen = try .init(alloc, .{ .cols = width, .rows = height, .x_pixel = 0, .y_pixel = 0 });
            try surface.render(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen }, list.widget());
            var above: u32 = 0;
            var below: u32 = 0;
            var first_lines: u32 = 0;
            var second_lines: u32 = 0;
            for (0..height) |y| {
                var text: std.ArrayList(u8) = .empty;
                for (0..width) |x| try text.appendSlice(alloc, screen.readCell(@intCast(x), @intCast(y)).?.char.grapheme);
                const line = std.mem.trim(u8, text.items, " ");
                if (std.mem.eql(u8, line, "first")) {
                    first_lines += 1;
                    try std.testing.expectEqual(@as(u32, @intCast(y)), @as(u32, @intFromBool(above > 0)) + (first_lines - 1) * 2);
                } else if (std.mem.eql(u8, line, "second")) {
                    second_lines += 1;
                    try std.testing.expectEqual(first_lines, second_lines);
                } else if (std.mem.startsWith(u8, line, "↑ ")) {
                    above = try std.fmt.parseInt(u32, line[4 .. line.len - " more".len], 10);
                    try std.testing.expect(above > 0);
                    try std.testing.expectEqual(@as(usize, 0), y);
                } else if (std.mem.startsWith(u8, line, "↓ ")) {
                    below = try std.fmt.parseInt(u32, line[4 .. line.len - " more".len], 10);
                    try std.testing.expect(below > 0);
                    try std.testing.expectEqual(@as(u32, @intCast(y)), @as(u32, @intFromBool(above > 0)) + second_lines * 2);
                } else try std.testing.expectEqualStrings("", line);
            }
            try std.testing.expectEqual(first_lines, second_lines);
            try std.testing.expectEqual(list.shown.first, above);
            try std.testing.expectEqual(rows.len - list.shown.end, below);
            try std.testing.expectEqual(rows.len, above + first_lines + below);
            try std.testing.expectEqual(first_lines, list.shown.end - list.shown.first);
        }
    };
}

test "List mixed-height rows scroll in both directions and reach EOF without partial rows" {
    const data: [9]TestRow = .{
        .{ .lines = &.{&.{.{ .text = "one" }}}, .target = 0 },
        .{ .lines = &.{ &.{.{ .text = "two" }}, &.{} }, .target = 1 },
        .{ .lines = &.{ &.{.{ .text = "four" }}, &.{}, &.{}, &.{} }, .target = 2 },
        .{ .lines = &.{&.{.{ .text = "one" }}}, .target = 3 },
        .{ .lines = &.{ &.{.{ .text = "two" }}, &.{} }, .target = 4 },
        .{ .lines = &.{ &.{.{ .text = "four" }}, &.{}, &.{}, &.{} }, .target = 5 },
        .{ .lines = &.{&.{.{ .text = "one" }}}, .target = 6 },
        .{ .lines = &.{ &.{.{ .text = "two" }}, &.{} }, .target = 7 },
        .{ .lines = &.{ &.{.{ .text = "four" }}, &.{}, &.{}, &.{} }, .target = 8 },
    };
    const rows: []const TestRow = &data;
    for ([_]u16{ 46, 140 }) |width| for ([_]u16{ 6, 7, 8, 9, 10 }) |height| for (data, 0..) |row, index| for (0..row.lines.len) |offset| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var list: TestList = .{ .rows = .of(&rows), .aboveFn = Testing.below, .belowFn = Testing.below };
        list.list.wheel_scroll = 1;
        const ctx = Testing.context(arena.allocator(), height).withConstraints(.{}, .{ .width = width, .height = height });
        list.last_size = ctx.max.size();
        list.list.item_count = @intCast(rows.len);
        list.list.scroll = .{ .top = @intCast(index), .offset = @intCast(offset) };
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        for ([_]bool{ false, true }) |up| {
            for (0..data.len + 1) |_| {
                const surface = try list.widget().draw(ctx);
                const content = Testing.content(surface);
                try std.testing.expectEqual(@as(i17, 0), list.list.scroll.offset);
                try std.testing.expectEqual(list.shown.end < rows.len, list.list.scroll.has_more);
                var y: u16 = 0;
                for (content.children, list.shown.first..) |child, at| {
                    try std.testing.expectEqual(y, child.origin.row);
                    try std.testing.expectEqual(data[at].lines.len, child.surface.size.height);
                    y += child.surface.size.height;
                    try std.testing.expect(y <= content.size.height);
                }
                const above: u32 = list.shown.first;
                const below: u32 = @as(u32, @intCast(rows.len)) - list.shown.end;
                try std.testing.expectEqual(rows.len, above + content.children.len + below);
                if (above > 0) {
                    const marker = surface.children[1];
                    try std.testing.expectEqual(@as(i17, 0), marker.origin.row);
                    const expected = try std.fmt.allocPrint(arena.allocator(), "below {d}", .{above});
                    for (expected, 0..) |byte, x| try std.testing.expectEqualStrings(&.{byte}, marker.surface.readCell(@intCast(x), 0).char.grapheme);
                }
                if (below > 0) {
                    const marker = surface.children[surface.children.len - 1];
                    try std.testing.expectEqual(y + @intFromBool(above > 0), marker.origin.row);
                    const expected = try std.fmt.allocPrint(arena.allocator(), "below {d}", .{below});
                    for (expected, 0..) |byte, x| try std.testing.expectEqualStrings(&.{byte}, marker.surface.readCell(@intCast(x), 0).char.grapheme);
                }
                if ((up and above == 0) or (!up and below == 0)) break;
                const before = list.shown.first;
                events.consume_event = false;
                try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 0, .row = 0, .button = if (up) .wheel_up else .wheel_down, .type = .press, .mods = .{} } });
                try std.testing.expect(events.consume_event);
                _ = try list.widget().draw(ctx);
                try std.testing.expect(if (up) list.shown.first < before else list.shown.first > before);
            } else return error.WheelDidNotReachEdge;
        }
        try std.testing.expectEqual(@as(u32, 0), list.shown.first);
    };
}

test "List wheel reaches every Session from either end regardless of selection markers or spacer" {
    var data: [9]TestRow = @splat(.{ .lines = &.{ &.{.{ .text = "Session" }}, &.{.{ .text = "detail" }} } });
    for (data[1..], 0..) |*row, index| row.target = @intCast(index);
    data[0] = .{ .lines = &.{&.{}} };
    for ([_]bool{ false, true }) |spacer| for (0..4) |markers| for ([_]u16{ 6, 7, 8, 11, 24 }) |height| for ([_]u8{ 1, 2, 3 }) |step| for (0..9) |choice| for ([_]bool{ false, true }) |up| {
        const rows: []const TestRow = if (spacer) &data else data[1..];
        const selected: ?u32 = if (choice == 0) null else @intCast(choice - 1 + @intFromBool(spacer));
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const ctx = Testing.context(arena.allocator(), height);
        var list: TestList = .{
            .rows = .of(&rows),
            .selected = selected,
            .aboveFn = if (markers & 1 != 0) Testing.below else null,
            .belowFn = if (markers & 2 != 0) Testing.below else null,
        };
        list.last_size = ctx.max.size();
        list.list.item_count = @intCast(rows.len);
        list.list.cursor = selected orelse 0;
        list.list.scroll.top = if (up) @intCast(rows.len - 1) else 0;
        list.list.wheel_scroll = step;
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        var reached: [8]bool = @splat(false);
        for (0..rows.len + 1) |_| {
            const surface = try list.widget().draw(ctx);
            const content = Testing.content(surface);
            try std.testing.expectEqual(@as(i17, 0), list.list.scroll.offset);
            try std.testing.expectEqual(@as(i17, 0), list.list.scroll.pending_lines);
            try std.testing.expectEqual(list.shown.first, list.list.scroll.top);
            try std.testing.expectEqual(list.shown.end - list.shown.first, content.children.len);
            var y: u16 = 0;
            for (content.children, list.shown_at, list.shown.first..) |child, span, index| {
                try std.testing.expectEqual(y, child.origin.row);
                try std.testing.expectEqual(rows[index].lines.len, child.surface.size.height);
                try std.testing.expectEqual(rows[index].lines.len, span.height);
                y += child.surface.size.height;
                try std.testing.expect(y <= content.size.height);
                if (rows[index].target) |session| {
                    reached[session] = true;
                    try std.testing.expectEqualStrings("S", child.surface.readCell(0, 0).char.grapheme);
                    try std.testing.expectEqualStrings("d", child.surface.readCell(0, 1).char.grapheme);
                }
            }
            const shown = list.shown;
            _ = try list.widget().draw(ctx);
            try std.testing.expectEqualDeep(shown, list.shown);
            try std.testing.expectEqual(selected, list.selected);
            if ((up and shown.first == 0) or (!up and shown.end == rows.len)) break;
            events.consume_event = false;
            try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 0, .row = 0, .button = if (up) .wheel_up else .wheel_down, .type = .press, .mods = .{} } });
            try std.testing.expect(events.consume_event);
            _ = try list.widget().draw(ctx);
            try std.testing.expect(if (up) list.shown.first < shown.first else list.shown.first > shown.first);
        } else return error.WheelDidNotReachEdge;
        for (reached) |visible| try std.testing.expect(visible);
    };
}

test "List hides a row taller than the viewport instead of painting a partial selection" {
    const rows: []const TestRow = &.{Testing.mixed[1]};
    var list: TestList = .{ .rows = .of(&rows), .selected = 0, .aboveFn = Testing.below, .belowFn = Testing.below };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const surface = try list.widget().draw(Testing.context(arena.allocator(), 1));
    try std.testing.expectEqual(@as(?u32, 0), list.selected);
    try std.testing.expectEqual(@as(usize, 0), surface.children.len);
    try std.testing.expectEqual(@as(usize, 0), list.shown_at.len);
}

test "List hover paints only complete clickable rows without moving selection and clears on leave" {
    const rows: []const TestRow = &Testing.mixed;
    var pressed: Testing.Pressed = .{};
    var list: TestList = .{ .rows = .of(&rows), .selected = 4, .selection_style = .{ .bg = .{ .index = 2 } }, .hover_style = .{ .bg = .{ .index = 5 } }, .on_press = .{ .userdata = &pressed, .pressed = Testing.Pressed.pressed } };
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
    list.selected = null;
    const clipped_ctx = ctx.withConstraints(.{}, .{ .width = 20, .height = 2 });
    _ = try list.widget().draw(clipped_ctx);
    try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 1, .row = 1, .button = .none, .type = .motion, .mods = .{} } });
    const clipped = try list.widget().draw(clipped_ctx);
    try std.testing.expectEqual(@as(usize, 1), clipped.children.len);
    try std.testing.expectEqual(@as(usize, 1), list.shown_at.len);
    try std.testing.expect(!list.hover.pointing);
    list.list.scroll.top = 1;
    const whole = try list.widget().draw(clipped_ctx);
    try std.testing.expectEqual(list.hover_style.bg, whole.children[0].surface.readCell(0, 0).style.bg);
    try std.testing.expectEqual(@as(u16, 2), list.shown_at[0].height);
    try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 1, .row = 2, .button = .none, .type = .motion, .mods = .{} } });
    try std.testing.expect(!list.hover.pointing);
    list.on_press = null;
    _ = try list.widget().draw(clipped_ctx);
    try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 1, .row = 1, .button = .none, .type = .motion, .mods = .{} } });
    const inert = try list.widget().draw(clipped_ctx);
    try std.testing.expectEqual(list.base_style.bg, inert.children[0].surface.readCell(0, 0).style.bg);
    try std.testing.expect(!list.hover.pointing);
}

test "List column actions override row targets and region-only rows clip hover and clicks" {
    const rows: []const TestRow = &.{
        .{ .lines = &.{&.{.{ .text = "first controls" }}}, .target = 10, .regions = &.{.{ .start = 4, .end = 7, .target = 20 }} },
        .{ .lines = &.{&.{.{ .text = "second controls" }}}, .regions = &.{.{ .start = 4, .end = 30, .target = 30 }} },
        .{ .lines = &.{&.{.{ .text = "below" }}}, .regions = &.{.{ .start = 0, .end = 3, .target = 40 }} },
    };
    var pressed: Testing.Pressed = .{};
    var list: TestList = .{ .rows = .of(&rows), .on_press = .{ .userdata = &pressed, .pressed = Testing.Pressed.pressed }, .belowFn = Testing.below };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const draw_ctx = Testing.context(arena.allocator(), 2);
    const first = try list.widget().draw(draw_ctx);
    try Testing.expectBelow(first, 2);
    list.belowFn = null;
    _ = try list.widget().draw(Testing.context(arena.allocator(), 3));
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try list.widget().handleEvent(&ctx, .mouse_enter);
    var mouse: vaxis.Mouse = .{ .row = 1, .col = 5, .button = .none, .mods = .{}, .type = .motion };
    try list.widget().handleEvent(&ctx, .{ .mouse = mouse });
    const hovered = try list.widget().draw(Testing.context(arena.allocator(), 3));
    try std.testing.expectEqual(vaxis.Style.Underline.off, hovered.children[1].surface.readCell(0, 0).style.ul_style);
    try std.testing.expectEqual(vaxis.Style.Underline.single, hovered.children[1].surface.readCell(4, 0).style.ul_style);
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
    const freed = @as([*]const Hover.Rect, @ptrFromInt(0x1000))[0..4];
    for ([_]bool{ true, false }) |was_pointing| {
        ctx.cmds = .empty;
        ctx.redraw = false;
        hover.targets = freed;
        try hover.handleEvent(&ctx, .mouse_leave);
        try std.testing.expect(!hover.pointing);
        try std.testing.expect(hover.point == null);
        try std.testing.expectEqual(was_pointing, ctx.redraw);
        try std.testing.expectEqual(@as(usize, @intFromBool(was_pointing)), ctx.cmds.items.len);
        if (was_pointing) try std.testing.expectEqual(vaxis.Mouse.Shape.default, ctx.cmds.items[0].set_mouse_shape);
    }
}

test "List markers never acquire whole-row hover or press targets" {
    const rows: []const TestRow = &.{ Testing.mixed[1], Testing.mixed[1], Testing.mixed[1], Testing.mixed[1], Testing.mixed[1], Testing.mixed[1] };
    var pressed: Testing.Pressed = .{};
    var list: TestList = .{ .rows = .of(&rows), .aboveFn = Testing.below, .belowFn = Testing.below, .on_press = .{ .userdata = &pressed, .pressed = Testing.Pressed.pressed } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Testing.context(arena.allocator(), 4);
    _ = try list.widget().draw(ctx);
    list.list.scroll.top = 1;
    _ = try list.widget().draw(ctx);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try list.widget().handleEvent(&events, .mouse_enter);
    for ([_]i16{ 0, 3, 1, 2 }) |y| {
        pressed.target = null;
        try list.widget().handleEvent(&events, .{ .mouse = .{ .col = 1, .row = y, .button = .none, .type = .motion, .mods = .{} } });
        const surface = try list.widget().draw(ctx);
        const content = y == 1 or y == 2;
        try std.testing.expectEqual(content, list.hover.pointing);
        try std.testing.expectEqual(if (content) list.hover_style.ul_style else vaxis.Style.Underline.off, surface.children[0].surface.children[0].surface.readCell(0, 0).style.ul_style);
        try list.widget().handleEvent(&events, Testing.left(y));
        try std.testing.expectEqual(if (content) @as(?u32, 11) else null, pressed.target);
    }
}

test "List selected regions retain focus while other regions hover and whitespace stays inert" {
    const ranges = [_]TestRegion{ .{ .start = 1, .end = 4, .target = 11 }, .{ .start = 7, .end = 10, .target = 22 } };
    for ([_]u16{ 0, 1, 2, 4, 7, 9, 10, 20 }) |width| for ([_]?usize{ null, 0, 1 }) |focus| for ([_]i16{ -1, 0, 1, 3, 4, 6, 7, 9, 10, 19, 20 }) |pointer| {
        var regions = ranges;
        for (&regions, 0..) |*region, index| region.selected = focus == index;
        const rows: []const TestRow = &.{.{ .lines = &.{&.{.{ .text = " one   two", .style = .{ .fg = .{ .index = 3 } } }}}, .regions = &regions }};
        var pressed: Testing.Pressed = .{};
        var list: TestList = .{ .rows = .of(&rows), .selection_style = .{ .bg = .{ .index = 2 } }, .hover_style = .{ .bg = .{ .index = 5 } }, .on_press = .{ .userdata = &pressed, .pressed = Testing.Pressed.pressed } };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const draw_ctx = Testing.context(arena.allocator(), 1).withConstraints(.{}, .{ .width = width, .height = 1 });
        _ = try list.widget().draw(draw_ctx);
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        try list.widget().handleEvent(&events, .mouse_enter);
        const mouse: vaxis.Mouse = .{ .row = 0, .col = pointer, .button = .none, .type = .motion, .mods = .{} };
        try list.widget().handleEvent(&events, .{ .mouse = mouse });
        const hovered: ?usize = for (ranges, 0..) |range, index| {
            if (pointer >= range.start and pointer < @min(range.end, width)) break index;
        } else null;
        try std.testing.expectEqual(hovered != null, list.hover.pointing);
        if (hovered != null) try std.testing.expectEqual(vaxis.Mouse.Shape.pointer, events.cmds.items[events.cmds.items.len - 1].set_mouse_shape);
        const shown = try list.widget().draw(draw_ctx);
        if (width != 0) for (0..width) |x| {
            const selected = if (focus) |index| x >= ranges[index].start and x < ranges[index].end else false;
            const under = if (hovered) |index| x >= ranges[index].start and x < ranges[index].end else false;
            try std.testing.expectEqual(if (selected) list.selection_style.bg else if (under) list.hover_style.bg else list.base_style.bg, shown.children[0].surface.readCell(@intCast(x), 0).style.bg);
        };
        events.redraw = false;
        events.cmds.clearRetainingCapacity();
        try list.widget().handleEvent(&events, .{ .mouse = mouse });
        try std.testing.expect(!events.redraw);
        try std.testing.expectEqual(@as(usize, 0), events.cmds.items.len);
        try list.widget().handleEvent(&events, .{ .mouse = .{ .row = 0, .col = pointer, .button = .left, .type = .press, .mods = .{} } });
        try std.testing.expectEqual(if (hovered) |index| @as(?u32, ranges[index].target) else null, pressed.target);
        try list.widget().handleEvent(&events, .mouse_leave);
        try std.testing.expect(!list.hover.pointing and list.hover.point == null);
        if (hovered != null) try std.testing.expectEqual(vaxis.Mouse.Shape.default, events.cmds.items[events.cmds.items.len - 1].set_mouse_shape);
    };
}
test "SUI-107 List anchors mixed-height rows at the nearest attainable physical offset" {
    const three: []const TestLine = &.{ &.{.{ .text = "one" }}, &.{.{ .text = "two" }}, &.{.{ .text = "three" }} };
    const rows: [10]TestRow = @splat(.{ .lines = three });
    const all: []const TestRow = &rows;
    var list: TestList = .{ .rows = .of(&all), .anchor = .{ .index = 5, .row = 4 } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 12, .height = 12 }, .cell_size = .{} };
    _ = try list.widget().draw(ctx);
    try std.testing.expectEqual(@as(u32, 4), list.shown.first);
    try std.testing.expectEqual(@as(i17, 3), list.shown_at[1].row);
}
