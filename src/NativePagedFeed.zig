//! A bounded page of authenticated source, with framework-owned text geometry.
//! The caller transfers the whole owner across a joined worker boundary. No
//! source or widget borrows a running worker or a transient page buffer.
const std = @import("std");
const vaxis = @import("vaxis");
const fw = vaxis.vxfw;
const client = @import("client.zig");
const observations = @import("NativeObservations.zig");
const protocol = @import("protocol.zig");
const replies = @import("protocol_reply.zig");
const feed = @import("NativeFeed.zig");
const Self = @This();

const Item = struct {
    source: feed.VerifiedSource,
    reader: vaxis.unicode.PagedReader,
    index: fw.PagedText.Index,
};

pub const Anchor = struct {
    instance: protocol.InstanceId,
    session: [protocol.session_id_bytes]u8,
    position: u64,
    ordinal: u64,
    reference: protocol.ActivityItem.Content,
    /// Null addresses the speaker label rather than display content.
    source: ?client.VerifiedContentScratch.SourceAnchor,
};

allocator: std.mem.Allocator,
page: observations.SourcePage,
items: [protocol.ActivityPage.items]*Item = undefined,
count: usize = 0,
row_count: u32 = 0,
width: u16,

/// Load at most one authoritative Activity page. Each selected Message is
/// held in two unlinked files (exact verified and terminal-safe projection).
/// Total temporary disk is their combined sizes; no content lives in an arena.
pub fn load(allocator: std.mem.Allocator, requests: client.Requests, dir: std.Io.Dir, store: []const u8, session: *const [protocol.session_id_bytes]u8, cursor: replies.ActivityCursor, instance: ?protocol.InstanceId, width: u16) !*Self {
    if (width == 0) return error.InvalidWidth;
    const page = try observations.sourcePage(requests, store, session, cursor, instance);
    const self = try allocator.create(Self);
    self.* = .{ .allocator = allocator, .page = page, .width = width };
    errdefer self.destroy();
    const ctx: fw.DrawContext = .{ .arena = allocator, .min = .{ .width = width }, .max = .{ .width = width, .height = null }, .cell_size = .{} };
    for (0..page.count) |i| {
        const page_index = if (page.direction == .backward) page.count - 1 - i else i;
        const item = try allocator.create(Item);
        errdefer allocator.destroy(item);
        item.source = try feed.VerifiedSource.open(allocator, requests, dir, store, &self.page, page_index);
        errdefer item.source.close();
        item.reader = .{ .source = try item.source.pagedSource() };
        item.index = try fw.PagedText.Index.init(&item.reader, ctx, width);
        const added = try std.math.add(usize, item.index.len, 1);
        const total = try std.math.add(usize, self.row_count, added);
        self.row_count = std.math.cast(u32, total) orelse return error.TooManyRows;
        // No reference to the worker's cancellation token crosses publication.
        item.source.cancellation = null;
        self.items[self.count] = item;
        self.count += 1;
    }
    try observations.ensureServing(requests.io, store, self.page.instance);
    return self;
}

pub fn destroy(self: *Self) void {
    const allocator = self.allocator;
    for (self.items[0..self.count]) |item| {
        item.source.close();
        allocator.destroy(item);
    }
    allocator.destroy(self);
}

pub fn builder(self: *Self) fw.ScrollView.Builder {
    return .{ .userdata = self, .hasFn = hasRow, .buildFrameFn = drawRow };
}

fn hasRow(raw: *const anyopaque, row: usize, _: usize) bool {
    const self: *const Self = @ptrCast(@alignCast(raw));
    return row < self.row_count;
}

const Location = struct { item: *Item, row: ?usize };

fn locate(self: *const Self, row: usize) ?Location {
    var remaining = row;
    for (self.items[0..self.count]) |item| {
        if (remaining == 0) return .{ .item = item, .row = null };
        remaining -= 1;
        if (remaining < item.index.len) return .{ .item = item, .row = remaining };
        remaining -= item.index.len;
    }
    return null;
}

fn drawRow(raw: *const anyopaque, row: usize, cursor: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!?fw.Widget {
    const self: *Self = @ptrCast(@alignCast(@constCast(raw)));
    const location = self.locate(row) orelse return null;
    if (location.row) |line| return location.item.index.builder().itemAtIdxForDraw(line, cursor, arena);
    const label = try arena.create(fw.Text);
    label.* = .{ .text = if (location.item.source.item.kind == .user) "You" else "Assistant", .softwrap = false };
    return label.widget();
}

/// Capture the exact source identity and a raw-source span for a visual row.
/// Mapping can scan the source prefix and should be run off the UI thread.
pub fn anchorAt(self: *const Self, row: usize) !?Anchor {
    const location = self.locate(row) orelse return null;
    const item = location.item;
    const source_anchor = if (location.row) |line| blk: {
        const span = (try item.index.rowAt(line)) orelse return error.InvalidTarget;
        break :blk try item.source.scratch.sourceAnchor(span.start);
    } else null;
    return .{ .instance = self.page.instance, .session = self.page.session, .position = item.source.item.position, .ordinal = item.source.item.ordinal, .reference = item.source.item.reference, .source = source_anchor };
}

/// Resolve only against the same Activity identity and content binding.
pub fn rowForAnchor(self: *const Self, anchor: Anchor) !?u32 {
    if (!std.mem.eql(u8, &self.page.instance, &anchor.instance) or !std.mem.eql(u8, &self.page.session, &anchor.session)) return null;
    var base: usize = 0;
    for (self.items[0..self.count]) |item| {
        const id = item.source.item;
        if (id.position == anchor.position and id.ordinal == anchor.ordinal and std.meta.eql(id.reference, anchor.reference)) {
            const row = if (anchor.source) |source| blk: {
                const projection = try item.source.scratch.projectionOffset(source);
                const offset = std.math.cast(usize, projection) orelse return error.InvalidTarget;
                const line = (try item.index.rowForOffset(offset)) orelse return error.InvalidTarget;
                break :blk base + 1 + line;
            } else base;
            return std.math.cast(u32, row) orelse error.TooManyRows;
        }
        base += 1 + item.index.len;
    }
    return null;
}


test "native paged feed declarations retain one bounded page owner" {
    std.testing.refAllDecls(@This());
    try std.testing.expect(@sizeOf(Self) < 16384);
    try std.testing.expectEqual(protocol.ActivityPage.items, @typeInfo(@FieldType(Self, "items")).array.len);
}
