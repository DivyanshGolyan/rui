//! Pointer-only row feedback shared by lists and panels. Rectangles are the
//! latest frame's clipped click regions; hovering never owns selection or focus.
//!
//! `targets` borrows the frame arena of this widget's latest draw, so it is
//! read only while handling a `.mouse` event: vxfw delivers one (or a parent
//! forwards it from its own hit) only to widgets drawn in the frame it
//! hit-tested, so that frame's arena is still live. `.mouse_leave` also
//! reaches widgets from an older hit list whose frame arena may be gone, so it
//! never reads `targets`; it only forgets the point and restores the default
//! pointer. The borrow itself stays: a press can follow the leave against the
//! same frame before any redraw, and callers' click regions are these targets.
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

/// `style` under the pointer: of `hover` only its background, reverse and
/// underline apply, so the drawn foreground stays.
pub fn look(style: vaxis.Style, hover: vaxis.Style) vaxis.Style {
    var drawn = style;
    drawn.bg = hover.bg;
    drawn.reverse = hover.reverse;
    drawn.ul_style = hover.ul_style;
    return drawn;
}

/// A chip's hover look: its own style, underlined.
pub fn underlined(style: vaxis.Style) vaxis.Style {
    var drawn = style;
    drawn.ul_style = .single;
    return drawn;
}

const Point = struct { col: i17, row: i17 };
point: ?Point = null,
pointing: bool = false,
/// Borrowed from the latest frame arena and replaced by its next draw; read
/// only during `.mouse` (see the file comment).
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
            // The frame these targets came from may already be freed.
            self.point = null;
            break :leave false;
        },
        .mouse_enter => return, // The following mouse report supplies coordinates.
        else => return,
    };
    if (!std.meta.eql(previous, self.point)) ctx.redraw = true;
    if (pointing != self.pointing) {
        self.pointing = pointing;
        try ctx.setMouseShape(if (pointing) .pointer else .default);
    }
}
