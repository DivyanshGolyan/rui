//! Shared screen composition. The overview and Session keep their own workers
//! and input policy; this owner places content above input, facts and status.
const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const InputArea = @import("InputArea.zig");

pub const Overview = Screen(@import("GroupedList.zig"));
pub const Session = Screen(@import("Transcript.zig"));

fn Screen(comptime Content: type) type {
    return struct {
        const Self = @This();

        content: *Content,
        input: *InputArea,
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

        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *Self = @ptrCast(@alignCast(raw));
            const size = ctx.max.size();
            if (size.width == 0 or size.height == 0) return .empty(self.widget());
            const children = try ctx.arena.alloc(vxfw.SubSurface, 6);
            var used: usize = 0;
            const input = try self.input.widget().draw(ctx.withConstraints(.{}, ctx.max));
            const input_row = size.height - input.size.height;
            var top: u16 = 0;
            if (self.header) |header| {
                const drawn = try header.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = input_row }));
                children[used] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = drawn };
                used += 1;
                top = drawn.size.height;
            }
            const above_input: vxfw.MaxSize = .{ .width = size.width, .height = input_row - top };
            var content_end = input_row;
            if (self.tail) |tail| {
                const drawn = try tail.draw(ctx.withConstraints(.{}, above_input));
                content_end -= drawn.size.height;
                children[used] = .{ .origin = .{ .row = content_end, .col = 0 }, .surface = drawn };
                used += 1;
            }
            const content_max: vxfw.MaxSize = .{ .width = size.width, .height = content_end - top };
            children[used] = .{ .origin = .{ .row = top, .col = 0 }, .surface = try self.content.widget().draw(ctx.withConstraints(.{}, content_max)) };
            used += 1;
            children[used] = .{ .origin = .{ .row = input_row, .col = 0 }, .surface = input };
            used += 1;
            if (content_end > top) if (self.marker) |marker| {
                const drawn = try marker.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 }));
                children[used] = .{ .origin = .{ .row = content_end - 1, .col = size.width - drawn.size.width }, .surface = drawn, .z_index = 1 };
                used += 1;
            };
            if (self.overlay) |overlay| {
                const drawn = try overlay.draw(ctx.withConstraints(.{}, above_input));
                children[used] = .{ .origin = .{ .row = input_row - drawn.size.height, .col = 0 }, .surface = drawn, .z_index = 2 };
                used += 1;
            }
            return .{ .widget = self.widget(), .size = size, .buffer = &.{}, .children = children[0..used] };
        }
    };
}

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
        try std.testing.expectEqual(@as(usize, 3), drawn.children.len);
        try std.testing.expectEqual(@as(i17, 19), drawn.children[1].origin.row);
        try std.testing.expectEqual(@as(i17, 18), drawn.children[2].origin.row);
        try std.testing.expect(drawn.children[1].surface.widget.eql(input.widget()));
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
    try std.testing.expectEqual(@as(usize, 6), active.children.len);
    try std.testing.expectEqual(@as(i17, 17), active.children[1].origin.row);
    try std.testing.expectEqual(@as(u16, 16), active.children[2].surface.size.height);
    try std.testing.expectEqual(@as(i17, 19), active.children[3].origin.row);
    try std.testing.expectEqual(vxfw.RelativePoint{ .row = 16, .col = 78 }, active.children[4].origin);
    try std.testing.expectEqual(@as(u8, 1), active.children[4].z_index);
    try std.testing.expectEqual(@as(u8, 2), active.children[5].z_index);
    session.tail = null;
    const browsing = try session.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 18), browsing.children[1].surface.size.height);
    try std.testing.expectEqual(vxfw.RelativePoint{ .row = 18, .col = 78 }, browsing.children[3].origin);
    for ([_]vxfw.Size{ .{ .width = 1, .height = 1 }, .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 0 } }) |size| {
        const tiny = try session.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height }));
        try std.testing.expect(tiny.size.width <= size.width and tiny.size.height <= size.height);
        for (tiny.children) |child| try std.testing.expect(child.z_index != 1);
    }
}
