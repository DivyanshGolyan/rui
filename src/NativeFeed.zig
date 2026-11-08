//! Retained Host identities and exact content are distinct from Text widgets.
const std = @import("std");
const fw = @import("vaxis").vxfw;
const observations = @import("NativeObservations.zig");
const markdown = @import("markdown_prefix.zig");
const table = @import("table_row.zig");
const Self = @This();

sources: std.ArrayList(observations.Block) = .empty,
widgets: std.ArrayList(fw.Text) = .empty,

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.sources.deinit(allocator);
    self.widgets.deinit(allocator);
    self.* = .{};
}

pub fn clearRetainingCapacity(self: *Self) void {
    self.sources.clearRetainingCapacity();
    self.widgets.clearRetainingCapacity();
}

/// Blocks and their exact bytes borrow `arena` through the feed's lifetime.
pub fn append(self: *Self, allocator: std.mem.Allocator, arena: std.mem.Allocator, blocks: []const observations.Block) !void {
    var widgets: std.ArrayList(fw.Text) = .empty;
    for (blocks) |block| {
        try widgets.append(arena, .{ .text = if (block.kind == .user) "You\n" else "Assistant\n" });
        try appendDisplay(&widgets, arena, block.display);
        try widgets.append(arena, .{ .text = " \n" });
    }
    try self.sources.ensureUnusedCapacity(allocator, blocks.len);
    try self.widgets.ensureUnusedCapacity(allocator, widgets.items.len);
    self.sources.appendSliceAssumeCapacity(blocks);
    self.widgets.appendSliceAssumeCapacity(widgets.items);
}

fn appendDisplay(widgets: *std.ArrayList(fw.Text), arena: std.mem.Allocator, display: []const u8) !void {
    var context: markdown.Context = .plain;
    var at: usize = 0;
    var segment_start: usize = 0;
    var previous: ?markdown.Context.Mode = null;
    while (at < display.len) {
        const end = if (std.mem.indexOfScalarPos(u8, display, at, '\n')) |i| i else display.len;
        const line = display[at..end];
        const head = line[0..@min(line.len, markdown.head_limit)];
        const ending: markdown.HeadEnding = if (head.len == markdown.head_limit) .limit_cut else if (end < display.len) .line_feed else .canonical_eof;
        const result = context.step(head, ending);
        const decision = switch (result) {
            .resolved => |value| value,
            .need_more => unreachable,
        };
        const mode = decision.projection.mode;
        if (previous) |last| if (last != mode) {
            try appendPart(widgets, arena, display[segment_start..at], last);
            segment_start = at;
        };
        previous = mode;
        context = decision.next;
        at = if (end < display.len) end + 1 else end;
    }
    if (previous) |last| try appendPart(widgets, arena, display[segment_start..], last);
}

const Line = struct {
    raw: []const u8,
    next: usize,
    ending: table.Ending,
};

fn lineAt(bytes: []const u8, at: usize) ?Line {
    if (at >= bytes.len) return null;
    const end = std.mem.indexOfScalarPos(u8, bytes, at, '\n') orelse bytes.len;
    return .{ .raw = bytes[at..end], .next = if (end < bytes.len) end + 1 else end, .ending = if (end < bytes.len) .line_feed else .canonical_eof };
}

const TableFormat = struct {
    columns: table.Columns,
    widths: [table.max_columns]usize = @splat(0),
    delimiter: []const u8,
};

fn appendPart(widgets: *std.ArrayList(fw.Text), arena: std.mem.Allocator, part: []const u8, mode: markdown.Context.Mode) !void {
    if (mode != .prose) {
        try widgets.append(arena, .{ .text = part, .softwrap = false });
        return;
    }
    var at: usize = 0;
    var prose_start: usize = 0;
    while (lineAt(part, at)) |head| {
        // Recognition decides only source ranges; the native Text line
        // index owns wrapping and the rail geometry.
        const logical = if (head.ending == .line_feed and std.mem.endsWith(u8, head.raw, "\r")) head.raw[0 .. head.raw.len - 1] else head.raw;
        const quote = markdown.recognize(logical[0..@min(logical.len, markdown.head_limit)], true);
        if (quote == .quote) {
            if (at > prose_start) try widgets.append(arena, .{ .text = part[prose_start..at] });
            try widgets.append(arena, .{ .text = head.raw, .quote_depth = quote.quote.depth, .quote_prefix_len = quote.quote.bytes });
            at = head.next;
            prose_start = at;
            continue;
        }
        if (head.ending != .line_feed) break;
        const delimiter = lineAt(part, head.next) orelse break;
        const columns = switch (table.header(head.raw, delimiter.raw, delimiter.ending)) {
            .columns => |value| value,
            else => {
                at = head.next;
                continue;
            },
        };
        const first = switch (table.parse(head.raw, head.ending, columns.count)) {
            .row => |value| value,
            else => unreachable,
        };
        const format = try arena.create(TableFormat);
        format.* = .{ .columns = columns, .delimiter = delimiter.raw };
        const ctx: fw.DrawContext = .{ .arena = arena, .min = .{}, .max = .{}, .cell_size = .{} };
        measureTableRow(format, ctx, head.raw, first);
        var next = delimiter.next;
        while (lineAt(part, next)) |line| {
            const parsed = switch (table.parse(line.raw, line.ending, columns.count)) {
                .row => |value| value,
                else => break,
            };
            if (!parsed.has_pipe) break;
            measureTableRow(format, ctx, line.raw, parsed);
            next = line.next;
        }
        if (at > prose_start) try widgets.append(arena, .{ .text = part[prose_start..at] });
        try widgets.append(arena, .{
            .text = part[at..next],
            .softwrap = false,
            .lazy_line = .{ .userdata = format, .renderFn = renderTableLine },
        });
        at = next;
        prose_start = at;
    }
    if (prose_start < part.len) try widgets.append(arena, .{ .text = part[prose_start..] });
}

