//! Shared screen composition. The overview and Session keep their own workers
//! and input policy; this owner places content above input, facts and status.
const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const InputArea = @import("InputArea.zig");
const Stack = @import("widgets/Stack.zig");
const Layer = @import("widgets/Layer.zig");

pub const Overview = Screen(@import("GroupedList.zig"));
/// A Session switches between the feed and independent panel widgets.
pub const Content = struct {
    shown: vxfw.Widget,

    pub fn widget(self: *Content) vxfw.Widget {
        return self.shown;
    }
};
pub const Session = Screen(Content);

fn Screen(comptime Body: type) type {
    return struct {
        const Self = @This();

        content: *Body,
        input: vxfw.Widget,
        style: @import("vaxis").Style = .{},
        header: ?vxfw.Widget = null,
        tail: ?vxfw.Widget = null,
        host: ?vxfw.Widget = null,
        /// One feed gutter in either shell layout; input keeps its own margin.
        content_gutter: bool = false,
        marker: ?vxfw.Widget = null,
        overlay: ?vxfw.Widget = null,
        /// Reserve a natural panel's rows before drawing the remaining feed.
        /// Floating palettes leave the feed's allocation unchanged.
        overlay_reserves_space: bool = false,
        userdata: *anyopaque,
        on_event: *const fn (*anyopaque, *vxfw.EventContext, vxfw.Event) anyerror!void,

        pub const Part = enum { whole, list };

        pub fn widget(self: *Self) vxfw.Widget {
            return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
        }

        pub fn listWidget(self: *Self) vxfw.Widget {
            return .{ .userdata = self, .drawFn = drawList };
        }

        fn drawList(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *Self = @ptrCast(@alignCast(raw));
            return self.drawPart(ctx, .list);
        }

        fn event(raw: *anyopaque, ctx: *vxfw.EventContext, value: vxfw.Event) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            try self.on_event(self.userdata, ctx, value);
        }

        fn closeOverlay(raw: *anyopaque, ctx: *vxfw.EventContext) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            try self.on_event(self.userdata, ctx, .{ .key_press = .{ .codepoint = @import("vaxis").Key.escape } });
        }

        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *Self = @ptrCast(@alignCast(raw));
            return self.drawPart(ctx, .whole);
        }

        pub fn drawPart(self: *Self, ctx: vxfw.DrawContext, part: Part) std.mem.Allocator.Error!vxfw.Surface {
            const own = switch (part) {
                .whole => self.widget(),
                .list => self.listWidget(),
            };
            const size = ctx.max.size();
            if (size.width == 0 or size.height == 0) return .empty(own);
            // Nest columns to retain the existing height priority: input,
            // header, tail, marker, then the remaining content.
            const lower = try ctx.arena.create(Stack);
            const lower_children = try ctx.arena.alloc(Stack.Child, 4);
            var count: usize = 1;
            lower_children[0] = .{ .widget = self.content.widget(), .sizing = .fill };
            if (part == .whole) if (self.marker) |marker| {
                const row = try ctx.arena.create(Marker);
                row.* = .{ .child = marker, .style = self.style };
                lower_children[count] = .{ .widget = row.widget() };
                count += 1;
            };
            if (part == .whole) if (self.tail) |tail| {
                lower_children[count] = .{ .widget = tail };
                count += 1;
            };
            if (part != .list) if (self.host) |host| {
                lower_children[count] = .{ .widget = host };
                count += 1;
            };
            lower.* = .{ .children = lower_children[0..count] };
            const feed: vxfw.Widget = if (self.content_gutter) gutter: {
                const padding = try ctx.arena.create(vxfw.Padding);
                padding.* = .{ .child = lower.widget(), .padding = .{ .left = 1 } };
                break :gutter padding.widget();
            } else lower.widget();
            const upper = try ctx.arena.create(Stack);
            const upper_children = try ctx.arena.alloc(Stack.Child, 2);
            count = 0;
            if (self.header) |header| {
                upper_children[count] = .{ .widget = header };
                count += 1;
            }
            upper_children[count] = .{ .widget = feed, .sizing = .fill };
            upper.* = .{ .children = upper_children[0 .. count + 1] };
            const overlay = if (part == .list) null else self.overlay;
            const reserved: ?*ReservedPanel = if (self.overlay_reserves_space and overlay != null) reserve: {
                const slot = try ctx.arena.create(ReservedPanel);
                slot.* = .{ .child = overlay.? };
                break :reserve slot;
            } else null;
            const column = try ctx.arena.create(Stack);
            const column_children = try ctx.arena.alloc(Stack.Child, if (part == .list) 1 else if (reserved != null) 3 else 2);
            column_children[0] = .{ .widget = upper.widget(), .sizing = .fill };
            if (reserved) |slot| column_children[1] = .{ .widget = slot.spaceWidget() };
            const input_index = column_children.len - 1;
            if (part != .list) column_children[input_index] = .{ .widget = self.input };
            column.* = .{ .children = column_children };
            // Stack measures from the bottom: input first, panel second, feed
            // last. Layer then paints the very same panel surface, once.
            var base = try column.widget().draw(ctx);
            try groundBase(ctx, &base, self.style, if (reserved) |slot| slot.spaceWidget() else null);
            const panels = try ctx.arena.alloc(Layer.Panel, if (overlay != null) 1 else 0);
            if (overlay) |shown| panels[0] = .{
                .child = if (reserved) |slot| slot.shownWidget() else shown,
                .bottom = @intCast(base.children[input_index].origin.row),
                .top = if (reserved != null) @intCast(base.children[1].origin.row) else if (part == .whole and self.header != null and base.children[input_index].origin.row > 0) base.children[0].surface.children[0].surface.size.height else 0,
                .style = self.style,
                .userdata = self,
                .on_close = closeOverlay,
            };
            const layer = try ctx.arena.create(Layer);
            layer.* = .{ .base = column.widget(), .panels = panels };
            var surface = try layer.drawAbove(ctx, base);
            // Existing screen policy still owns events; these parts change
            // composition without changing how panels or input handle keys.
            surface.widget = own;
            return surface;
        }
    };
}

