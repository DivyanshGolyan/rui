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

pub fn look(style: vaxis.Style, hover: vaxis.Style) vaxis.Style {
    var drawn = style;
    drawn.bg = hover.bg;
    drawn.reverse = hover.reverse;
    drawn.ul_style = hover.ul_style;
    return drawn;
}

pub fn underlined(style: vaxis.Style) vaxis.Style {
    var drawn = style;
    drawn.ul_style = .single;
    return drawn;
}

const Point = struct { col: i17, row: i17 };
point: ?Point = null,
pointing: bool = false,
targets: []const Rect = &.{},

pub fn contains(self: *const Self, rect: Rect) bool {
    const point = self.point orelse return false;
    return rect.contains(point.col, point.row);
}

pub fn handleEvent(self: *Self, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const previous = self.point;
    const pointing = switch (input) {
        .mouse => |mouse| pointing: {
            self.point = .{ .col = mouse.col, .row = mouse.row };
            break :pointing for (self.targets) |rect| {
                if (self.contains(rect)) break true;
            } else false;
        },
        .mouse_leave => leave: {
            self.point = null;
            break :leave false;
        },
        .mouse_enter => return,
        else => return,
    };
    if (!std.meta.eql(previous, self.point)) ctx.redraw = true;
    if (pointing != self.pointing) {
        self.pointing = pointing;
        try ctx.setMouseShape(if (pointing) .pointer else .default);
    }
}
