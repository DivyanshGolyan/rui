//! The conversation shell's bounded pending-message list. The native ListView
//! owns its only cursor and viewport; Host reads happen outside its builder.
const std = @import("std");
const vaxis = @import("vaxis");
const reads = @import("session_reads.zig");
const protocol = @import("protocol.zig");

const Self = @This();
pub const Direction = @FieldType(protocol.ActivityPage, "direction");
pub const Request = struct { snapshot: reads.QueueSnapshot, position: u64 = 0, direction: Direction = .forward };

list: vaxis.vxfw.ListView = .{ .children = .{ .slice = &.{} }, .item_count = 0, .draw_cursor = false },
snapshot: ?reads.QueueSnapshot = null,
page: reads.QueuePage = .{},
wanted: ?Request = null,
busy: bool = false,
focused: bool = false,
/// The last successfully delivered frame, not a speculative layout.
visible: bool = false,

/// Applying a new authoritative snapshot revokes the old rows immediately.
/// A completed read may publish only against the exact frozen snapshot.
pub fn observe(self: *Self, snapshot: reads.QueueSnapshot) void {
    // Queue membership is an admission-order suffix: unchanged authoritative
    // count and ends retain the exact membership even if unrelated activity
    // advances the Activity boundary (QueuedMessages in store/domain/reads).
    if (self.snapshot != null and std.meta.eql(self.snapshot.?.queued, snapshot.queued)) return;
    self.snapshot = snapshot;
    self.page = .{};
    self.list.item_count = 0;
    self.list.jumpToItem(0);
    self.visible = false;
    self.focused = false;
    self.wanted = if (snapshot.queued.count != 0) .{ .snapshot = snapshot } else null;
}

pub fn publish(self: *Self, request: Request, page: reads.QueuePage) bool {
    const current = self.snapshot orelse return false;
    if (!std.meta.eql(current, request.snapshot) or (current.queued.count != 0 and page.len == 0)) return false;
    // Until the replacement frame is flushed, old visible rows cannot grant
    // input authority over this newly joined page.
    self.visible = false;
    self.page = page;
    self.list.item_count = @intCast(page.len);
    const index: usize = if (request.direction == .backward and page.len != 0) page.len - 1 else 0;
    self.list.jumpToItem(@intCast(index));
    return true;
}

/// A page edge requests the next bounded window; the pending selection is
/// carried by the direction, never by a second cursor or copied offset.
pub fn move(self: *Self, allocator: std.mem.Allocator, direction: Direction) void {
    if (self.page.len == 0 or self.wanted != null or self.busy) return;
    const edge = if (direction == .forward) self.list.cursor + 1 >= self.page.len else self.list.cursor == 0;
    if (edge) {
        const more = if (direction == .forward) self.page.newer else self.page.older;
        if (more) {
            const position = if (direction == .forward) self.page.entries[self.page.len - 1].position else self.page.entries[0].position;
            self.wanted = .{ .snapshot = self.snapshot.?, .position = position, .direction = direction };
        }
        return;
    }
    var context: vaxis.vxfw.EventContext = .{ .io = undefined, .alloc = allocator, .cmds = .empty };
    if (direction == .forward) self.list.nextItem(&context) else self.list.prevItem(&context);
}

test "new queue snapshots revoke old rows and stale replies cannot publish" {
    var self: Self = .{};
    const old: reads.QueueSnapshot = .{ .boundary = 7, .queued = .{ .count = 1, .oldest_position = 3, .newest_position = 3, .newest_admission = 4 } };
    self.observe(old);
    const request = self.wanted.?;
    self.wanted = null;
    var page: reads.QueuePage = .{};
    page.entries[0] = .{ .admission = 4, .position = 3, .line = .{} };
    page.len = 1;
    try std.testing.expect(self.publish(request, page));
    self.visible = true;
    self.focused = true;
    self.observe(.{ .boundary = 8, .queued = .{} });
    try std.testing.expectEqual(@as(usize, 0), self.page.len);
    try std.testing.expect(!self.visible and !self.focused and self.wanted == null);
    try std.testing.expect(!self.publish(request, page));
}