/// AppScreen's transparent base consists of disjoint row bands and padding.
/// Keep that layout/event tree intact; add inert surfaces only in its gaps.
/// Layer owns overlapping panels separately, including the reserved slot.
fn groundBase(ctx: vxfw.DrawContext, base: *vxfw.Surface, style: @import("vaxis").Style, reserved: ?vxfw.Widget) std.mem.Allocator.Error!void {
    const arena = ctx.arena;
    var ground: Ground = .{ .arena = arena, .cell_arena = ctx.cell_arena, .style = style, .reserved = reserved };
    try ground.collect(base.*, .{ .row = 0, .col = 0 }, base.size);
    if (ground.strips.items.len == 0) return;
    const children = try arena.alloc(vxfw.SubSurface, base.children.len + ground.strips.items.len);
    @memcpy(children[0..base.children.len], base.children);
    @memcpy(children[base.children.len..], ground.strips.items);
    base.children = children;
}

const Ground = struct {
    arena: std.mem.Allocator,
    cell_arena: std.mem.Allocator,
    style: @import("vaxis").Style,
    reserved: ?vxfw.Widget,
    strips: std.ArrayList(vxfw.SubSurface) = .empty,
    const inert: vxfw.Text = .{ .text = "" };

    fn strip(self: *Ground, origin: vxfw.RelativePoint, size: vxfw.Size) std.mem.Allocator.Error!void {
        if (size.width == 0 or size.height == 0) return;
        const surface = try vxfw.Surface.init(self.cell_arena, inert.widget(), size);
        @memset(surface.buffer, .{ .style = self.style });
        try self.strips.append(self.arena, .{ .origin = origin, .surface = surface });
    }

    fn above(_: void, a: *const vxfw.SubSurface, b: *const vxfw.SubSurface) bool {
        return a.origin.row < b.origin.row;
    }

    fn collect(self: *Ground, surface: vxfw.Surface, origin: vxfw.RelativePoint, size: vxfw.Size) std.mem.Allocator.Error!void {
        if (size.width == 0 or size.height == 0 or surface.buffer.len != 0) return;
        if (self.reserved) |slot| if (surface.widget.eql(slot)) return;
        // Input facts can follow status on screen, and list indicators can
        // precede the first child. Order references, never the event tree.
        const rows = try self.arena.alloc(*const vxfw.SubSurface, surface.children.len);
        for (surface.children, rows) |*child, *row| row.* = child;
        std.mem.sort(*const vxfw.SubSurface, rows, {}, above);
        var bottom: u16 = 0;
        for (rows) |child| {
            std.debug.assert(child.origin.row >= 0 and child.origin.col >= 0);
            const top: u16 = @min(size.height, @as(u16, @intCast(child.origin.row)));
            const left: u16 = @min(size.width, @as(u16, @intCast(child.origin.col)));
            const height = @min(child.surface.size.height, size.height - top);
            const width = @min(child.surface.size.width, size.width - left);
            if (height == 0) continue;
            // This is a column/padding walk, not overlapping-region algebra.
            std.debug.assert(top >= bottom);
            try self.strip(.{ .row = origin.row + bottom, .col = origin.col }, .{ .width = size.width, .height = top - bottom });
            try self.strip(.{ .row = origin.row + top, .col = origin.col }, .{ .width = left, .height = height });
            try self.collect(child.surface, .{ .row = origin.row + top, .col = origin.col + left }, .{ .width = width, .height = height });
            try self.strip(.{ .row = origin.row + top, .col = origin.col + left + width }, .{ .width = size.width - left - width, .height = height });
            bottom = top + height;
        }
        try self.strip(.{ .row = origin.row + bottom, .col = origin.col }, .{ .width = size.width, .height = size.height - bottom });
    }
};

