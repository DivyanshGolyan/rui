const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

pub const Events = struct {
    parser: vaxis.Parser = .{},
    bytes: []const u8,
    at: usize = 0,
    pasting: bool = false,

    pub fn init(bytes: []const u8) Events {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Events) ?vxfw.Event {
        while (self.at < self.bytes.len) {
            const result = self.parser.parse(self.bytes[self.at..], null) catch return null;
            if (result.n == 0) return null;
            self.at += result.n;
            const event: vxfw.Event = switch (result.event orelse continue) {
                .key_press => |key| .{ .key_press = key },
                .key_release => |key| .{ .key_release = key },
                .paste_start => .paste_start,
                .paste_end => .paste_end,
                .focus_in => .focus_in,
                .focus_out => .focus_out,
                else => continue,
            };
            switch (event) {
                .paste_start => self.pasting = true,
                .paste_end => self.pasting = false,
                else => {},
            }
            return event;
        }
        return null;
    }
};

pub fn send(ctx: *vxfw.EventContext, bytes: []const u8, root: vxfw.Widget, focused: vxfw.Widget) !void {
    var events: Events = .init(bytes);
    while (!ctx.quit) {
        const event = events.next() orelse return;
        ctx.consume_event = false;
        ctx.phase = .capturing;
        try root.captureEvent(ctx, event);
        if (ctx.consume_event) continue;
        ctx.phase = .at_target;
        try focused.handleEvent(ctx, event);
    }
}

pub fn mouse(ctx: *vxfw.EventContext, frame: vxfw.Surface, report: vaxis.Mouse) !void {
    var hits: std.ArrayList(vxfw.HitResult) = .empty;
    defer hits.deinit(ctx.alloc);
    if (report.row < 0 or report.col < 0 or report.row >= frame.size.height or report.col >= frame.size.width) return;
    try frame.hitTest(ctx.alloc, &hits, .{ .row = @intCast(report.row), .col = @intCast(report.col) });
    const target = hits.pop() orelse return;
    ctx.consume_event = false;
    ctx.phase = .capturing;
    for (hits.items) |hit| {
        try hit.widget.captureEvent(ctx, .{ .mouse = local(report, hit) });
        if (ctx.consume_event) return;
    }
    ctx.phase = .at_target;
    try target.widget.handleEvent(ctx, .{ .mouse = local(report, target) });
    if (ctx.consume_event) return;
    ctx.phase = .bubbling;
    while (hits.pop()) |hit| {
        try hit.widget.handleEvent(ctx, .{ .mouse = local(report, hit) });
        if (ctx.consume_event) return;
    }
}

fn local(report: vaxis.Mouse, hit: vxfw.HitResult) vaxis.Mouse {
    var moved = report;
    moved.col = @intCast(hit.local.col);
    moved.row = @intCast(hit.local.row);
    return moved;
}