fn measureTableRow(format: *TableFormat, ctx: fw.DrawContext, raw: []const u8, row: table.Row) void {
    for (row.cells[0..row.count], 0..) |cell, col| {
        format.widths[col] = @max(format.widths[col], tableCellWidth(ctx, raw[cell.start..cell.end]));
    }
}

// The native line index invokes this only for a row being drawn. Its arena is
// the frame arena, so padded cells do not accumulate across the whole table.
fn renderTableLine(raw_context: *const anyopaque, raw: []const u8, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    const format: *const TableFormat = @ptrCast(@alignCast(raw_context));
    var output: std.Io.Writer.Allocating = .init(arena);
    if (raw.ptr == format.delimiter.ptr) {
        tableRule(&output.writer, format.widths[0..format.columns.count]) catch return error.OutOfMemory;
        return output.written();
    }
    const row = switch (table.parse(raw, .canonical_eof, format.columns.count)) {
        .row => |value| value,
        else => unreachable,
    };
    const ctx: fw.DrawContext = .{ .arena = arena, .min = .{}, .max = .{}, .cell_size = .{} };
    for (row.cells[0..row.count], 0..) |cell, col| {
        if (col != 0) output.writer.writeAll(" │ ") catch return error.OutOfMemory;
        const text = raw[cell.start..cell.end];
        const padding = format.widths[col] - tableCellWidth(ctx, text);
        const leading = switch (format.columns.alignment[col]) {
            .left => @as(usize, 0),
            .right => padding,
            .center => padding / 2,
        };
        for (0..leading) |_| output.writer.writeByte(' ') catch return error.OutOfMemory;
        writeTableCell(&output.writer, ctx, text) catch return error.OutOfMemory;
        for (leading..padding) |_| output.writer.writeByte(' ') catch return error.OutOfMemory;
    }
    return output.written();
}

fn tableCellWidth(ctx: fw.DrawContext, text: []const u8) usize {
    return ctx.hardLineWidth(text);
}

fn writeTableCell(writer: *std.Io.Writer, ctx: fw.DrawContext, text: []const u8) !void {
    var column: usize = 0;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |char| {
        const grapheme = char.bytes(text);
        if (std.mem.eql(u8, grapheme, "\t")) {
            const width = fw.DrawContext.tabWidth(column);
            for (0..width) |_| try writer.writeByte(' ');
            column += width;
        } else {
            try writer.writeAll(grapheme);
            column += ctx.stringWidth(grapheme);
        }
    }
}

fn tableRule(writer: *std.Io.Writer, widths: []const usize) !void {
    for (widths, 0..) |width, col| {
        if (col != 0) try writer.writeAll("─┼─");
        for (0..width) |_| try writer.writeAll("─");
    }
}

pub fn sourceAt(self: *const Self, position: u64, ordinal: u64) ?observations.Block {
    for (self.sources.items) |block| if (block.position == position and block.ordinal == ordinal) return block;
    return null;
}

test "native feed retains exact content and Host identity independently of display" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var feed: Self = .{};
    defer feed.deinit(std.testing.allocator);
    const original = "private\x1b[31m bytes\n";
    const content = observations.Block{
        .kind = .assistant,
        .position = 42,
        .ordinal = 0,
        .reference = .{ .length = original.len, .digest = @import("protocol.zig").contentDigest(original) },
        .source = original,
        .display = "private bytes\n",
    };
    try feed.append(std.testing.allocator, arena.allocator(), &.{content});
    const retained = feed.sourceAt(42, 0).?;
    try std.testing.expectEqualStrings(original, retained.source);
    try std.testing.expectEqualDeep(content.reference, retained.reference);
    try std.testing.expectEqualStrings("Assistant\n", feed.widgets.items[0].text);
    try std.testing.expectEqualStrings("private bytes\n", feed.widgets.items[1].text);
    try std.testing.expect(feed.sourceAt(42, 1) == null);
}

test "native feed keeps prose wrapped and fenced source horizontally scrollable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var feed: Self = .{};
    defer feed.deinit(std.testing.allocator);
    const source = "before prose\n```zig\nlong-\x1b[31mcode-line\n```\nafter prose";
    const display = "before prose\n```zig\nlong-code-line\n```\nafter prose";
    try feed.append(std.testing.allocator, arena.allocator(), &.{.{
        .kind = .assistant,
        .position = 1,
        .ordinal = 0,
        .reference = .{ .length = source.len, .digest = @import("protocol.zig").contentDigest(source) },
        .source = source,
        .display = display,
    }});
    try std.testing.expect(feed.widgets.items[1].softwrap);
    try std.testing.expect(!feed.widgets.items[2].softwrap);
    try std.testing.expect(feed.widgets.items[3].softwrap);
    try std.testing.expectEqualStrings(source, feed.sourceAt(1, 0).?.source);
}

