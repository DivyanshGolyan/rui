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
const RichLines = @import("NativeRichLines.zig");
const RowWindow = @import("NativeRowWindow.zig");
const TerminalText = @import("TerminalText.zig");
pub const window_rows: u32 = 512;
const Self = @This();

const Item = struct {
    source: feed.VerifiedSource,
    reader: vaxis.unicode.PagedReader,
    rich: ?RichLines = null,
    index: ?fw.PagedText.Index = null,
    preview: [4096 + 16]u8 = undefined,
    preview_len: usize = 0,
    glyph: []const u8 = "",
    failure_glyph: bool = false,

    fn rows(self: *const Item) usize {
        return 1 + if (self.index) |*index| index.len else @as(usize, 0);
    }
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

/// Prepared on the UI thread while the page is live; resolving the raw span
/// can scan the source and belongs to a joined background worker.
pub const AnchorInput = struct {
    anchor: Anchor,
    scratch: ?*client.VerifiedContentScratch,
    projection: u64,

    pub fn resolve(self: AnchorInput, cancellation: ?*const client.Cancellation) !Anchor {
        var result = self.anchor;
        if (self.scratch) |scratch| result.source = try scratch.sourceAnchorCancelable(self.projection, cancellation);
        return result;
    }
};

allocator: std.mem.Allocator,
page: observations.SourcePage,
request: replies.ActivityCursor,
items: [protocol.ActivityPage.items]*Item = undefined,
count: usize = 0,
row_count: usize = 0,
window: RowWindow = RowWindow.init(0, window_rows),
width: u16,
colour: bool,

/// Load at most one authoritative Activity page. Each selected Message is
/// held in two unlinked files (exact verified and terminal-safe projection).
/// Temporary disk also includes line and table checkpoint/interval sidecars;
/// no Message content lives in an arena.
pub fn load(allocator: std.mem.Allocator, requests: client.Requests, dir: std.Io.Dir, store: []const u8, session: *const [protocol.session_id_bytes]u8, cursor: replies.ActivityCursor, instance: ?protocol.InstanceId, width: u16, colour: bool) !*Self {
    if (width == 0) return error.InvalidWidth;
    const page = try observations.sourcePage(requests, store, session, cursor, instance);
    const self = try allocator.create(Self);
    self.* = .{ .allocator = allocator, .page = page, .request = cursor, .width = width, .colour = colour };
    errdefer self.destroy();
    const ctx: fw.DrawContext = .{ .arena = allocator, .min = .{ .width = width }, .max = .{ .width = width, .height = null }, .cell_size = .{} };
    for (0..page.count) |i| {
        const page_index = if (page.direction == .backward) page.count - 1 - i else i;
        const item = try allocator.create(Item);
        errdefer allocator.destroy(item);
        item.source = try feed.VerifiedSource.open(allocator, requests, dir, store, &self.page, page_index);
        errdefer item.source.close();
        item.reader = .{ .source = try item.source.pagedSource() };
        item.rich = null;
        item.index = null;
        errdefer if (item.rich) |*rich| rich.close();
        item.preview_len = 0;
        item.glyph = "";
        item.failure_glyph = false;
        if (item.source.item.queued) {
            item.preview_len = try queuedPreview(&item.reader, &item.preview);
        } else if (item.source.item.presentation) |presentation| {
            const status = toolStatus(presentation.code);
            item.glyph = status.glyph;
            item.failure_glyph = status.failure;
            item.preview_len = try toolPreview(&item.preview, presentation, status);
        } else {
            item.rich = try RichLines.buildRaw(requests.io, dir, try item.source.rawSource(), item.reader.source, requests.cancellation);
            item.index = try fw.PagedText.Index.initStyled(&item.reader, ctx, width, item.rich.?.provider());
        }
        self.row_count = try std.math.add(usize, self.row_count, item.rows());
        self.items[self.count] = item;
        self.count += 1;
    }
    self.window = RowWindow.init(self.row_count, window_rows);
    try observations.ensureServing(requests.io, store, self.page.instance);
    return self;
}

/// Materialize at most one bounded, terminal-safe first line. The reader is
/// already authenticated; the preview never replaces its exact source.
fn queuedPreview(reader: *vaxis.unicode.PagedReader, preview: *[4096 + 16]u8) !usize {
    const prefix = "Queued · ";
    @memcpy(preview[0..prefix.len], prefix);
    var used: usize = 0;
    while (used < 4096) : (used += 1) {
        const byte = (try reader.readByte(used)) orelse break;
        if (byte == '\n') break;
        preview[prefix.len + used] = byte;
    }
    const truncated = used == 4096 and used < reader.source.length;
    while (used != 0 and !std.unicode.utf8ValidateSlice(preview[prefix.len .. prefix.len + used])) used -= 1;
    var len = prefix.len + used;
    if (truncated) {
        @memcpy(preview[len..][0..3], "…");
        len += 3;
    }
    return len;
}

const ToolStatus = struct { glyph: []const u8, suffix: []const u8, failure: bool = false };

fn toolStatus(code: protocol.ToolPresentation.Code) ToolStatus {
    return switch (code) {
        .unresolved => .{ .glyph = "•", .suffix = "" },
        .pending_permission => .{ .glyph = "?", .suffix = "" },
        .succeeded => .{ .glyph = "✓", .suffix = "" },
        .denied => .{ .glyph = "•", .suffix = " — Denied" },
        .unknown_tool => .{ .glyph = "•", .suffix = " — Rejected: unknown tool" },
        .invalid_arguments => .{ .glyph = "•", .suffix = " — Rejected: invalid arguments" },
        .failed => .{ .glyph = "!", .suffix = " — Failed", .failure = true },
        .timed_out => .{ .glyph = "!", .suffix = " — Timed out", .failure = true },
        .indeterminate => .{ .glyph = "!", .suffix = " — Outcome unknown; may have run", .failure = true },
        .storage_failed => .{ .glyph = "!", .suffix = " — Output capture failed", .failure = true },
        .spawn_failed => .{ .glyph = "!", .suffix = " — Could not start", .failure = true },
        .cancelled => .{ .glyph = "!", .suffix = " — Cancelled", .failure = true },
        .infrastructure_shutdown => .{ .glyph = "!", .suffix = " — Host stopped; outcome unknown", .failure = true },
    };
}

fn toolPreview(preview: *[4096 + 16]u8, presentation: protocol.ToolPresentation, status: ToolStatus) !usize {
    var out: std.Io.Writer = .fixed(preview);
    var safe: TerminalText = .{ .mode = .label };
    try safe.feed(&out, if (presentation.description) |description| description.slice() else "Tool call");
    try safe.finish(&out);
    try out.writeAll(status.suffix);
    return out.buffered().len;
}

fn toolWidget(arena: std.mem.Allocator, glyph: []const u8, text: []const u8, width: u16, red: bool) std.mem.Allocator.Error!fw.Widget {
    const symbol = try arena.create(fw.Text);
    symbol.* = .{ .text = glyph, .softwrap = false, .style = .{ .fg = if (red) .{ .index = 1 } else .default } };
    const label = try arena.create(fw.Text);
    label.* = .{ .text = text, .softwrap = false, .width_basis = .parent };
    const children = try arena.alloc(fw.FlexItem, 3);
    const spacer = try arena.create(fw.Text);
    spacer.* = .{ .text = " ", .softwrap = false };
    children[0] = .{ .widget = symbol.widget(), .flex = 0 };
    children[1] = .{ .widget = spacer.widget(), .flex = 0 };
    children[2] = .{ .widget = label.widget(), .flex = 1 };
    const row = try arena.create(fw.FlexRow);
    row.* = .{ .children = children };
    const box = try arena.create(fw.SizedBox);
    box.* = .{ .child = row.widget(), .size = .{ .width = width, .height = 1 } };
    var widget = box.widget();
    widget.pinnedHorizontal = true;
    return widget;
}

fn queuedWidget(arena: std.mem.Allocator, text: []const u8, width: u16) std.mem.Allocator.Error!fw.Widget {
    const label = try arena.create(fw.Text);
    label.* = .{ .text = text, .softwrap = false, .pinned_horizontal = true };
    const box = try arena.create(fw.SizedBox);
    box.* = .{ .child = label.widget(), .size = .{ .width = width, .height = 1 } };
    var widget = box.widget();
    widget.pinnedHorizontal = true;
    return widget;
}

/// Detach the worker token only after all indexing and anchor resolution have
/// completed; the page may then safely outlive its joined worker.
pub fn prepareForPublication(self: *Self, cancellation: ?*const client.Cancellation) !void {
    if (cancellation) |stop| if (stop.stopped.load(.acquire)) return error.Cancelled;
    for (self.items[0..self.count]) |item| {
        item.source.cancellation = null;
        if (item.rich) |*rich| rich.releaseCancellation();
    }
}

pub fn destroy(self: *Self) void {
    const allocator = self.allocator;
    for (self.items[0..self.count]) |item| {
        if (item.rich) |*rich| rich.close();
        item.source.close();
        allocator.destroy(item);
    }
    allocator.destroy(self);
}

pub fn fault(self: *const Self) ?anyerror {
    for (self.items[0..self.count]) |item| if (item.index) |*index| {
        if (index.fault) |err| return err;
    };
    return null;
}

pub fn builder(self: *Self) fw.ScrollView.Builder {
    return .{ .userdata = self, .hasFn = hasRow, .buildFrameFn = drawRow };
}

fn hasRow(raw: *const anyopaque, row: usize, _: usize) bool {
    const self: *const Self = @ptrCast(@alignCast(raw));
    return row < self.window.count();
}

/// Snapshot only public Activity identities; exact content remains in its
/// verified scratch owner and is never reconstructed from rendered cells.
pub fn sources(self: *const Self, out: *[protocol.ActivityPage.items]observations.SourcePage.Item) usize {
    for (self.items[0..self.count], 0..) |item, i| out[i] = item.source.item;
    return self.count;
}

pub fn sourceIndexAt(self: *const Self, row: usize) ?usize {
    var remaining = self.window.global(row) orelse return null;
    for (self.items[0..self.count], 0..) |item, i| {
        const rows = item.rows();
        if (remaining < rows) return i;
        remaining -= rows;
    }
    return null;
}

const Location = struct { item: *Item, row: ?usize };

fn locate(self: *const Self, row: usize) ?Location {
    var remaining = row;
    for (self.items[0..self.count]) |item| {
        if (remaining == 0) return .{ .item = item, .row = null };
        remaining -= 1;
        if (item.index) |*index| {
            if (remaining < index.len) return .{ .item = item, .row = remaining };
            remaining -= index.len;
        }
    }
    return null;
}

fn drawRow(raw: *const anyopaque, row: usize, cursor: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!?fw.Widget {
    const self: *Self = @ptrCast(@alignCast(@constCast(raw)));
    const global_row = self.window.global(row) orelse return null;
    const location = self.locate(global_row) orelse return null;
    if (location.row) |line| return location.item.index.?.builder().itemAtIdxForDraw(line, cursor, arena);
    if (location.item.source.item.queued) return try queuedWidget(arena, location.item.preview[0..location.item.preview_len], self.width);
    if (location.item.source.item.presentation != null) return try toolWidget(arena, location.item.glyph, location.item.preview[0..location.item.preview_len], self.width, self.colour and location.item.failure_glyph);
    const label = try arena.create(fw.Text);
    label.* = .{ .text = if (location.item.source.item.kind == .user) "You" else "Assistant", .softwrap = false, .pinned_horizontal = true };
    return label.widget();
}

/// Prepare a source-bound visual anchor without scanning the full source.
/// The caller keeps this page alive until the worker resolves the anchor.
pub fn prepareAnchor(self: *const Self, row: usize) !?AnchorInput {
    const global_row = self.window.global(row) orelse return null;
    const location = self.locate(global_row) orelse return null;
    const item = location.item;
    const span = if (location.row) |line| (try item.index.?.rowAt(line)) orelse return error.InvalidTarget else null;
    return .{
        .anchor = .{ .instance = self.page.instance, .session = self.page.session, .position = item.source.item.position, .ordinal = item.source.item.ordinal, .reference = item.source.item.reference, .source = null },
        .scratch = if (span == null) null else item.source.scratch,
        .projection = if (span) |value| value.start else 0,
    };
}

/// Resolve only against the same Activity identity and content binding.
pub fn rowForAnchor(self: *Self, anchor: Anchor, cancellation: ?*const client.Cancellation) !?u32 {
    if (!std.mem.eql(u8, &self.page.instance, &anchor.instance) or !std.mem.eql(u8, &self.page.session, &anchor.session)) return null;
    var base: usize = 0;
    for (self.items[0..self.count]) |item| {
        const id = item.source.item;
        if (id.position == anchor.position and id.ordinal == anchor.ordinal and std.meta.eql(id.reference, anchor.reference)) {
            const row = if (anchor.source) |source| blk: {
                const projection = try item.source.scratch.projectionOffsetCancelable(source, cancellation);
                const offset = std.math.cast(usize, projection) orelse return error.InvalidTarget;
                const line = (try item.index.?.rowForOffset(offset)) orelse return error.InvalidTarget;
                break :blk base + 1 + line;
            } else base;
            return self.window.select(row) orelse error.HistoryAnchorUnavailable;
        }
        base += item.rows();
    }
    return null;
}

test "native paged feed declarations retain one bounded page owner" {
    std.testing.refAllDecls(@This());
    try std.testing.expect(@sizeOf(Self) < 16384);
    try std.testing.expectEqual(protocol.ActivityPage.items, @typeInfo(@FieldType(Self, "items")).array.len);
}

test "native queued preview clips UTF8 boundary and marks viewport overflow" {
    const Source = struct {
        bytes: []const u8,
        fn read(raw: *const anyopaque, offset: u64, out: []u8) !usize {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            const start: usize = @intCast(offset);
            const count = @min(out.len, self.bytes.len - start);
            @memcpy(out[0..count], self.bytes[start..][0..count]);
            return count;
        }
    };
    var bytes: [4100]u8 = @splat('x');
    @memcpy(bytes[4094..4098], "😀");
    bytes[4098] = '\n';
    const source: Source = .{ .bytes = &bytes };
    var reader: vaxis.unicode.PagedReader = .{ .source = .{ .userdata = &source, .length = source.bytes.len, .readFn = Source.read } };
    var preview: [4096 + 16]u8 = undefined;
    const len = try queuedPreview(&reader, &preview);
    const text = preview[0..len];
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    try std.testing.expect(std.mem.endsWith(u8, text, "…"));
    try std.testing.expectEqual(@as(usize, "Queued · ".len + 4094 + 3), len);
    fw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{ .width = 20 }, .max = .{ .width = null, .height = null }, .cell_size = .{} };
    const widget = try queuedWidget(ctx.arena, text, 20);
    try std.testing.expect(widget.pinnedHorizontal);
    const surface = try widget.draw(ctx);
    try std.testing.expectEqual(@as(u16, 20), surface.size.width);
    try std.testing.expectEqualStrings("…", surface.readCell(19, 0).char.grapheme);
}

test "native compact tool failure escapes metadata and colors only its glyph" {
    const status = toolStatus(.failed);
    try std.testing.expect(status.failure);
    var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    try description.set("danger\x1b[31m");
    const presentation: protocol.ToolPresentation = .{ .description = description, .code = .failed, .publication_position = null };
    var preview: [4096 + 16]u8 = undefined;
    const len = try toolPreview(&preview, presentation, status);
    try std.testing.expectEqualStrings("danger\\x1b[31m — Failed", preview[0..len]);
    fw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{ .width = 30 }, .max = .{ .width = null, .height = null }, .cell_size = .{} };
    const widget = try toolWidget(ctx.arena, status.glyph, preview[0..len], 30, true);
    const surface = try widget.draw(ctx);
    try std.testing.expectEqual(@as(usize, 3), surface.children.len);
    try std.testing.expectEqualStrings("!", surface.children[0].surface.readCell(0, 0).char.grapheme);
    try std.testing.expect(std.meta.eql(vaxis.Color{ .index = 1 }, surface.children[0].surface.readCell(0, 0).style.fg));
    try std.testing.expect(std.meta.eql(vaxis.Color.default, surface.children[2].surface.readCell(0, 0).style.fg));
    const no_colour = try (try toolWidget(ctx.arena, status.glyph, preview[0..len], 30, false)).draw(ctx);
    try std.testing.expect(std.meta.eql(vaxis.Color.default, no_colour.children[0].surface.readCell(0, 0).style.fg));
    for (std.enums.values(protocol.ToolPresentation.Code)) |code| try std.testing.expect(toolStatus(code).glyph.len != 0);
}
