//! Shared screen composition. The overview and Session keep their own workers
//! and input policy; this owner places content above input, facts and status.
const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const InputArea = @import("InputArea.zig");
const Stack = @import("widgets/Stack.zig");
const Layer = @import("widgets/Layer.zig");

pub const Overview = Screen(@import("GroupedList.zig"));
pub const Session = Screen(@import("Transcript.zig"));

fn Screen(comptime Content: type) type {
    return struct {
        const Self = @This();

        content: *Content,
        input: *InputArea,
        style: @import("vaxis").Style = .{},
        header: ?vxfw.Widget = null,
        tail: ?vxfw.Widget = null,
        marker: ?vxfw.Widget = null,
        overlay: ?vxfw.Widget = null,
        userdata: *anyopaque,
        on_event: *const fn (*anyopaque, *vxfw.EventContext, vxfw.Event) anyerror!void,

        pub fn widget(self: *Self) vxfw.Widget {
            return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
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
            const size = ctx.max.size();
            if (size.width == 0 or size.height == 0) return .empty(self.widget());
            // Nest columns to retain the existing height priority: input,
            // header, tail, marker, then the remaining content.
            const lower = try ctx.arena.create(Stack);
            const lower_children = try ctx.arena.alloc(Stack.Child, 3);
            var count: usize = 1;
            lower_children[0] = .{ .widget = self.content.widget(), .sizing = .fill };
            if (self.marker) |marker| {
                const row = try ctx.arena.create(Marker);
                row.* = .{ .child = marker };
                lower_children[count] = .{ .widget = row.widget() };
                count += 1;
            }
            if (self.tail) |tail| {
                lower_children[count] = .{ .widget = tail };
                count += 1;
            }
            lower.* = .{ .children = lower_children[0..count] };
            const upper = try ctx.arena.create(Stack);
            const upper_children = try ctx.arena.alloc(Stack.Child, 2);
            count = 0;
            if (self.header) |header| {
                upper_children[count] = .{ .widget = header };
                count += 1;
            }
            upper_children[count] = .{ .widget = lower.widget(), .sizing = .fill };
            upper.* = .{ .children = upper_children[0 .. count + 1] };
            const column = try ctx.arena.create(Stack);
            column.* = .{ .children = try ctx.arena.dupe(Stack.Child, &.{
                .{ .widget = upper.widget(), .sizing = .fill },
                .{ .widget = self.input.widget() },
            }) };
            const base = try column.widget().draw(ctx);
            const panels = try ctx.arena.alloc(Layer.Panel, if (self.overlay != null) 1 else 0);
            if (self.overlay) |overlay| panels[0] = .{
                .child = overlay,
                .bottom = @intCast(base.children[1].origin.row),
                .top = if (self.header != null and base.children[1].origin.row > 0) base.children[0].surface.children[0].surface.size.height else 0,
                .style = self.style,
                .userdata = self,
                .on_close = closeOverlay,
            };
            const layer = try ctx.arena.create(Layer);
            layer.* = .{ .base = column.widget(), .panels = panels };
            var surface = try layer.drawAbove(ctx, base);
            // Existing screen policy still owns events; only composition moves
            // here. The shell will route captured panel events in its next unit.
            surface.widget = self.widget();
            surface.buffer = try vxfw.Surface.createBuffer(ctx.arena, size);
            @memset(surface.buffer, .{ .style = self.style });
            return surface;
        }
    };
}

const Marker = struct {
    child: vxfw.Widget,

    fn widget(self: *Marker) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Marker = @ptrCast(@alignCast(raw));
        const width = ctx.max.width.?;
        if (width == 0 or ctx.max.height.? == 0) return .empty(self.widget());
        var row = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = 1 });
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
    var transcript: @import("Transcript.zig") = .{ .document = document };
    var events: usize = 0;
    const Handler = struct {
        fn event(raw: *anyopaque, _: *vxfw.EventContext, _: vxfw.Event) !void {
            const count: *usize = @ptrCast(@alignCast(raw));
            count.* += 1;
        }
    };
    var overview: Overview = .{ .content = &list, .input = &input, .userdata = &events, .on_event = Handler.event };
    var session: Session = .{ .content = &transcript, .input = &input, .userdata = &events, .on_event = Handler.event };
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
        try std.testing.expectEqual(@as(i17, 19), column.children[1].origin.row);
        try std.testing.expectEqual(@as(i17, 18), drawn.children[1].origin.row);
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
    try std.testing.expectEqual(@as(i17, 17), lower.origin.row + lower.surface.children[2].origin.row);
    // The marker owns a whole row above the tail; the content ends above it.
    const marker_row = lower.surface.children[1];
    try std.testing.expectEqual(vxfw.RelativePoint{ .row = 16, .col = 0 }, vxfw.RelativePoint{ .row = lower.origin.row + marker_row.origin.row, .col = marker_row.origin.col });
    try std.testing.expectEqual(@as(u16, 80), marker_row.surface.size.width);
    try std.testing.expectEqual(@as(i17, 78), marker_row.surface.children[0].origin.col);
    try std.testing.expectEqual(@as(u8, 1), marker_row.surface.children[0].z_index);
    try std.testing.expectEqual(@as(u16, 15), lower.surface.children[0].surface.size.height);
    try std.testing.expectEqual(@as(i17, 19), column.children[1].origin.row);
    try std.testing.expectEqual(@as(u8, 2), active.children[1].z_index);
    session.tail = null;
    const browsing = try session.widget().draw(ctx);
    const browsing_lower = browsing.children[0].surface.children[0].surface.children[1];
    const browsing_marker = browsing_lower.surface.children[1];
    try std.testing.expectEqual(vxfw.RelativePoint{ .row = 18, .col = 0 }, vxfw.RelativePoint{ .row = browsing_lower.origin.row + browsing_marker.origin.row, .col = browsing_marker.origin.col });
    try std.testing.expectEqual(@as(u16, 17), browsing_lower.surface.children[0].surface.size.height);
    for ([_]vxfw.Size{ .{ .width = 1, .height = 1 }, .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 0 } }) |size| {
        const tiny = try session.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height }));
        try std.testing.expect(tiny.size.width <= size.width and tiny.size.height <= size.height);
        for (tiny.children) |child| try std.testing.expect(child.z_index != 1);
    }
}

test "App screens render the same cells as the original composition" {
    const vaxis = @import("vaxis");
    const Content = struct {
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
    var content: Content = .{};
    var screen: Screen(Content) = .{ .content = &content, .input = &input, .userdata = &content, .on_event = Content.event, .style = .{ .bg = .{ .index = 4 } } };
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
        for (terminal.buf) |cell| {
            hash.update(cell.char.grapheme);
            std.hash.autoHash(&hash, cell.char.width);
            std.hash.autoHash(&hash, cell.style);
        }
    };
    // Captured from c347313's composition, across all optional rows and tiny,
    // narrow and wide terminals. Hash visible graphemes, widths and styles.
    try std.testing.expectEqual(@as(u64, 13927979314281808809), hash.final());
}