test "native feed measures Unicode tables and preserves original source" {
    fw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var feed: Self = .{};
    defer feed.deinit(std.testing.allocator);
    const source = "intro\nname | 表\n--- | ---:\na | 7\noutro";
    try feed.append(std.testing.allocator, arena.allocator(), &.{.{
        .kind = .assistant,
        .position = 2,
        .ordinal = 0,
        .reference = .{ .length = source.len, .digest = @import("protocol.zig").contentDigest(source) },
        .source = source,
        .display = source,
    }});
    try std.testing.expectEqualStrings("intro\n", feed.widgets.items[1].text);
    try std.testing.expect(!feed.widgets.items[2].softwrap);
    const formatted = feed.widgets.items[2].lazy_line.?;
    var lines = std.mem.splitScalar(u8, feed.widgets.items[2].text, '\n');
    try std.testing.expectEqualStrings("name │ 表", try formatted.renderFn(formatted.userdata, lines.next().?, arena.allocator()));
    try std.testing.expectEqualStrings("─────┼───", try formatted.renderFn(formatted.userdata, lines.next().?, arena.allocator()));
    try std.testing.expectEqualStrings("a    │  7", try formatted.renderFn(formatted.userdata, lines.next().?, arena.allocator()));
    try std.testing.expectEqualStrings("outro", feed.widgets.items[3].text);
    try std.testing.expectEqualStrings(source, feed.sourceAt(2, 0).?.source);
}

test "native feed does not interpret table syntax inside a fence" {
    fw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var feed: Self = .{};
    defer feed.deinit(std.testing.allocator);
    const source = "```\na | b\n--- | ---\nx | y\n```";
    try feed.append(std.testing.allocator, arena.allocator(), &.{.{
        .kind = .assistant,
        .position = 3,
        .ordinal = 0,
        .reference = .{ .length = source.len, .digest = @import("protocol.zig").contentDigest(source) },
        .source = source,
        .display = source,
    }});
    try std.testing.expectEqualStrings(source, feed.widgets.items[1].text);
    try std.testing.expect(!feed.widgets.items[1].softwrap);
}

test "native measured table expands tabs from cell starts" {
    fw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var feed: Self = .{};
    defer feed.deinit(std.testing.allocator);
    const source = "key | val\n--- | ---\na\tb | X\n";
    try feed.append(std.testing.allocator, arena.allocator(), &.{.{
        .kind = .assistant,
        .position = 4,
        .ordinal = 0,
        .reference = .{ .length = source.len, .digest = @import("protocol.zig").contentDigest(source) },
        .source = source,
        .display = source,
    }});
    const formatted = feed.widgets.items[1].lazy_line.?;
    var lines = std.mem.splitScalar(u8, feed.widgets.items[1].text, '\n');
    try std.testing.expectEqualStrings("key       │ val", try formatted.renderFn(formatted.userdata, lines.next().?, arena.allocator()));
    try std.testing.expectEqualStrings("──────────┼────", try formatted.renderFn(formatted.userdata, lines.next().?, arena.allocator()));
    try std.testing.expectEqualStrings("a       b │ X  ", try formatted.renderFn(formatted.userdata, lines.next().?, arena.allocator()));
    try std.testing.expectEqualStrings(source, feed.sourceAt(4, 0).?.source);
}

test "native quote rail wraps on every row without changing source" {
    fw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var feed: Self = .{};
    defer feed.deinit(std.testing.allocator);
    const source = "before\n> alphabet beta gamma delta\n> second\nafter";
    try feed.append(std.testing.allocator, arena.allocator(), &.{.{
        .kind = .assistant,
        .position = 5,
        .ordinal = 0,
        .reference = .{ .length = source.len, .digest = @import("protocol.zig").contentDigest(source) },
        .source = source,
        .display = source,
    }});
    const ctx: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{ .width = 10 }, .max = .{ .width = 10, .height = null }, .cell_size = .{} };
    var index: fw.Text.LineIndex = .{};
    defer index.deinit(std.testing.allocator);
    try index.reflow(std.testing.allocator, feed.widgets.items, ctx);
    var quoted: usize = 0;
    for (0..index.len) |i| {
        const widget = (try index.builder().itemAtIdxForDraw(i, 0, ctx.arena)).?;
        const text: *const fw.Text = @ptrCast(@alignCast(widget.userdata));
        if (text.quote_depth == 0) continue;
        const row = try widget.draw(ctx);
        try std.testing.expectEqualStrings("│", row.readCell(0, 0).char.grapheme);
        try std.testing.expect(row.readCell(0, 0).style.dim);
        quoted += 1;
    }
    try std.testing.expect(quoted >= 4);
    const narrow = ctx.withConstraints(.{ .width = 2 }, .{ .width = 2, .height = null });
    try index.reflow(std.testing.allocator, feed.widgets.items, narrow);
    for (0..index.len) |i| {
        const row = (try index.builder().itemAtIdxForDraw(i, 0, ctx.arena)).?;
        _ = try row.draw(narrow);
    }
    try index.reflow(std.testing.allocator, feed.widgets.items, ctx);
    try std.testing.expectEqualStrings(source, feed.sourceAt(5, 0).?.source);
}

