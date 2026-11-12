//! Pointer-only row feedback shared by lists and panels. Rectangles are the
//! latest frame's clipped click regions; hovering never owns selection or focus.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Self = @This();

pub const Rect = struct {
    row: i17,
    col: i17 = 0,
    width: u16,
    height: u16 = 1,

    pub fn contains(self: Rect, col: i17, row: i17) bool {
        return col >= self.col and col < self.col + self.width and row >= self.row and row < self.row + self.height;
    }
};

const Point = struct { col: i17, row: i17 };
point: ?Point = null,
pointing: bool = false,
/// Borrowed from the latest frame arena and replaced by its next draw.
targets: []const Rect = &.{},

pub fn contains(self: *const Self, rect: Rect) bool {
    const point = self.point orelse return false;
    return rect.contains(point.col, point.row);
}

pub fn handleEvent(self: *Self, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const previous = self.point;
    switch (input) {
        .mouse => |mouse| self.point = .{ .col = mouse.col, .row = mouse.row },
        .mouse_leave => self.point = null,
        .mouse_enter => return, // The following mouse report supplies coordinates.
        else => return,
    }
    if (!std.meta.eql(previous, self.point)) ctx.redraw = true;
    const pointing = for (self.targets) |rect| {
        if (self.contains(rect)) break true;
    } else false;
    if (pointing != self.pointing) {
        self.pointing = pointing;
        try ctx.setMouseShape(if (pointing) .pointer else .default);
    }
}