/// Draw-arena custody of one measured panel. Stack reserves its actual rows;
/// Layer paints its retained surface over that space without drawing it again.
const ReservedPanel = struct {
    child: vxfw.Widget,
    drawn: vxfw.Surface = undefined,

    fn spaceWidget(self: *ReservedPanel) vxfw.Widget {
        return .{ .userdata = self, .drawFn = space };
    }

    fn shownWidget(self: *ReservedPanel) vxfw.Widget {
        return .{ .userdata = self, .drawFn = shown };
    }

    fn space(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *ReservedPanel = @ptrCast(@alignCast(raw));
        self.drawn = try self.child.draw(ctx);
        return .{ .widget = self.spaceWidget(), .size = self.drawn.size, .buffer = &.{}, .children = &.{} };
    }

    fn shown(raw: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *ReservedPanel = @ptrCast(@alignCast(raw));
        return self.drawn;
    }
};

const Marker = struct {
    child: vxfw.Widget,
    style: @import("vaxis").Style,

    fn widget(self: *Marker) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Marker = @ptrCast(@alignCast(raw));
        const width = ctx.max.width.?;
        if (width == 0 or ctx.max.height.? == 0) return .empty(self.widget());
        var row = try vxfw.Surface.init(ctx.cell_arena, self.widget(), .{ .width = width, .height = 1 });
        @memset(row.buffer, .{ .style = self.style });
        const drawn = try self.child.draw(ctx.withConstraints(.{}, .{ .width = width, .height = 1 }));
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = 0, .col = width - drawn.size.width }, .surface = drawn, .z_index = 1 };
        row.children = children;
        return row;
    }
};