const CountedLazyLine = struct {
    inner: fw.Text.LazyLine,
    calls: usize = 0,

    fn render(raw: *const anyopaque, line: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        const self: *CountedLazyLine = @ptrCast(@alignCast(@constCast(raw)));
        self.calls += 1;
        return self.inner.renderFn(self.inner.userdata, line, allocator);
    }
};

test "native table realizes visible rows without multiplying widest cell by history" {
    fw.DrawContext.init(.unicode);
    var original: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer original.deinit();
    try original.writer.writeAll("a | b\n--- | ---\n");
    for (0..100_000) |_| try original.writer.writeAll("s | t  \n");
    for (0..4000) |_| try original.writer.writeByte('W');
    try original.writer.writeAll(" | 界END\n");
    const source = original.written();
    var storage: [2 * 1024 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var arena = std.heap.ArenaAllocator.init(fixed.allocator());
    defer arena.deinit();
    var feed: Self = .{};
    defer feed.deinit(std.testing.allocator);
    try feed.append(std.testing.allocator, arena.allocator(), &.{.{
        .kind = .assistant,
        .position = 6,
        .ordinal = 0,
        .reference = .{ .length = source.len, .digest = @import("protocol.zig").contentDigest(source) },
        .source = source,
        .display = source,
    }});
    try std.testing.expectEqualStrings(source, feed.widgets.items[1].text);
    try std.testing.expectEqualStrings(source, feed.sourceAt(6, 0).?.source);
    var counted: CountedLazyLine = .{ .inner = feed.widgets.items[1].lazy_line.? };
    feed.widgets.items[1].lazy_line = .{ .userdata = &counted, .renderFn = CountedLazyLine.render };
    const ctx: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{ .width = 80 }, .max = .{ .width = 80, .height = null }, .cell_size = .{} };
    var index: fw.Text.LineIndex = .{};
    defer index.deinit(std.testing.allocator);
    try index.reflow(std.testing.allocator, feed.widgets.items, ctx);
    try std.testing.expectEqual(@as(usize, 0), counted.calls);
    for ([_]usize{ 1, 2, index.len - 2 }) |i| {
        const row = (try index.builder().itemAtIdxForDraw(i, 0, ctx.arena)).?;
        const surface = try row.drawHorizontalFn.?(row.userdata, ctx, if (i == index.len - 2) 3996 else 0, 12);
        if (i == index.len - 2) {
            try std.testing.expectEqualStrings("界", surface.readCell(7, 0).char.grapheme);
            try std.testing.expectEqualStrings("D", surface.readCell(11, 0).char.grapheme);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), counted.calls);
    var frame_storage: [2 * 1024 * 1024]u8 = undefined;
    var frame_fixed = std.heap.FixedBufferAllocator.init(&frame_storage);
    const frame_ctx: fw.DrawContext = .{ .arena = frame_fixed.allocator(), .min = .{}, .max = .{ .width = 80, .height = 10 }, .cell_size = .{} };
    var scroll: fw.ScrollView = .{ .children = .{ .builder = index.builder() }, .item_count = @intCast(index.len) };
    counted.calls = 0;
    scroll.jumpToEnd();
    const actual_frame = try scroll.draw(frame_ctx);
    std.debug.print("lazy-table actual-scroll calls={d} children={d} frame_bytes={d}\n", .{ counted.calls, actual_frame.children.len, frame_fixed.end_index });
    try std.testing.expect(counted.calls > 0 and counted.calls <= 10);
    try std.testing.expect(actual_frame.children.len <= 10);
    const wide_row = actual_frame.children[actual_frame.children.len - 2].surface;
    try std.testing.expectEqualStrings("W", wide_row.readCell(0, 0).char.grapheme);
    std.debug.print("lazy-table input_bytes={d} rows={d} owner_arena_high_water={d} scroll_frame_bytes={d} scroll_format_calls={d}\n", .{ source.len, index.len, fixed.end_index, frame_fixed.end_index, counted.calls });
    try std.testing.expect(fixed.end_index < storage.len);
    try std.testing.expect(frame_fixed.end_index < frame_storage.len);
}