test "queue edge requests a bounded page at the native cursor" {
    var self: Self = .{};
    const snapshot: reads.QueueSnapshot = .{ .boundary = 50, .queued = .{ .count = 3, .oldest_position = 2, .newest_position = 9, .newest_admission = 3 } };
    self.observe(snapshot);
    const initial = self.wanted.?;
    self.wanted = null;
    var page: reads.QueuePage = .{ .len = 2, .newer = true };
    page.entries[0] = .{ .admission = 1, .position = 2, .line = .{} };
    page.entries[1] = .{ .admission = 2, .position = 5, .line = .{} };
    try std.testing.expect(self.publish(initial, page));
    self.move(std.testing.allocator, .forward);
    self.move(std.testing.allocator, .forward);
    try std.testing.expectEqual(@as(u64, 5), self.wanted.?.position);
    try std.testing.expectEqual(Direction.forward, self.wanted.?.direction);
}

/// Paint only the allocated inline region. The first row is the focus hint;
/// the native ListView builds fixed-height children in the charged frame arena.
pub fn draw(self: *Self, window: vaxis.Window, arena: std.mem.Allocator, method: vaxis.gwidth.Method, quiet: vaxis.Style, available: bool) !void {
    const header = window.child(.{ .height = 1 });
    _ = header.printSegment(.{ .text = if (!available) "Pending" else if (self.focused) (if (window.width >= 13) "↑↓ move · Esc" else "↑↓ Esc") else if (window.width >= 14) "Pending: Alt-Q" else "Alt-Q", .style = quiet }, .{ .wrap = .none });
    if (window.height < 2 or self.page.len == 0) return;
    var rows: Rows = .{ .owner = self, .method = method, .quiet = quiet, .available = available };
    self.list.children = .{ .builder = .{ .userdata = &rows, .buildFn = Rows.build } };
    defer self.list.children = .{ .slice = &.{} };
    const height = window.height - 1;
    const surface = try self.list.draw(.{ .arena = arena, .min = .{}, .max = .{ .width = window.width, .height = height }, .cell_size = .{} });
    surface.render(window.child(.{ .y_off = 1, .height = height }), self.list.widget());
}

const Rows = struct {
    owner: *Self,
    method: vaxis.gwidth.Method,
    quiet: vaxis.Style,
    available: bool,
    index: usize = 0,
    selected: bool = false,

    fn build(raw: *const anyopaque, index: usize, cursor: usize) ?vaxis.vxfw.Widget {
        const self: *Rows = @ptrCast(@alignCast(@constCast(raw)));
        if (index >= self.owner.page.len) return null;
        self.index = index;
        self.selected = index == cursor and self.owner.focused and self.available;
        return .{ .userdata = self, .drawFn = Rows.draw };
    }

    fn draw(raw: *anyopaque, context: vaxis.vxfw.DrawContext) std.mem.Allocator.Error!vaxis.vxfw.Surface {
        const self: *Rows = @ptrCast(@alignCast(raw));
        const width = context.max.width.?;
        const widget: vaxis.vxfw.Widget = .{ .userdata = self, .drawFn = Rows.draw };
        const surface = try vaxis.vxfw.Surface.init(context.arena, widget, .{ .width = width, .height = 1 });
        var screen: vaxis.Screen = .{ .width = width, .height = 1, .width_method = self.method, .buf = surface.buffer };
        const window: vaxis.Window = .{ .screen = &screen, .width = width, .height = 1, .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0 };
        var style = self.quiet;
        style.reverse = self.selected;
        window.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
        // The admission identity keeps duplicate previews distinguishable,
        // including when paging leaves only one row on screen.
        const entry = &self.owner.page.entries[self.index];
        const prefix = try std.fmt.allocPrint(context.arena, "{s}{d} ", .{ if (self.selected) "› " else "  ", entry.admission });
        const mark = window.printSegment(.{ .text = prefix, .style = style }, .{ .wrap = .none });
        _ = window.child(.{ .x_off = mark.col }).printSegment(.{ .text = entry.line.slice(), .style = style }, .{ .wrap = .none });
        return surface;
    }
};