test "App screens compose content input facts status and an overlay without owning the draft" {
    var bytes = "kept draft".*;
    const editor: @import("TerminalEditor.zig") = .{ .buffer = &bytes, .length = bytes.len, .cursor = 4 };
    var input: InputArea = .{ .composer = .{ .editor = &editor } };
    var list: @import("GroupedList.zig") = .{};
    const document = try std.testing.allocator.create(@import("ConversationViewport.zig").Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    var transcript: @import("DocumentView.zig") = .{ .document = document };
    var events: usize = 0;
    const Handler = struct {
        fn event(raw: *anyopaque, _: *vxfw.EventContext, _: vxfw.Event) !void {
            const count: *usize = @ptrCast(@alignCast(raw));
            count.* += 1;
        }
    };
    var overview: Overview = .{ .content = &list, .input = input.widget(), .userdata = &events, .on_event = Handler.event };
    var facade: Content = .{ .shown = transcript.widget() };
    var session: Session = .{ .content = &facade, .input = input.widget(), .userdata = &events, .on_event = Handler.event };
    const overlay: vxfw.Text = .{ .text = "Commands" };
    overview.overlay = overlay.widget();
    session.overlay = overlay.widget();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var event_context: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]vxfw.Widget{ overview.widget(), session.widget() }) |screen| {
        try screen.handleEvent(&event_context, .tick);
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
        const drawn = try screen.draw(ctx);
        try std.testing.expectEqual(@as(usize, 2), drawn.children.len);
        const column = drawn.children[0].surface;
        try std.testing.expectEqual(@as(i17, 20), column.children[1].origin.row);
        try std.testing.expectEqual(@as(i17, 19), drawn.children[1].origin.row);
        try std.testing.expect(column.children[1].surface.widget.eql(input.widget()));
        for ([_]vxfw.Size{ .{ .width = 1, .height = 1 }, .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 0 } }) |size| {
            const tiny = try screen.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height }));
            try std.testing.expect(tiny.size.width <= size.width and tiny.size.height <= size.height);
        }
        try std.testing.expectEqualStrings("kept draft", editor.buffer[0..editor.length]);
        try std.testing.expectEqual(@as(usize, 4), editor.cursor);
    }
    try std.testing.expectEqual(@as(usize, 2), events);
    const header: vxfw.Text = .{ .text = "Counts" };
    const tail: vxfw.Text = .{ .text = "Working\nQueued" };
    const marker: vxfw.Text = .{ .text = "Up" };
    session.header = header.widget();
    session.tail = tail.widget();
    session.marker = marker.widget();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
    const active = try session.widget().draw(ctx);
    try std.testing.expectEqual(@as(usize, 2), active.children.len);
    const column = active.children[0].surface;
    const upper = column.children[0].surface;
    const lower = upper.children[1];
    try std.testing.expectEqual(@as(i17, 18), lower.origin.row + lower.surface.children[2].origin.row);
    // The marker owns a whole row above the tail; the content ends above it.
    const marker_row = lower.surface.children[1];
    try std.testing.expectEqual(vxfw.RelativePoint{ .row = 17, .col = 0 }, vxfw.RelativePoint{ .row = lower.origin.row + marker_row.origin.row, .col = marker_row.origin.col });
    try std.testing.expectEqual(@as(u16, 80), marker_row.surface.size.width);
    try std.testing.expectEqual(@as(i17, 78), marker_row.surface.children[0].origin.col);
    try std.testing.expectEqual(@as(u8, 1), marker_row.surface.children[0].z_index);
    try std.testing.expectEqual(@as(u16, 16), lower.surface.children[0].surface.size.height);
    try std.testing.expectEqual(@as(i17, 20), column.children[1].origin.row);
    try std.testing.expectEqual(@as(u8, 2), active.children[1].z_index);
    session.tail = null;
    const browsing = try session.widget().draw(ctx);
    const browsing_lower = browsing.children[0].surface.children[0].surface.children[1];
    const browsing_marker = browsing_lower.surface.children[1];
    try std.testing.expectEqual(vxfw.RelativePoint{ .row = 19, .col = 0 }, vxfw.RelativePoint{ .row = browsing_lower.origin.row + browsing_marker.origin.row, .col = browsing_marker.origin.col });
    try std.testing.expectEqual(@as(u16, 18), browsing_lower.surface.children[0].surface.size.height);
    for ([_]vxfw.Size{ .{ .width = 1, .height = 1 }, .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 0 } }) |size| {
        const tiny = try session.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height }));
        try std.testing.expect(tiny.size.width <= size.width and tiny.size.height <= size.height);
        for (tiny.children) |child| try std.testing.expect(child.z_index != 1);
    }
}