test "native nested quotes keep literal prefixes when narrow and recover rails" {
    fw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var feed: Self = .{};
    defer feed.deinit(std.testing.allocator);
    const source = "> > alpha\r\n>\r\n> > omega";
    try feed.append(std.testing.allocator, arena.allocator(), &.{.{
        .kind = .assistant,
        .position = 8,
        .ordinal = 0,
        .reference = .{ .length = source.len, .digest = @import("protocol.zig").contentDigest(source) },
        .source = source,
        .display = source,
    }});
    try std.testing.expectEqual(@as(u4, 2), feed.widgets.items[1].quote_depth);
    try std.testing.expectEqual(@as(u4, 1), feed.widgets.items[2].quote_depth);
    try std.testing.expectEqual(@as(u4, 2), feed.widgets.items[3].quote_depth);
    const wide: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{ .width = 8 }, .max = .{ .width = 8, .height = null }, .cell_size = .{} };
    var index: fw.Text.LineIndex = .{};
    defer index.deinit(std.testing.allocator);
    const nested = [_]fw.Text{feed.widgets.items[1]};
    try index.reflow(std.testing.allocator, &nested, wide);
    const wide_row = try (try index.builder().itemAtIdxForDraw(0, 0, wide.arena)).?.draw(wide);
    try std.testing.expectEqualStrings("│", wide_row.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("│", wide_row.readCell(2, 0).char.grapheme);
    try std.testing.expect(wide_row.readCell(0, 0).style.dim and wide_row.readCell(2, 0).style.dim);
    const narrow = wide.withConstraints(.{ .width = 2 }, .{ .width = 2, .height = null });
    try index.reflow(std.testing.allocator, &nested, narrow);
    const narrow_row = try (try index.builder().itemAtIdxForDraw(0, 0, narrow.arena)).?.draw(narrow);
    try std.testing.expectEqualStrings(">", narrow_row.readCell(0, 0).char.grapheme);
    try index.reflow(std.testing.allocator, &nested, wide);
    const restored = try (try index.builder().itemAtIdxForDraw(0, 0, wide.arena)).?.draw(wide);
    try std.testing.expectEqualStrings("│", restored.readCell(2, 0).char.grapheme);
    const empty = [_]fw.Text{feed.widgets.items[2]};
    try index.reflow(std.testing.allocator, &empty, wide);
    const empty_row = try (try index.builder().itemAtIdxForDraw(0, 0, wide.arena)).?.draw(wide);
    try std.testing.expectEqualStrings("│", empty_row.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings(source, feed.sourceAt(8, 0).?.source);
}

test "native quoted fence retains opaque text and original control bytes" {
    fw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var feed: Self = .{};
    defer feed.deinit(std.testing.allocator);
    const source = "> ```\r\n> a | \x1b[31mb\r\n> --- | ---\r\n> ```\r\n";
    const display = "> ```\r\n> a | \\x1b[31mb\r\n> --- | ---\r\n> ```\r\n";
    try feed.append(std.testing.allocator, arena.allocator(), &.{.{
        .kind = .assistant,
        .position = 9,
        .ordinal = 0,
        .reference = .{ .length = source.len, .digest = @import("protocol.zig").contentDigest(source) },
        .source = source,
        .display = display,
    }});
    try std.testing.expectEqualStrings(display, feed.widgets.items[1].text);
    try std.testing.expect(!feed.widgets.items[1].softwrap);
    try std.testing.expect(feed.widgets.items[1].lazy_line == null);
    try std.testing.expectEqualStrings(source, feed.sourceAt(9, 0).?.source);
}

test "native line index realizes a blank source row at one cell height" {
    fw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{ .width = 10 }, .max = .{ .width = 10, .height = null }, .cell_size = .{} };
    var index: fw.Text.LineIndex = .{};
    defer index.deinit(std.testing.allocator);
    const input = [_]fw.Text{.{ .text = " \n" }};
    try index.reflow(std.testing.allocator, &input, ctx);
    try std.testing.expectEqual(@as(usize, 1), index.len);
    const row = try (try index.builder().itemAtIdxForDraw(0, 0, ctx.arena)).?.draw(ctx);
    try std.testing.expectEqual(@as(u16, 1), row.size.height);
}

test "native terminal cell currently requires the entire large grapheme" {
    const vaxis = @import("vaxis");
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, 1 + 2 * 65_536);
    defer allocator.free(source);
    source[0] = 'a';
    for (0..65_536) |i| {
        source[1 + 2 * i] = 0xcc;
        source[2 + 2 * i] = 0x81;
    }
    var graphemes = vaxis.unicode.graphemeIterator(source);
    const only = graphemes.next().?;
    try std.testing.expectEqual(source.len, only.len);
    try std.testing.expect(graphemes.next() == null);
    var storage: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var screen = try vaxis.AllocatingScreen.init(fixed.allocator(), 1, 1);
    defer screen.deinit(fixed.allocator());
    try std.testing.expectError(error.OutOfMemory, screen.writeCell(0, 0, .{ .char = .{ .grapheme = source, .width = 1 } }));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "source", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, source);
    const backing: GraphemeFile = .{ .io = std.testing.io, .file = file, .max_read = 4096 };
    var reader: vaxis.unicode.PagedReader = .{ .source = .{ .userdata = &backing, .length = source.len, .readFn = GraphemeFile.read } };
    var paged = try vaxis.unicode.PagedGraphemeIterator.init(&reader, 0);
    const span = (try paged.next()).?;
    try std.testing.expectEqual(@as(usize, 0), span.start);
    try std.testing.expectEqual(source.len, span.len);
    try std.testing.expect((try paged.next()) == null);
    try std.testing.expect(@sizeOf(@TypeOf(reader)) < 8192);
    std.debug.print("native terminal single_grapheme_bytes={d} screen_allocator_capacity={d} result=OutOfMemory paged_reader_bytes={d}\n", .{ source.len, storage.len, @sizeOf(@TypeOf(reader)) });
}

