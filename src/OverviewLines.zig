//! The overview's header: the counts line and any provider band
//! under it, as `overview_view.header` decides them each frame. A left
//! press on the counts line's view name, which shows only off the default
//! view, is the core's `.view` click.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const overview_view = @import("overview_view.zig");
const widget_style = @import("widget_style.zig");

pub const Header = struct {
    state: *const overview_view.State,
    caps: overview_view.Caps = .{},
    userdata: *anyopaque,
    on_click: *const fn (*anyopaque, *vxfw.EventContext, overview_view.Click) anyerror!void,
    /// Where the last frame drew the view name: plain data, kept for the
    /// press that frame's hit test sends here.
    view: ?struct { start: u16, end: u16 } = null,

    pub fn widget(self: *Header) vxfw.Widget {
        return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
    }

    fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) anyerror!void {
        const self: *Header = @ptrCast(@alignCast(raw));
        const mouse = switch (input) {
            .mouse => |mouse| mouse,
            else => return,
        };
        if (mouse.button != .left or mouse.type != .press or mouse.row != 0) return;
        const view = self.view orelse return;
        if (mouse.col < view.start or mouse.col >= view.end) return;
        try self.on_click(self.userdata, ctx, .view);
        ctx.consumeAndRedraw();
    }

    fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Header = @ptrCast(@alignCast(raw));
        const width = ctx.max.width orelse 0;
        const lines = try overview_view.header(ctx.arena, self.state, width, self.caps);
        self.view = if (lines.view) |view| .{ .start = view.start, .end = view.end } else null;
        const spans = try ctx.arena.alloc(vaxis.Segment, lines.segments.len);
        for (lines.segments, spans) |segment, *span| span.* = .{ .text = segment.text, .style = widget_style.of(self.caps, segment.style) };
        const text: vxfw.RichText = .{ .text = spans, .softwrap = false, .width_basis = .parent };
        var surface = try text.draw(ctx.withConstraints(.{ .width = width }, ctx.max));
        surface.widget = self.widget();
        return surface;
    }
};

fn cells(arena: std.mem.Allocator, surface: vxfw.Surface, row: u16) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (0..surface.size.width) |column| try text.appendSlice(arena, surface.readCell(@intCast(column), row).char.grapheme);
    return text.items;
}

const Clicks = struct {
    got: ?overview_view.Click = null,
    fn take(raw: *anyopaque, _: *vxfw.EventContext, click: overview_view.Click) anyerror!void {
        const self: *Clicks = @ptrCast(@alignCast(raw));
        self.got = click;
    }
};

test "the header keeps Host words out and only a press on the view name is the view click" {
    var state: overview_view.State = undefined;
    try state.init(std.testing.allocator, .{ .cwd = "/w", .home = "/h" });
    defer state.deinit();
    var clicks: Clicks = .{};
    const caps: overview_view.Caps = .{ .unicode = false };
    var header: Header = .{ .state = &state, .caps = caps, .userdata = &clicks, .on_click = Clicks.take };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 50, .height = 6 }, .cell_size = .{} };
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const press = struct {
        fn at(column: i16, row: i16) vxfw.Event {
            return .{ .mouse = .{ .col = column, .row = row, .button = .left, .type = .press, .mods = .{} } };
        }
    }.at;

    // The default view names nothing, so no press is a click.
    const plain = try header.widget().draw(ctx);
    try std.testing.expectEqual(vxfw.Size{ .width = 50, .height = 1 }, plain.size);
    try std.testing.expect(std.mem.startsWith(u8, try cells(arena.allocator(), plain, 0), " rui"));
    try std.testing.expect(plain.widget.eql(header.widget()));
    try header.widget().handleEvent(&events, press(45, 0));
    try std.testing.expectEqual(null, clicks.got);

    // A failed listing adds no Host band to the header.
    state.archive = .archived;
    state.list_stale = true;
    const banded = try header.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 1), banded.size.height);
    const text = try cells(arena.allocator(), banded, 0);
    try std.testing.expectEqualStrings("Archived ", text[41..]);
    try std.testing.expect(std.mem.indexOf(u8, text, "Host stopped") == null);
    // Beside the name, after it, and below the header are not the name.
    for ([_][2]i16{ .{ 40, 0 }, .{ 49, 0 }, .{ 44, 1 } }) |at| try header.widget().handleEvent(&events, press(at[0], at[1]));
    try std.testing.expectEqual(null, clicks.got);
    try std.testing.expect(!events.consume_event);
    try header.widget().handleEvent(&events, press(44, 0));
    try std.testing.expectEqual(overview_view.Click.view, clicks.got.?);
    try std.testing.expect(events.consume_event);
}