test "App screens render the original composition with painted marker rows" {
    const vaxis = @import("vaxis");
    const TestContent = struct {
        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .drawFn = draw };
        }
        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), ctx.max.size());
            @memset(surface.buffer, .{ .char = .{ .grapheme = "c", .width = 1 }, .style = .{ .dim = true } });
            return surface;
        }
        fn event(_: *anyopaque, _: *vxfw.EventContext, _: vxfw.Event) !void {}
    };
    var bytes = "draft".*;
    const editor: @import("TerminalEditor.zig") = .{ .buffer = &bytes, .length = bytes.len, .cursor = 2 };
    var input: InputArea = .{ .composer = .{ .editor = &editor } };
    var content: TestContent = .{};
    var screen: Screen(TestContent) = .{ .content = &content, .input = input.widget(), .userdata = &content, .on_event = TestContent.event, .style = .{ .bg = .{ .index = 4 } } };
    const header: vxfw.Text = .{ .text = "Header", .style = .{ .bold = true } };
    const tail: vxfw.Text = .{ .text = "Tail\nSecond" };
    const marker: vxfw.Text = .{ .text = "Up" };
    const overlay: vxfw.Text = .{ .text = "Panel" };
    vxfw.DrawContext.init(.unicode);
    var hash: std.hash.Wyhash = .init(0);
    for ([_]u16{ 0, 1, 2, 7, 46, 140 }) |width| for ([_]u16{ 0, 1, 2, 5, 10, 24 }) |height| for (0..16) |flags| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        screen.header = if (flags & 1 != 0) header.widget() else null;
        screen.tail = if (flags & 2 != 0) tail.widget() else null;
        screen.marker = if (flags & 4 != 0) marker.widget() else null;
        screen.overlay = if (flags & 8 != 0) overlay.widget() else null;
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} };
        const surface = try screen.widget().draw(ctx);
        try std.testing.expectEqual(@as(usize, 0), surface.buffer.len);
        var terminal: vaxis.Screen = .{ .width = width, .height = height, .width_method = .unicode, .buf = try arena.allocator().alloc(vaxis.Cell, @as(usize, width) * height) };
        @memset(terminal.buf, .{});
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &terminal };
        try surface.render(window, input.composer.widget());
        if (screen.marker != null and screen.overlay == null and width > 0 and height > 0) {
            const upper = surface.children[0].surface.children[0].surface;
            const lower = upper.children[upper.children.len - 1];
            const row = lower.surface.children[1];
            if (row.surface.size.height > 0) {
                const y: u16 = @intCast(lower.origin.row + row.origin.row);
                const chip = row.surface.children[0];
                for (0..@intCast(chip.origin.col)) |x| {
                    try std.testing.expectEqual(screen.style.bg, terminal.readCell(@intCast(x), y).?.style.bg);
                }
            }
        }
        for (terminal.buf) |cell| {
            hash.update(cell.char.grapheme);
            std.hash.autoHash(&hash, cell.char.width);
            std.hash.autoHash(&hash, cell.style);
        }
    };
    // c347313's composition with grounded marker rows and no empty status slot,
    // across all optional rows and tiny, narrow and wide terminals.
    try std.testing.expectEqual(@as(u64, 9710008619075226950), hash.final());
}