test "native last-frame cache redraws an oversized grapheme without copying it" {
    const vaxis = @import("vaxis");
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, 1 + 2 * 65_536);
    defer allocator.free(source);
    source[0] = 'a';
    for (0..65_536) |i| {
        source[1 + 2 * i] = 0xcc;
        source[2 + 2 * i] = 0x81;
    }
    const cell: vaxis.Cell = .{ .char = .{ .grapheme = source, .width = 1 } };
    var storage: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var screen = try vaxis.AllocatingScreen.init(fixed.allocator(), 1, 1);
    defer screen.deinit(fixed.allocator());
    try screen.writeLastCell(0, 0, cell);
    try std.testing.expect(!screen.buf[0].eql(cell));
    const oversized_link: vaxis.Cell = .{ .link = .{ .uri = source } };
    try screen.writeLastCell(0, 0, oversized_link);
    try std.testing.expect(!screen.buf[0].eql(oversized_link));
    try std.testing.expect(fixed.end_index < storage.len);
    const normal: vaxis.Cell = .{ .char = .{ .grapheme = "normal", .width = 1 } };
    try screen.writeCell(0, 0, normal);
    try std.testing.expect(screen.buf[0].eql(normal));

    var environment = try std.testing.environ.createMap(allocator);
    defer environment.deinit();
    var vx = try vaxis.Vaxis.init(std.testing.io, allocator, &environment, .{});
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    defer vx.deinit(allocator, &output.writer);
    try vx.resize(allocator, &output.writer, .{ .rows = 1, .cols = 1, .x_pixel = 0, .y_pixel = 0 });
    vx.screen.writeCell(0, 0, cell);
    var start = output.written().len;
    try vx.render(&output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written()[start..], source) != null);
    start = output.written().len;
    try vx.render(&output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written()[start..], source) != null);
    std.debug.print("native last-frame cache source_bytes={d} fixed_bytes={d} redraws=2 exact_source=true\n", .{ source.len, fixed.end_index });
}

const GraphemeFile = struct {
    io: std.Io,
    file: std.Io.File,
    max_read: usize,
    fail_at: ?usize = null,

    fn read(raw: *const anyopaque, offset: u64, buffer: []u8) !usize {
        const self: *const GraphemeFile = @ptrCast(@alignCast(raw));
        if (self.fail_at) |boundary| if (offset >= boundary) return error.WitnessSourceFailure;
        return self.file.readPositionalAll(self.io, buffer[0..@min(buffer.len, self.max_read)], offset);
    }
};

test "native paged Unicode yields exact grapheme offsets across file windows" {
    const vaxis = @import("vaxis");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "source", .{ .read = true });
    defer file.close(io);
    const source = "Aé中👩🏽‍🚀🇨🇭e\u{301}\nZ";
    try file.writeStreamingAll(io, source);
    for (1..8) |max_read| {
        const backing: GraphemeFile = .{ .io = io, .file = file, .max_read = max_read };
        var reader: vaxis.unicode.PagedReader = .{ .source = .{ .userdata = &backing, .length = source.len, .readFn = GraphemeFile.read } };
        var actual = try vaxis.unicode.PagedGraphemeIterator.init(&reader, 0);
        var expected = vaxis.unicode.graphemeIterator(source);
        while (expected.next()) |want| {
            const got = (try actual.next()).?;
            try std.testing.expectEqual(want.start, got.start);
            try std.testing.expectEqual(want.len, got.len);
        }
        try std.testing.expect((try actual.next()) == null);
        try std.testing.expect(@sizeOf(@TypeOf(reader)) < 8192);
    }
    const failing: GraphemeFile = .{ .io = io, .file = file, .max_read = 1, .fail_at = 5 };
    var reader: vaxis.unicode.PagedReader = .{ .source = .{ .userdata = &failing, .length = source.len, .readFn = GraphemeFile.read } };
    var actual = try vaxis.unicode.PagedGraphemeIterator.init(&reader, 0);
    const Walk = struct {
        fn all(iter: *vaxis.unicode.PagedGraphemeIterator) !void {
            while (try iter.next()) |_| {}
        }
    };
    try std.testing.expectError(error.WitnessSourceFailure, Walk.all(&actual));
}

test "native paged word wrap matches contiguous source geometry" {
    const vaxis = @import("vaxis");
    fw.DrawContext.init(.unicode);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const cases = [_][]const u8{
        "alpha beta gamma delta\nnext words\n",
        "  alpha    beta  \n\nlong-unbroken-word-here\r\nlast",
        "é中 👩🏽‍🚀 test e\u{301} 🇨🇭\nwidth界end",
        "a\tb c\t\td\n   \n  x",
    };
    for (cases, 0..) |source, case_index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "source-{d}", .{case_index});
        const file = try tmp.dir.createFile(io, name, .{ .read = true });
        defer file.close(io);
        try file.writeStreamingAll(io, source);
        for (1..21) |raw_width| {
            const width: u16 = @intCast(raw_width);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const ctx: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{ .width = width }, .max = .{ .width = width, .height = null }, .cell_size = .{} };
            var expected: fw.Text.LineIndex = .{};
            defer expected.deinit(std.testing.allocator);
            const texts = [_]fw.Text{.{ .text = source }};
            try expected.reflow(std.testing.allocator, &texts, ctx);
            const backing: GraphemeFile = .{ .io = io, .file = file, .max_read = 3 };
            var reader: vaxis.unicode.PagedReader = .{ .source = .{ .userdata = &backing, .length = source.len, .readFn = GraphemeFile.read } };
            var paged = try fw.PagedText.WrapIterator.init(&reader, ctx, width);
            var row: usize = 0;
            while (try paged.next()) |actual| : (row += 1) {
                try std.testing.expect(row < expected.len);
                const widget = (try expected.builder().itemAtIdxForDraw(row, 0, ctx.arena)).?;
                const text: *const fw.Text = @ptrCast(@alignCast(widget.userdata));
                const observed = source[actual.start..actual.end];
                std.testing.expectEqualStrings(if (observed.len == 0) " " else observed, text.text) catch |err| {
                    std.debug.print("paged wrap mismatch case={d} width={d} row={d} start={d} end={d} source={any} expected={any} actual={any}\n", .{ case_index, width, row, actual.start, actual.end, source, text.text, observed });
                    return err;
                };
                try std.testing.expect(!actual.oversized_grapheme);
            }
            try std.testing.expectEqual(expected.len, row);
        }
    }
}

