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

const TableLine = struct { raw: []const u8, parsed: table.Row };

// These bound temporary metadata and formatted output per table, not history.
// A table beyond either limit stays available as original text with a notice.
const max_table_rows = 4096;
const max_table_render_bytes = 1024 * 1024;
const table_fallback_start = "[Table too large to format; original text follows]\n";
const table_fallback_end = "[End of unformatted table]\n";

fn appendPart(widgets: *std.ArrayList(fw.Text), arena: std.mem.Allocator, part: []const u8, mode: markdown.Context.Mode) !void {
    if (mode != .prose) {
        try widgets.append(arena, .{ .text = part, .softwrap = false });
        return;
    }
    var at: usize = 0;
    var prose_start: usize = 0;
    while (lineAt(part, at)) |head| {
        if (head.ending != .line_feed) break;
        const delimiter = lineAt(part, head.next) orelse break;
        // Recognition decides only source ranges; the native Text line
        // index owns wrapping and the rail geometry.
        const quote = markdown.recognize(head.raw[0..@min(head.raw.len, markdown.head_limit)], true);
        if (quote == .quote) {
            if (at > prose_start) try widgets.append(arena, .{ .text = part[prose_start..at] });
            const body = head.raw[quote.quote.bytes..];
            try widgets.append(arena, .{ .text = if (body.len == 0) " " else body, .quote_rail = true });
            at = head.next;
            prose_start = at;
            continue;
        }
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
        var rows: std.ArrayList(TableLine) = .empty;
        try rows.append(arena, .{ .raw = head.raw, .parsed = first });
        var next = delimiter.next;
        var too_many_rows = false;
        while (lineAt(part, next)) |line| {
            const parsed = switch (table.parse(line.raw, line.ending, columns.count)) {
                .row => |value| value,
                else => break,
            };
            if (!parsed.has_pipe) break;
            if (rows.items.len < max_table_rows) {
                try rows.append(arena, .{ .raw = line.raw, .parsed = parsed });
            } else too_many_rows = true;
            next = line.next;
        }
        if (at > prose_start) try widgets.append(arena, .{ .text = part[prose_start..at] });
        const rendered = if (too_many_rows) null else try renderTable(arena, rows.items, columns);
        if (rendered) |text| {
            try widgets.append(arena, .{ .text = text, .softwrap = false });
        } else {
            try widgets.append(arena, .{ .text = table_fallback_start });
            try widgets.append(arena, .{ .text = part[at..next], .softwrap = false });
            try widgets.append(arena, .{ .text = table_fallback_end });
        }
        at = next;
        prose_start = at;
    }
    if (prose_start < part.len) try widgets.append(arena, .{ .text = part[prose_start..] });
}

fn renderTable(arena: std.mem.Allocator, rows: []const TableLine, columns: table.Columns) !?[]const u8 {
    const ctx: fw.DrawContext = .{ .arena = arena, .min = .{}, .max = .{}, .cell_size = .{} };
    var widths: [table.max_columns]usize = @splat(0);
    for (rows) |row| for (row.parsed.cells[0..row.parsed.count], 0..) |cell, col| {
        widths[col] = @max(widths[col], tableCellWidth(ctx, row.raw[cell.start..cell.end]));
    };
    // Conservative upper bound includes the UTF-8 rule, cell bytes (tabs can
    // expand), padding and separators. Saturation is a refusal, never a wrap.
    var estimated: usize = 1;
    for (widths[0..columns.count]) |width| estimated +|= (width *| 3) +| 6;
    for (rows) |row| {
        for (row.parsed.cells[0..row.parsed.count], 0..) |cell, col| {
            estimated +|= ((@as(usize, cell.end) - cell.start) *| 8) +| widths[col] +| 6;
        }
        estimated +|= 1;
        if (estimated > max_table_render_bytes) return null;
    }
    if (estimated > max_table_render_bytes) return null;
    var output: std.Io.Writer.Allocating = .init(arena);
    for (rows, 0..) |row, row_index| {
        if (row_index == 1) try tableRule(&output.writer, widths[0..columns.count]);
        for (row.parsed.cells[0..row.parsed.count], 0..) |cell, col| {
            if (col != 0) try output.writer.writeAll(" │ ");
            const text = row.raw[cell.start..cell.end];
            const padding = widths[col] - tableCellWidth(ctx, text);
            const leading = switch (columns.alignment[col]) {
                .left => @as(usize, 0),
                .right => padding,
                .center => padding / 2,
            };
            for (0..leading) |_| try output.writer.writeByte(' ');
            try writeTableCell(&output.writer, ctx, text);
            for (leading..padding) |_| try output.writer.writeByte(' ');
        }
        try output.writer.writeByte('\n');
    }
    if (rows.len == 1) try tableRule(&output.writer, widths[0..columns.count]);
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
    try writer.writeByte('\n');
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
    try std.testing.expectEqualStrings("name │ 表\n─────┼───\na    │  7\n", feed.widgets.items[2].text);
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
    try std.testing.expectEqualStrings("key       │ val\n──────────┼────\na       b │ X  \n", feed.widgets.items[1].text);
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
        if (!text.quote_rail) continue;
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

test "native oversized table falls back visibly without amplified output" {
    fw.DrawContext.init(.unicode);
    var original: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer original.deinit();
    try original.writer.writeAll("a | b\n--- | ---\n");
    for (0..100_000) |_| try original.writer.writeAll("s | t  \n");
    for (0..4000) |_| try original.writer.writeByte('W');
    try original.writer.writeAll(" | z\n");
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
    try std.testing.expectEqualStrings(table_fallback_start, feed.widgets.items[1].text);
    try std.testing.expectEqualStrings(source, feed.widgets.items[2].text);
    try std.testing.expect(!feed.widgets.items[2].softwrap);
    try std.testing.expectEqualStrings(table_fallback_end, feed.widgets.items[3].text);
    try std.testing.expectEqualStrings(source, feed.sourceAt(6, 0).?.source);
    std.debug.print("oversized-table input_bytes={d} fixed_arena_bytes={d} row_limit={d} format_limit={d}\\n", .{ source.len, fixed.end_index, max_table_rows, max_table_render_bytes });
    try std.testing.expect(fixed.end_index < storage.len);
}

test "native table format budget rejects width by row amplification" {
    fw.DrawContext.init(.unicode);
    var original: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer original.deinit();
    try original.writer.writeAll("a | b\n--- | ---\n");
    for (0..1000) |_| try original.writer.writeAll("s | t\n");
    for (0..4000) |_| try original.writer.writeByte('W');
    try original.writer.writeAll(" | z\n");
    const source = original.written();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var feed: Self = .{};
    defer feed.deinit(std.testing.allocator);
    try feed.append(std.testing.allocator, arena.allocator(), &.{.{
        .kind = .assistant,
        .position = 7,
        .ordinal = 0,
        .reference = .{ .length = source.len, .digest = @import("protocol.zig").contentDigest(source) },
        .source = source,
        .display = source,
    }});
    try std.testing.expectEqualStrings(table_fallback_start, feed.widgets.items[1].text);
    try std.testing.expectEqualStrings(source, feed.widgets.items[2].text);
    try std.testing.expectEqualStrings(source, feed.sourceAt(7, 0).?.source);
}