test "unchanged membership retains an in-flight pinned page across unrelated activity" {
    var self: Self = .{};
    const first: reads.QueueSnapshot = .{ .boundary = 10, .queued = .{ .count = 1, .oldest_position = 3, .newest_position = 3, .newest_admission = 4 } };
    self.observe(first);
    const request = self.wanted.?;
    self.wanted = null;
    self.busy = true;
    self.observe(.{ .boundary = 20, .queued = first.queued });
    try std.testing.expectEqual(first.boundary, self.snapshot.?.boundary);
    var page: reads.QueuePage = .{ .len = 1 };
    page.entries[0] = .{ .admission = 4, .position = 3, .line = .{} };
    try std.testing.expect(self.publish(request, page));
    self.observe(.{ .boundary = 21, .queued = .{} });
    try std.testing.expect(!self.publish(request, page));
    try std.testing.expectEqual(@as(usize, 0), self.page.len);
}

test "bounded forward and backward page edges keep admission identity" {
    var self: Self = .{};
    const snapshot: reads.QueueSnapshot = .{ .boundary = 40, .queued = .{ .count = 5, .oldest_position = 2, .newest_position = 10, .newest_admission = 5 } };
    self.observe(snapshot);
    var request = self.wanted.?;
    self.wanted = null;
    var first: reads.QueuePage = .{ .len = 2, .newer = true };
    first.entries[0] = .{ .admission = 1, .position = 2, .line = .{} };
    first.entries[1] = .{ .admission = 2, .position = 4, .line = .{} };
    var middle: reads.QueuePage = .{ .len = 2, .older = true, .newer = true };
    middle.entries[0] = .{ .admission = 3, .position = 6, .line = .{} };
    middle.entries[1] = .{ .admission = 4, .position = 8, .line = .{} };
    var last: reads.QueuePage = .{ .len = 1, .older = true };
    last.entries[0] = .{ .admission = 5, .position = 10, .line = .{} };
    try std.testing.expect(self.publish(request, first));
    self.move(std.testing.allocator, .forward);
    self.move(std.testing.allocator, .forward);
    request = self.wanted.?;
    try std.testing.expectEqual(@as(u64, 4), request.position);
    self.wanted = null;
    try std.testing.expect(self.publish(request, middle));
    try std.testing.expectEqual(@as(u64, 3), self.page.entries[self.list.cursor].admission);
    self.move(std.testing.allocator, .forward);
    self.move(std.testing.allocator, .forward);
    request = self.wanted.?;
    try std.testing.expectEqual(@as(u64, 8), request.position);
    self.wanted = null;
    try std.testing.expect(self.publish(request, last));
    try std.testing.expectEqual(@as(u64, 5), self.page.entries[self.list.cursor].admission);
    self.move(std.testing.allocator, .backward);
    request = self.wanted.?;
    try std.testing.expectEqual(@as(u64, 10), request.position);
    self.wanted = null;
    try std.testing.expect(self.publish(request, middle));
    try std.testing.expectEqual(@as(u64, 4), self.page.entries[self.list.cursor].admission);
    self.move(std.testing.allocator, .backward);
    self.move(std.testing.allocator, .backward);
    request = self.wanted.?;
    try std.testing.expectEqual(@as(u64, 6), request.position);
    self.wanted = null;
    try std.testing.expect(self.publish(request, first));
    try std.testing.expectEqual(@as(u64, 2), self.page.entries[self.list.cursor].admission);
}