test "native paged checkpoints seek source offsets without per-row storage" {
    const vaxis = @import("vaxis");
    fw.DrawContext.init(.unicode);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "long-source", .{ .read = true });
    defer file.close(io);
    const chunk: [4096]u8 = @splat('x');
    for (0..245) |_| try file.writeStreamingAll(io, &chunk);
    const length = 245 * chunk.len;
    const backing: GraphemeFile = .{ .io = io, .file = file, .max_read = 4096 };
    var reader: vaxis.unicode.PagedReader = .{ .source = .{ .userdata = &backing, .length = length, .readFn = GraphemeFile.read } };
    const width: u16 = 79;
    const ctx: fw.DrawContext = .{ .arena = std.testing.allocator, .min = .{ .width = width }, .max = .{ .width = width, .height = null }, .cell_size = .{} };
    const index = try fw.PagedText.Index.init(&reader, ctx, width);
    try std.testing.expectEqual((length + width - 1) / width, index.len);
    try std.testing.expect(index.checkpoint_count <= 256);
    try std.testing.expect(@sizeOf(@TypeOf(index)) < 65536);
    for ([_]usize{ 0, length / 2, length - 1 }) |offset| {
        const row = (try index.rowForOffset(offset)).?;
        try std.testing.expectEqual(offset / width, row);
        const span = (try index.rowAt(row)).?;
        try std.testing.expect(span.start <= offset and offset < span.end);
    }
    try std.testing.expectEqual(index.len - 1, (try index.rowForOffset(length)).?);
    try std.testing.expectEqual(length, (try index.rowAt(index.len - 1)).?.end);
    try std.testing.expect((try index.rowAt(index.len)) == null);
}

/// A verified source in the native feed working set. The owner must keep this
/// object at a stable address while a framework reader borrows `pagedSource`,
/// and close it after the last borrowed reader is gone.
pub const VerifiedSource = struct {
    item: observations.SourcePage.Item,
    scratch: *@import("client.zig").VerifiedContentScratch,
    display: *@import("client.zig").DisplayScratch,
    cancellation: ?*const @import("client.zig").Cancellation = null,

    pub fn open(allocator: std.mem.Allocator, requests: @import("client.zig").Requests, dir: std.Io.Dir, store: []const u8, page: *const observations.SourcePage, item_index: usize) !VerifiedSource {
        if (item_index >= page.count) return error.InvalidTarget;
        const scratch = try observations.openPageSource(allocator, requests, dir, store, page, item_index);
        errdefer scratch.close();
        const display = try scratch.projectMultiline(allocator, dir, requests.cancellation);
        return .{ .item = page.items[item_index], .scratch = scratch, .display = display, .cancellation = requests.cancellation };
    }

    pub fn close(self: *VerifiedSource) void {
        self.display.close();
        self.scratch.close();
        self.* = undefined;
    }

    pub fn pagedSource(self: *const VerifiedSource) !@import("vaxis").unicode.PagedSource {
        return .{ .userdata = self, .length = std.math.cast(usize, self.display.len()) orelse return error.SourceTooLarge, .readFn = read };
    }

    pub fn rawSource(self: *const VerifiedSource) !@import("vaxis").unicode.PagedSource {
        return .{ .userdata = self, .length = std.math.cast(usize, self.item.reference.length) orelse return error.SourceTooLarge, .readFn = readRaw };
    }

    fn readRaw(raw: *const anyopaque, offset: u64, buffer: []u8) !usize {
        const self: *const VerifiedSource = @ptrCast(@alignCast(raw));
        if (self.cancellation) |stop| if (stop.stopped.load(.acquire)) return error.Cancelled;
        return self.scratch.readAt(offset, buffer);
    }

    fn read(raw: *const anyopaque, offset: u64, buffer: []u8) !usize {
        const self: *const VerifiedSource = @ptrCast(@alignCast(raw));
        if (self.cancellation) |stop| if (stop.stopped.load(.acquire)) return error.Cancelled;
        return self.display.readAt(offset, buffer);
    }
};

test "native paged source scroll view realizes only visible rows" {
    const vaxis = @import("vaxis");
    fw.DrawContext.init(.unicode);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "scroll-source", .{ .read = true });
    defer file.close(io);
    const chunk: [4096]u8 = @splat('x');
    for (0..40) |_| try file.writeStreamingAll(io, &chunk);
    const length = 40 * chunk.len;
    const backing: GraphemeFile = .{ .io = io, .file = file, .max_read = 4096 };
    var reader: vaxis.unicode.PagedReader = .{ .source = .{ .userdata = &backing, .length = length, .readFn = GraphemeFile.read } };
    const geometry: fw.DrawContext = .{ .arena = std.testing.allocator, .min = .{ .width = 32 }, .max = .{ .width = 32, .height = null }, .cell_size = .{} };
    var index = try fw.PagedText.Index.init(&reader, geometry, 32);
    try std.testing.expect(index.len > 5000);
    var storage: [1024 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const frame: fw.DrawContext = .{ .arena = fixed.allocator(), .min = .{}, .max = .{ .width = 32, .height = 4 }, .cell_size = .{} };
    var scroll: fw.ScrollView = .{ .children = .{ .builder = index.builder() }, .item_count = @intCast(index.len) };
    scroll.jumpToEnd();
    const drawn = try scroll.draw(frame);
    try std.testing.expect(drawn.children.len > 0 and drawn.children.len <= 4);
    try std.testing.expectEqualStrings("x", drawn.children[drawn.children.len - 1].surface.readCell(0, 0).char.grapheme);
    try std.testing.expect(index.fault == null);
    try std.testing.expect(fixed.end_index < storage.len);
    std.debug.print("paged actual-scroll source={d} rows={d} visible={d} frame_bytes={d}\n", .{ length, index.len, drawn.children.len, fixed.end_index });
}