test "App screens update layout state through exhausted resizes for every optional row combination" {
    const GroupedList = @import("GroupedList.zig");
    const Row = struct {
        text: vxfw.Text,
        calls: usize = 0,
        max: vxfw.Size = .{},

        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .drawFn = draw };
        }

        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.max = ctx.max.size();
            return self.text.widget().draw(ctx);
        }

        fn event(_: *anyopaque, _: *vxfw.EventContext, _: vxfw.Event) !void {}
    };
    var bytes = "draft".*;
    const editor: @import("TerminalEditor.zig") = .{ .buffer = &bytes, .length = bytes.len, .cursor = 2 };
    var input: InputArea = .{ .composer = .{ .editor = &editor } };
    const document = try std.testing.allocator.create(@import("ConversationViewport.zig").Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    const rows: [4]GroupedList.Row = @splat(.{ .segments = &.{.{ .text = "Session", .style = .{} }} });

    // The original composition (c347313) draws header, tail and content even
    // at zero remaining height; only the marker needs a free row. Sweep both
    // exhaustion boundaries (input/header and tail/marker) and partial layouts.
    for (0..8) |flags| for (1..11) |small_height| {
        var all: []const GroupedList.Row = rows[0..3];
        var list: GroupedList = .{ .rows = .of(&all) };
        var transcript: @import("DocumentView.zig") = .{ .document = document };
        var overview: Overview = .{ .content = &list, .input = input.widget(), .userdata = &list, .on_event = Row.event };
        var facade: Content = .{ .shown = transcript.widget() };
        var session: Session = .{ .content = &facade, .input = input.widget(), .userdata = &transcript, .on_event = Row.event };
        inline for (.{ &overview, &session }) |screen| {
            var header: Row = .{ .text = .{ .text = "Header" } };
            var tail: Row = .{ .text = .{ .text = "Tail\nSecond" } };
            var marker: Row = .{ .text = .{ .text = "Up" } };
            screen.header = if (flags & 1 != 0) header.widget() else null;
            screen.tail = if (flags & 2 != 0) tail.widget() else null;
            screen.marker = if (flags & 4 != 0) marker.widget() else null;
            const heights = [_]u16{ 24, @intCast(small_height), @intCast(small_height), @intCast(small_height), @intCast(small_height), 24 };
            // Remove, replace and grow the list while the terminal stays small.
            for (heights, [_]usize{ 3, 3, 0, 1, 4, 4 }) |height, count| {
                var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena.deinit();
                all = rows[0..count];
                list.rows = .of(&all);
                const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = height }, .cell_size = .{} };
                // InputArea still owns input height. The rest is the original
                // screen's allocation rule, independent of the Stack tree.
                const input_height = (try input.widget().draw(ctx)).size.height;
                const header_room = height - input_height;
                const header_height = if (screen.header != null) @min(1, header_room) else 0;
                const tail_room = header_room - header_height;
                const tail_height = if (screen.tail != null) @min(2, tail_room) else 0;
                const marker_room = tail_room - tail_height;
                const marker_height: u16 = if (screen.marker != null and marker_room > 0) 1 else 0;
                const content_height = marker_room - marker_height;
                header.calls = 0;
                tail.calls = 0;
                marker.calls = 0;
                _ = try screen.widget().draw(ctx);
                try std.testing.expectEqual(@intFromBool(screen.header != null), header.calls);
                try std.testing.expectEqual(@intFromBool(screen.tail != null), tail.calls);
                try std.testing.expectEqual(marker_height, marker.calls);
                if (screen.header != null) try std.testing.expectEqual(vxfw.Size{ .width = 80, .height = header_room }, header.max);
                if (screen.tail != null) try std.testing.expectEqual(vxfw.Size{ .width = 80, .height = tail_room }, tail.max);
                if (marker_height > 0) try std.testing.expectEqual(vxfw.Size{ .width = 80, .height = 1 }, marker.max);
                if (@TypeOf(screen) == *Session) {
                    try std.testing.expectEqual(vxfw.Size{ .width = 80, .height = content_height }, transcript.size);
                } else {
                    try std.testing.expectEqual(@as(?u32, @intCast(count)), list.list.item_count);
                    try std.testing.expectEqual(@as(u32, 0), list.shown.first);
                    try std.testing.expectEqual(@as(u32, @intCast(@min(count, content_height))), list.shown.end);
                    try std.testing.expectEqual(@min(count, content_height), list.shown_at.len);
                }
                try std.testing.expectEqualStrings("draft", editor.buffer[0..editor.length]);
                try std.testing.expectEqual(@as(usize, 2), editor.cursor);
            }
        }
    };
}

