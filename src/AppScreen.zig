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
        input: *InputArea,
        style: @import("vaxis").Style = .{},
        header: ?vxfw.Widget = null,
        tail: ?vxfw.Widget = null,
        host: ?vxfw.Widget = null,
        /// One feed gutter in either shell layout; input keeps its own margin.
        content_gutter: bool = false,
        marker: ?vxfw.Widget = null,
        overlay: ?vxfw.Widget = null,
        userdata: *anyopaque,
        on_event: *const fn (*anyopaque, *vxfw.EventContext, vxfw.Event) anyerror!void,

        pub const Part = enum { whole, list, compose };
        const empty: vxfw.Text = .{ .text = "" };

        pub fn widget(self: *Self) vxfw.Widget {
            return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
        }

        pub fn listWidget(self: *Self) vxfw.Widget {
            return .{ .userdata = self, .drawFn = drawList };
        }

        pub fn composeWidget(self: *Self) vxfw.Widget {
            return .{ .userdata = self, .eventHandler = event, .drawFn = drawCompose };
        }

        fn drawList(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *Self = @ptrCast(@alignCast(raw));
            return self.drawPart(ctx, .list);
        }

        fn drawCompose(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *Self = @ptrCast(@alignCast(raw));
            return self.drawPart(ctx, .compose);
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
                .compose => self.composeWidget(),
            };
            const size = ctx.max.size();
            if (size.width == 0 or size.height == 0) return .empty(own);
            // Nest columns to retain the existing height priority: input,
            // header, tail, marker, then the remaining content.
            const lower = try ctx.arena.create(Stack);
            const lower_children = try ctx.arena.alloc(Stack.Child, 4);
            var count: usize = 1;
            lower_children[0] = .{ .widget = if (part == .compose) empty.widget() else self.content.widget(), .sizing = .fill };
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
            if (part != .compose) if (self.header) |header| {
                upper_children[count] = .{ .widget = header };
                count += 1;
            };
            upper_children[count] = .{ .widget = feed, .sizing = .fill };
            upper.* = .{ .children = upper_children[0 .. count + 1] };
            const column = try ctx.arena.create(Stack);
            const column_children = try ctx.arena.alloc(Stack.Child, if (part == .list) 1 else 2);
            column_children[0] = .{ .widget = upper.widget(), .sizing = .fill };
            if (part != .list) column_children[1] = .{ .widget = self.input.widget() };
            column.* = .{ .children = column_children };
            const base = try column.widget().draw(ctx);
            const overlay = if (part == .list) null else self.overlay;
            const panels = try ctx.arena.alloc(Layer.Panel, if (overlay != null) 1 else 0);
            if (overlay) |shown| panels[0] = .{
                .child = shown,
                .bottom = @intCast(base.children[1].origin.row),
                .top = if (part == .whole and self.header != null and base.children[1].origin.row > 0) base.children[0].surface.children[0].surface.size.height else 0,
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
            surface.buffer = try vxfw.Surface.createBuffer(ctx.arena, size);
            @memset(surface.buffer, .{ .style = self.style });
            return surface;
        }
    };
}

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
        var row = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = 1 });
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
    var overview: Overview = .{ .content = &list, .input = &input, .userdata = &events, .on_event = Handler.event };
    var facade: Content = .{ .shown = transcript.widget() };
    var session: Session = .{ .content = &facade, .input = &input, .userdata = &events, .on_event = Handler.event };
    const overlay: vxfw.Text = .{ .text = "Commands" };
    overview.overlay = overlay.widget();
    session.overlay = overlay.widget();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var event_context: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]vxfw.Widget{ overview.widget(), session.widget() }) |screen| {
        try screen.handleEvent(&event_context, .tick);
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
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
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
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
            const surface = try vxfw.Surface.init(ctx.arena, self.widget(), ctx.max.size());
            @memset(surface.buffer, .{ .char = .{ .grapheme = "c", .width = 1 }, .style = .{ .dim = true } });
            return surface;
        }
        fn event(_: *anyopaque, _: *vxfw.EventContext, _: vxfw.Event) !void {}
    };
    var bytes = "draft".*;
    const editor: @import("TerminalEditor.zig") = .{ .buffer = &bytes, .length = bytes.len, .cursor = 2 };
    var input: InputArea = .{ .composer = .{ .editor = &editor } };
    var content: TestContent = .{};
    var screen: Screen(TestContent) = .{ .content = &content, .input = &input, .userdata = &content, .on_event = TestContent.event, .style = .{ .bg = .{ .index = 4 } } };
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
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} };
        const surface = try screen.widget().draw(ctx);
        try std.testing.expectEqual(@as(usize, width) * height, surface.buffer.len);
        if (width > 0 and height > 0) try std.testing.expectEqual(screen.style.bg, surface.readCell(width - 1, height - 1).style.bg);
        var terminal: vaxis.Screen = .{ .width = width, .height = height, .width_method = .unicode, .buf = try arena.allocator().alloc(vaxis.Cell, @as(usize, width) * height) };
        @memset(terminal.buf, .{});
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &terminal };
        surface.render(window, input.composer.widget());
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
        var overview: Overview = .{ .content = &list, .input = &input, .userdata = &list, .on_event = Row.event };
        var facade: Content = .{ .shown = transcript.widget() };
        var session: Session = .{ .content = &facade, .input = &input, .userdata = &transcript, .on_event = Row.event };
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
                const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = height }, .cell_size = .{} };
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