test "native oversized paged grapheme renders one bounded replacement and preserves source offsets" {
    const vaxis = @import("vaxis");
    fw.DrawContext.init(.unicode);
    const allocator = std.testing.allocator;
    const prefix = "e\u{301}👩🏽‍🚀";
    const accents = fw.PagedText.max_cell_grapheme_bytes / 2 + 64;
    const cluster_len = 1 + 2 * accents;
    const source = try allocator.alloc(u8, prefix.len + cluster_len + 1);
    defer allocator.free(source);
    @memcpy(source[0..prefix.len], prefix);
    source[prefix.len] = 'a';
    for (0..accents) |i| {
        source[prefix.len + 1 + 2 * i] = 0xcc;
        source[prefix.len + 2 + 2 * i] = 0x81;
    }
    source[source.len - 1] = 'Z';
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "large-grapheme", .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, source);
    const backing: GraphemeFile = .{ .io = io, .file = file, .max_read = 37 };
    var reader: vaxis.unicode.PagedReader = .{ .source = .{ .userdata = &backing, .length = source.len, .readFn = GraphemeFile.read } };
    var graphemes = try vaxis.unicode.PagedGraphemeIterator.init(&reader, 0);
    const first = (try graphemes.next()).?;
    const second = (try graphemes.next()).?;
    const large = (try graphemes.next()).?;
    const last = (try graphemes.next()).?;
    try std.testing.expectEqualStrings("e\u{301}", source[first.start..][0..first.len]);
    try std.testing.expectEqualStrings("👩🏽‍🚀", source[second.start..][0..second.len]);
    try std.testing.expectEqual(prefix.len, large.start);
    try std.testing.expectEqual(cluster_len, large.len);
    try std.testing.expectEqual(prefix.len + cluster_len, last.start);
    try std.testing.expectEqualStrings("Z", source[last.start..][0..last.len]);
    try std.testing.expect((try graphemes.next()) == null);

    const geometry: fw.DrawContext = .{ .arena = allocator, .min = .{ .width = 12 }, .max = .{ .width = 12, .height = null }, .cell_size = .{} };
    var index = try fw.PagedText.Index.init(&reader, geometry, 12);
    try std.testing.expectEqual(@as(usize, 1), index.len);
    const row = (try index.rowAt(0)).?;
    try std.testing.expect(row.oversized_grapheme);
    try std.testing.expectEqual(source.len, row.end);
    try std.testing.expectEqual(@as(?usize, 0), try index.rowForOffset(large.start + 4096));
    var storage: [256 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const ctx: fw.DrawContext = .{ .arena = fixed.allocator(), .min = .{ .width = 12 }, .max = .{ .width = 12, .height = null }, .cell_size = .{} };
    const widget = (try index.builder().itemAtIdxForDraw(0, 0, ctx.arena)).?;
    const surface = try widget.draw(ctx);
    const marker_column: u16 = @intCast(geometry.stringWidth(prefix));
    try std.testing.expectEqualStrings("e\u{301}", surface.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("👩🏽‍🚀", surface.readCell(1, 0).char.grapheme);
    try std.testing.expectEqualStrings("�", surface.readCell(marker_column, 0).char.grapheme);
    try std.testing.expectEqualStrings("Z", surface.readCell(marker_column + 1, 0).char.grapheme);
    try std.testing.expect(index.fault == null);

    const Horizontal = struct {
        fn line(_: *const anyopaque, _: usize) !fw.PagedText.LineStyle {
            return .{ .horizontal = true };
        }
    };
    var context: u8 = 0;
    var horizontal = try fw.PagedText.Index.initStyled(&reader, geometry, 12, .{ .userdata = &context, .lineFn = Horizontal.line });
    const horizontal_widget = (try horizontal.builder().itemAtIdxForDraw(0, 0, ctx.arena)).?;
    const shifted = try horizontal_widget.drawHorizontalFn.?(horizontal_widget.userdata, ctx, marker_column, 4);
    try std.testing.expectEqualStrings("�", shifted.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("Z", shifted.readCell(1, 0).char.grapheme);
    try std.testing.expect(horizontal.fault == null);
    const copied = try allocator.alloc(u8, source.len);
    defer allocator.free(copied);
    try std.testing.expectEqual(source.len, try file.readPositionalAll(io, copied, 0));
    try std.testing.expectEqualSlices(u8, source, copied);
    try std.testing.expect(fixed.end_index < storage.len);
    std.debug.print("native oversized display source_bytes={d} cluster_bytes={d} frame_bytes={d} source_exact=true\n", .{ source.len, cluster_len, fixed.end_index });
}