test "App screens reserve one measured natural panel before feed without shrinking input" {
    const Body = struct {
        draws: usize = 0,
        offered: vxfw.Size = .{},
        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .drawFn = draw };
        }
        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.draws += 1;
            self.offered = ctx.max.size();
            return vxfw.Surface.init(ctx.cell_arena, self.widget(), self.offered);
        }
        fn event(_: *anyopaque, _: *vxfw.EventContext, _: vxfw.Event) !void {}
    };
    const Panel = struct {
        rows: u16 = 1,
        draws: usize = 0,
        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .drawFn = draw };
        }
        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.draws += 1;
            return vxfw.Surface.init(ctx.cell_arena, self.widget(), .{ .width = ctx.max.width.?, .height = @min(self.rows, ctx.max.height.?) });
        }
    };
    var bytes = "kept\ndraft".*;
    const editor: @import("TerminalEditor.zig") = .{ .buffer = &bytes, .length = bytes.len, .cursor = 4 };
    var input: InputArea = .{ .composer = .{ .editor = &editor }, .status = null };
    var body: Body = .{};
    var panel: Panel = .{};
    var screen: Screen(Body) = .{ .content = &body, .input = input.widget(), .userdata = &body, .on_event = Body.event, .overlay_reserves_space = true };
    for ([_]u16{ 1, 2, 46, 140 }) |width| for ([_]u16{ 1, 2, 4, 7, 18, 30, 40 }) |height| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} };
        screen.overlay = null;
        const before = try screen.widget().draw(ctx);
        const ordinary_input = before.children[0].surface.children[1];
        for ([_]u16{ 1, 4, 50 }) |rows| {
            panel.rows = rows;
            panel.draws = 0;
            body.draws = 0;
            screen.overlay = panel.widget();
            const hosted = try screen.widget().draw(ctx);
            const base = hosted.children[0].surface;
            const feed = base.children[0];
            const slot = base.children[1];
            const composer = base.children[2];
            const above = hosted.children[1];
            try std.testing.expectEqual(@as(usize, 1), panel.draws);
            try std.testing.expectEqual(@as(usize, 1), body.draws);
            try std.testing.expectEqualDeep(ordinary_input.surface.size, composer.surface.size);
            try std.testing.expectEqualDeep(ordinary_input.origin, composer.origin);
            try std.testing.expectEqual(@min(rows, height - composer.surface.size.height), slot.surface.size.height);
            try std.testing.expectEqual(body.offered.height, feed.surface.size.height);
            try std.testing.expectEqual(@as(u16, height), body.offered.height + above.surface.size.height + composer.surface.size.height);
            try std.testing.expectEqual(feed.surface.size.height, above.origin.row);
            try std.testing.expectEqual(slot.origin.row, above.origin.row);
            try std.testing.expectEqual(slot.surface.size.height, above.surface.size.height);
            try std.testing.expectEqual(composer.origin.row, above.origin.row + above.surface.size.height);
            try std.testing.expect(above.surface.children[0].surface.widget.eql(panel.widget()));
            try std.testing.expectEqualStrings("kept\ndraft", editor.buffer[0..editor.length]);
            try std.testing.expectEqual(@as(usize, 4), editor.cursor);
        }
    };
}

test "App screens allocate cells once for a covered pane and its gutter" {
    const Body = struct {
        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .drawFn = draw };
        }
        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), ctx.max.size());
            @memset(surface.buffer, .{ .char = .{ .grapheme = "c", .width = 1 } });
            return surface;
        }
        fn event(_: *anyopaque, _: *vxfw.EventContext, _: vxfw.Event) !void {}
        fn cells(surface: vxfw.Surface) usize {
            var count = surface.buffer.len;
            for (surface.children) |child| count += cells(child.surface);
            return count;
        }
    };
    var bytes = "draft".*;
    const editor: @import("TerminalEditor.zig") = .{ .buffer = &bytes, .length = bytes.len };
    var input: InputArea = .{ .composer = .{ .editor = &editor } };
    var body: Body = .{};
    var screen: Screen(Body) = .{ .content = &body, .input = input.widget(), .content_gutter = true, .userdata = &body, .on_event = Body.event, .style = .{ .bg = .{ .index = 4 } } };
    for ([_]u16{ 1, 2, 46, 120, 250 }) |width| for ([_]u16{ 1, 2, 5, 40, 70 }) |height| for ([_]Screen(Body).Part{ .whole, .list }) |part| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const drawn = try screen.drawPart(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} }, part);
        // All children in this frame partition the pane. A full-pane ground
        // beneath them would double the cell allocation, even at wide sizes.
        try std.testing.expectEqual(@as(usize, width) * height, Body.cells(drawn));
        try std.testing.expectEqual(@as(usize, 0), drawn.buffer.len);
    };
}

