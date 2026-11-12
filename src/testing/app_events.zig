//! The bytes a terminal sends, delivered to a screen as App delivers them:
//! vaxis's own Parser decodes them, Root's capture sees each event first,
//! and the focused screen gets what Root leaves unconsumed.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

/// The events vaxis's Parser decodes from `bytes`, in order, with Root's
/// paste flag: set from a paste's start through its end. A malformed
/// sequence ends them, as App's loop discards one; an incomplete tail is
/// dropped.
pub const Events = struct {
    parser: vaxis.Parser = .{},
    bytes: []const u8,
    at: usize = 0,
    /// Root's flag for the event `next` last returned.
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
                .invalid_key => .invalid_key,
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

/// Delivers each complete event in `bytes`, in order, through `root`'s
/// capture and then to `focused`.
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

/// A mouse report delivered as App delivers it: hit-tested against the
/// frame `frame` drew, through each hit widget's capture, then the deepest
/// hit, then back up the hits until one consumes it.
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