test "App screens ground gutter short rows and empty space without changing hit targets" {
    const vaxis = @import("vaxis");
    const style: vaxis.Style = .{ .bg = .{ .index = 4 }, .fg = .{ .index = 7 } };
    const painted: vaxis.Cell = .{ .char = .{ .grapheme = "x", .width = 1 }, .style = .{ .bg = .{ .index = 2 } } };
    const text: vxfw.Text = .{ .text = "" };
    const Handler = struct {
        fn event(_: *anyopaque, _: *vxfw.EventContext, _: vxfw.Event) !void {}
    };
    var hit_widget = text.widget();
    hit_widget.eventHandler = Handler.event;
    // A natural-width row, a gutter beside a taller body, and leftover rows.
    // Visit the children out of visual order, as InputArea and List can do.
    for ([_]u16{ 1, 2, 7, 46, 120, 250 }) |width| for ([_]u16{ 1, 2, 5, 40, 70 }) |height| for (0..3) |mode| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const row_width: u16 = if (mode == 0) 0 else width / 2;
        const body_height: u16 = if (mode == 2) 0 else (height - 1) / 2;
        const ctx: vxfw.DrawContext = .{ .arena = alloc, .cell_arena = alloc, .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} };
        const row = try vxfw.Surface.init(ctx.cell_arena, hit_widget, .{ .width = row_width, .height = 1 });
        @memset(row.buffer, painted);
        const body = try vxfw.Surface.init(ctx.cell_arena, hit_widget, .{ .width = width - 1, .height = body_height });
        @memset(body.buffer, painted);
        const children = try alloc.dupe(vxfw.SubSurface, &.{
            .{ .origin = .{ .row = 1, .col = 1 }, .surface = body },
            .{ .origin = .{ .row = 0, .col = 0 }, .surface = row },
        });
        var base: vxfw.Surface = .{ .widget = hit_widget, .size = .{ .width = width, .height = height }, .buffer = &.{}, .children = children };
        var before: std.ArrayList(vxfw.HitResult) = .empty;
        try base.hitTest(alloc, &before, .{ .row = height - 1, .col = 0 });
        try groundBase(ctx, &base, style, null);
        var after: std.ArrayList(vxfw.HitResult) = .empty;
        try base.hitTest(alloc, &after, .{ .row = height - 1, .col = 0 });
        try std.testing.expectEqualDeep(before.items, after.items);
        var terminal: vaxis.Screen = .{ .width = width, .height = height, .width_method = .unicode, .buf = try alloc.alloc(vaxis.Cell, @as(usize, width) * height) };
        @memset(terminal.buf, .{});
        try base.render(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &terminal }, text.widget());
        for (0..height) |y| for (0..width) |x| {
            const covered = (y == 0 and x < row_width) or (y >= 1 and y < 1 + body_height and x >= 1);
            const expected: vaxis.Cell = if (covered) painted else .{ .style = style };
            try std.testing.expectEqualDeep(expected, terminal.readCell(@intCast(x), @intCast(y)).?);
        };
    };
}

// A frame-wide ground allocation would double these cells; putting even one
// strip on the metadata arena would leave its pointer outside cell_storage.
test "App screens allocate uncovered ground strips only in cell_arena" {
    const vaxis = @import("vaxis");
    const text: vxfw.Text = .{ .text = "" };
    var cell_storage: [4096]u8 align(@alignOf(vaxis.Cell)) = undefined;
    var cells: std.heap.FixedBufferAllocator = .init(&cell_storage);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = cells.allocator(), .min = .{}, .max = .{ .width = 8, .height = 4 }, .cell_size = .{} };
    const body = try vxfw.Surface.init(ctx.cell_arena, text.widget(), .{ .width = 6, .height = 2 });
    const children = try ctx.arena.dupe(vxfw.SubSurface, &.{.{ .origin = .{ .row = 1, .col = 1 }, .surface = body }});
    var base: vxfw.Surface = .{ .widget = text.widget(), .size = ctx.max.size(), .buffer = &.{}, .children = children };
    try groundBase(ctx, &base, .{}, null);
    try std.testing.expectEqual(@as(usize, 0), base.buffer.len);
    try std.testing.expectEqual(@as(usize, 5), base.children.len);
    const start = @intFromPtr(cell_storage[0..].ptr);
    const end = start + cell_storage.len;
    const metadata = @intFromPtr(base.children.ptr);
    try std.testing.expect(metadata < start or metadata >= end);
    var count: usize = 0;
    for (base.children) |child| {
        const ptr = @intFromPtr(child.surface.buffer.ptr);
        try std.testing.expect(ptr >= start and ptr + std.mem.sliceAsBytes(child.surface.buffer).len <= end);
        count += child.surface.buffer.len;
    }
    try std.testing.expectEqual(@as(usize, 32), count);
    try std.testing.expectEqual(count * @sizeOf(vaxis.Cell), cells.end_index);
}
