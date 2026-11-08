//! Bounded streaming recognition of display-line structure. The projection is
//! immutable and terminal safe; this disposable, unlinked index stores only
//! line offsets and style facts, never source content.
const std = @import("std");
const vaxis = @import("vaxis");
const markdown = @import("markdown_prefix.zig");
const table = @import("table_row.zig");
const fw = vaxis.vxfw;
const client = @import("client.zig");
const Self = @This();

pub const Mode = enum(u8) { prose, @"opaque" };
pub const TableRole = enum(u8) { none, header, rule, body };
pub const Line = extern struct {
    start: u64,
    end: u64,
    next: u64,
    table_group: u64 = 0,
    mode: Mode,
    quote_depth: u8,
    quote_prefix: u8,
    table_role: TableRole = .none,
    reserved: [4]u8 = @splat(0),
};
pub const Table = extern struct {
    widths: [table.max_columns]u64 = @splat(0),
    alignment: [table.max_columns]u8 = @splat(0),
    count: u8,
    reserved: [7]u8 = @splat(0),
};

io: std.Io,
source: vaxis.unicode.PagedSource,
file: std.Io.File,
tables: std.Io.File,
count: u64 = 0,
table_count: u64 = 0,

/// The source and its authenticated owner must outlive this disposable index.
/// Scanning is linear in source bytes and retains one bounded head and page.
pub fn build(io: std.Io, dir: std.Io.Dir, source: vaxis.unicode.PagedSource, cancellation: ?*const client.Cancellation) !Self {
    const file = try scratch(io, dir);
    errdefer file.close(io);
    const tables = try scratch(io, dir);
    errdefer tables.close(io);
    var self: Self = .{ .io = io, .source = source, .file = file, .tables = tables };
    var reader: vaxis.unicode.PagedReader = .{ .source = source };
    var context: markdown.Context = .plain;
    var head: [markdown.head_limit]u8 = undefined;
    var head_len: usize = 0;
    var start: usize = 0;
    var at: usize = 0;
    while (at < source.length) : (at += 1) {
        if (at % 4096 == 0) if (cancellation) |stop| if (stop.stopped.load(.acquire)) return error.Cancelled;
        const byte = (try reader.readByte(at)) orelse return error.InvalidSourceRead;
        if (byte == '\n') {
            try self.append(&context, head[0..head_len], start, at, at + 1, .line_feed);
            start = at + 1;
            head_len = 0;
        } else if (head_len < head.len) {
            head[head_len] = byte;
            head_len += 1;
        }
    }
    if (cancellation) |stop| if (stop.stopped.load(.acquire)) return error.Cancelled;
    if (start < source.length) try self.append(&context, head[0..head_len], start, source.length, source.length, .canonical_eof);
    try self.indexTables(source, cancellation);
    return self;
}

fn scratch(io: std.Io, dir: std.Io.Dir) !std.Io.File {
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(io, &random);
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "rui-lines-{s}.tmp", .{std.fmt.bytesToHex(random, .lower)});
    const file = try dir.createFile(io, name, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
    errdefer file.close(io);
    try dir.deleteFile(io, name);
    return file;
}

fn append(self: *Self, context: *markdown.Context, head: []const u8, start: usize, end: usize, next: usize, ending: markdown.HeadEnding) !void {
    const decision = switch (context.step(head, if (head.len == markdown.head_limit) .limit_cut else ending)) {
        .resolved => |value| value,
        .need_more => return error.InvalidSourceRead,
    };
    context.* = decision.next;
    const quote = if (decision.projection.mode == .prose) decision.projection.quote else null;
    const record: Line = .{
        .start = start,
        .end = end,
        .next = next,
        .mode = if (decision.projection.mode == .prose) .prose else .@"opaque",
        .quote_depth = if (quote) |value| value.depth else 0,
        .quote_prefix = if (quote) |value| value.bytes else 0,
    };
    try self.file.writeStreamingAll(self.io, std.mem.asBytes(&record));
    self.count = try std.math.add(u64, self.count, 1);
}

pub fn lineAt(self: *const Self, index: u64) !?Line {
    if (index >= self.count) return null;
    var line: Line = undefined;
    const offset = try std.math.mul(u64, index, @sizeOf(Line));
    if (try self.file.readPositionalAll(self.io, std.mem.asBytes(&line), offset) != @sizeOf(Line)) return error.TruncatedResponse;
    return line;
}

/// The framework owns wrapping and visible row geometry; these callbacks
/// provide bounded domain style facts and table cell presentation only.
pub fn provider(self: *Self) fw.PagedText.LineProvider {
    return .{ .userdata = self, .lineFn = lineStyle, .drawHorizontalFn = drawTable };
}

fn lineStyle(raw: *const anyopaque, index: usize) !fw.PagedText.LineStyle {
    const self: *const Self = @ptrCast(@alignCast(raw));
    const line = (try self.lineAt(index)) orelse return error.InvalidSourceRead;
    return .{
        .horizontal = line.mode == .@"opaque" or line.table_role != .none,
        .quote_depth = @intCast(line.quote_depth),
        .quote_prefix = line.quote_prefix,
        .custom = line.table_role != .none,
    };
}

fn drawTable(raw: *const anyopaque, index: usize, ctx: fw.DrawContext, left: u64, width: u16) !fw.Surface {
    const self: *const Self = @ptrCast(@alignCast(raw));
    const line = (try self.lineAt(index)) orelse return error.InvalidSourceRead;
    if (line.table_role == .none) return error.InvalidSourceRead;
    const group = (try self.tableAt(line.table_group)) orelse return error.InvalidSourceRead;
    const placeholder: fw.Widget = .{ .userdata = @constCast(self), .drawFn = placeholderDraw };
    var surface = try fw.Surface.init(ctx.arena, placeholder, .{ .width = width, .height = 1 });
    const slots = try ctx.arena.alloc(?[]u8, width);
    @memset(slots, null);
    var painter: TablePainter = .{ .surface = surface, .ctx = ctx, .left = left, .width = width, .slots = slots };
    if (line.table_role == .rule) {
        for (group.widths[0..group.count], 0..) |columns, col| {
            if (col != 0) try painter.text("─┼─");
            painter.repeated("─", columns);
        }
    } else {
        var line_buffer: [table.max_source_bytes]u8 = undefined;
        const bytes = (try readLine(self.source, line, &line_buffer)) orelse return error.InvalidSourceRead;
        const parsed = switch (table.parse(bytes, lineEnding(line), @intCast(group.count))) {
            .row => |value| value,
            else => return error.InvalidSourceRead,
        };
        for (parsed.cells[0..parsed.count], 0..) |cell, col| {
            if (col != 0) try painter.text(" │ ");
            const value = bytes[cell.start..cell.end];
            const content_width = ctx.hardLineWidth(value);
            const padding = group.widths[col] - content_width;
            const leading: u64 = switch (group.alignment[col]) {
                @backingInt(table.Alignment.left) => 0,
                @backingInt(table.Alignment.right) => padding,
                @backingInt(table.Alignment.center) => padding / 2,
                else => return error.InvalidSourceRead,
            };
            painter.repeated(" ", leading);
            try painter.text(value);
            painter.repeated(" ", padding - leading);
        }
    }
    surface.scroll_width = painter.column;
    return surface;
}

fn placeholderDraw(_: *anyopaque, _: fw.DrawContext) std.mem.Allocator.Error!fw.Surface {
    unreachable;
}

const TablePainter = struct {
    surface: fw.Surface,
    ctx: fw.DrawContext,
    left: u64,
    width: u16,
    slots: []?[]u8,
    column: u64 = 0,

    fn repeated(self: *TablePainter, glyph: []const u8, count: u64) void {
        const end = self.column +| count;
        var visible = @max(self.column, self.left);
        const stop = @min(end, self.left +| self.width);
        while (visible < stop) : (visible += 1) self.surface.writeCell(@intCast(visible - self.left), 0, .{ .char = .{ .grapheme = glyph, .width = 1 } });
        self.column = end;
    }

    fn text(self: *TablePainter, value: []const u8) !void {
        var local: usize = 0;
        var iter = self.ctx.graphemeIterator(value);
        while (iter.next()) |item| {
            const bytes = item.bytes(value);
            const tab = std.mem.eql(u8, bytes, "\t");
            const cells: usize = if (tab) fw.DrawContext.tabWidth(local) else self.ctx.stringWidth(bytes);
            if (tab) {
                self.repeated(" ", cells);
            } else {
                const end = try std.math.add(u64, self.column, cells);
                if (self.column >= self.left and end <= self.left +| self.width and self.column - self.left < self.width) {
                    const target: usize = @intCast(self.column - self.left);
                    if (self.slots[target] == null) self.slots[target] = try self.ctx.arena.alloc(u8, table.max_source_bytes);
                    const stored = self.slots[target].?[0..bytes.len];
                    @memcpy(stored, bytes);
                    self.surface.writeCell(@intCast(target), 0, .{ .char = .{ .grapheme = stored, .width = @intCast(cells) } });
                }
                self.column = end;
            }
            local += cells;
        }
    }
};

fn indexTables(self: *Self, source: vaxis.unicode.PagedSource, cancellation: ?*const client.Cancellation) !void {
    var first_buf: [table.max_source_bytes]u8 = undefined;
    var second_buf: [table.max_source_bytes]u8 = undefined;
    var i: u64 = 0;
    while (i + 1 < self.count) {
        if (cancellation) |stop| if (stop.stopped.load(.acquire)) return error.Cancelled;
        var first = (try self.lineAt(i)).?;
        var delimiter = (try self.lineAt(i + 1)).?;
        if (!eligible(first) or !eligible(delimiter) or first.next == first.end) {
            i += 1;
            continue;
        }
        const header = (try readLine(source, first, &first_buf)) orelse {
            i += 1;
            continue;
        };
        const rule = (try readLine(source, delimiter, &second_buf)) orelse {
            i += 1;
            continue;
        };
        const columns = switch (table.header(header, rule, lineEnding(delimiter))) {
            .columns => |value| value,
            else => {
                i += 1;
                continue;
            },
        };
        const first_row = switch (table.parse(header, .line_feed, columns.count)) {
            .row => |value| value,
            else => return error.InvalidSourceRead,
        };
        var group: Table = .{ .count = columns.count };
        for (columns.alignment[0..columns.count], 0..) |alignment, col| group.alignment[col] = @backingInt(alignment);
        measure(&group, header, first_row);
        first.table_group = self.table_count;
        first.table_role = .header;
        delimiter.table_group = self.table_count;
        delimiter.table_role = .rule;
        try self.writeLine(i, first);
        try self.writeLine(i + 1, delimiter);
        var next = i + 2;
        while (next < self.count) : (next += 1) {
            if (cancellation) |stop| if (stop.stopped.load(.acquire)) return error.Cancelled;
            var line = (try self.lineAt(next)).?;
            if (!eligible(line)) break;
            const raw = (try readLine(source, line, &first_buf)) orelse break;
            const parsed = switch (table.parse(raw, lineEnding(line), columns.count)) {
                .row => |value| value,
                else => break,
            };
            if (!parsed.has_pipe) break;
            measure(&group, raw, parsed);
            line.table_group = self.table_count;
            line.table_role = .body;
            try self.writeLine(next, line);
        }
        try self.tables.writeStreamingAll(self.io, std.mem.asBytes(&group));
        self.table_count = try std.math.add(u64, self.table_count, 1);
        i = next;
    }
}

fn eligible(line: Line) bool {
    return line.mode == .prose and line.quote_depth == 0;
}

fn lineEnding(line: Line) table.Ending {
    return if (line.next > line.end) .line_feed else .canonical_eof;
}

fn readLine(source: vaxis.unicode.PagedSource, line: Line, buffer: *[table.max_source_bytes]u8) !?[]const u8 {
    const len = line.end - line.start;
    if (len > buffer.len) return null;
    var filled: usize = 0;
    while (filled < len) {
        const n = try source.readFn(source.userdata, line.start + filled, buffer[filled..@intCast(len)]);
        if (n == 0 or n > len - filled) return error.InvalidSourceRead;
        filled += n;
    }
    return buffer[0..@intCast(len)];
}

fn measure(group: *Table, raw: []const u8, row: table.Row) void {
    const ctx: fw.DrawContext = .{ .arena = std.heap.page_allocator, .min = .{}, .max = .{}, .cell_size = .{} };
    for (row.cells[0..row.count], 0..) |cell, col| group.widths[col] = @max(group.widths[col], ctx.hardLineWidth(raw[cell.start..cell.end]));
}

fn writeLine(self: *Self, index: u64, line: Line) !void {
    const offset = try std.math.mul(u64, index, @sizeOf(Line));
    try self.file.writePositionalAll(self.io, std.mem.asBytes(&line), offset);
}

pub fn tableAt(self: *const Self, index: u64) !?Table {
    if (index >= self.table_count) return null;
    var group: Table = undefined;
    const offset = try std.math.mul(u64, index, @sizeOf(Table));
    if (try self.tables.readPositionalAll(self.io, std.mem.asBytes(&group), offset) != @sizeOf(Table)) return error.TruncatedResponse;
    return group;
}

pub fn close(self: *Self) void {
    self.tables.close(self.io);
    self.file.close(self.io);
    self.* = undefined;
}

const TestSource = struct {
    io: std.Io,
    file: std.Io.File,
    fn read(raw: *const anyopaque, offset: u64, buffer: []u8) !usize {
        const self: *const TestSource = @ptrCast(@alignCast(raw));
        return self.file.readPositionalAll(self.io, buffer, offset);
    }
};

test "native rich line index keeps bounded quote and fenced source facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "display", .{ .read = true });
    defer file.close(io);
    const bytes = "> > quote\n```zig\ncode | literal\n```\nafter\n";
    try file.writeStreamingAll(io, bytes);
    const backing: TestSource = .{ .io = io, .file = file };
    const source: vaxis.unicode.PagedSource = .{ .userdata = &backing, .length = bytes.len, .readFn = TestSource.read };
    var stop: client.Cancellation = .{};
    stop.requestStop();
    try std.testing.expectError(error.Cancelled, Self.build(io, tmp.dir, source, &stop));
    var index = try Self.build(io, tmp.dir, source, null);
    defer index.close();
    try std.testing.expectEqual(@as(u64, 5), index.count);
    const quote = (try index.lineAt(0)).?;
    try std.testing.expectEqual(Mode.prose, quote.mode);
    try std.testing.expectEqual(@as(u8, 2), quote.quote_depth);
    try std.testing.expectEqualStrings("> > ", bytes[0..quote.quote_prefix]);
    for (1..4) |i| try std.testing.expectEqual(Mode.@"opaque", (try index.lineAt(i)).?.mode);
    try std.testing.expectEqual(Mode.prose, (try index.lineAt(4)).?.mode);
    try std.testing.expect((try index.lineAt(5)) == null);
    var original: [bytes.len]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try file.readPositionalAll(io, &original, 0));
    try std.testing.expectEqualSlices(u8, bytes, &original);
    var directory = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer directory.close(io);
    var entries = directory.iterate();
    const only = (try entries.next(io)).?;
    try std.testing.expectEqualStrings("display", only.name);
    try std.testing.expect((try entries.next(io)) == null);
}

test "native rich table index retains column facts without padded rows" {
    fw.DrawContext.init(.unicode);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "display", .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "before\na | b\n--- | :---:\n");
    for (0..5000) |_| try file.writeStreamingAll(io, "s | 界\n");
    const wide: [4000]u8 = @splat('W');
    try file.writeStreamingAll(io, &wide);
    try file.writeStreamingAll(io, " | X\n\n```\na | b\n--- | ---\n```\nafter\n");
    const source_length = try file.length(io);
    const backing: TestSource = .{ .io = io, .file = file };
    var index = try Self.build(io, tmp.dir, .{ .userdata = &backing, .length = @intCast(source_length), .readFn = TestSource.read }, null);
    defer index.close();
    try std.testing.expectEqual(@as(u64, 1), index.table_count);
    try std.testing.expectEqual(TableRole.header, (try index.lineAt(1)).?.table_role);
    try std.testing.expectEqual(TableRole.rule, (try index.lineAt(2)).?.table_role);
    try std.testing.expectEqual(TableRole.body, (try index.lineAt(5003)).?.table_role);
    const group = (try index.tableAt(0)).?;
    try std.testing.expectEqual(@as(u8, 2), group.count);
    try std.testing.expectEqual(@as(u64, 4000), group.widths[0]);
    try std.testing.expectEqual(@as(u64, 2), group.widths[1]);
    try std.testing.expectEqual(@backingInt(table.Alignment.center), group.alignment[1]);
    try std.testing.expect((try index.tableAt(1)) == null);
    try std.testing.expectEqual(Mode.@"opaque", (try index.lineAt(5005)).?.mode);
    try std.testing.expectEqual(TableRole.none, (try index.lineAt(5006)).?.table_role);
    try std.testing.expectEqual(index.count * @sizeOf(Line), try index.file.length(io));
    try std.testing.expectEqual(@as(u64, @sizeOf(Table)), try index.tables.length(io));
    std.debug.print("rich-index source_bytes={d} lines={d} line_disk_bytes={d} table_disk_bytes={d}\n", .{ source_length, index.count, try index.file.length(io), try index.tables.length(io) });
}

test "native paged rich rows retain quote rails and horizontal code and table" {
    fw.DrawContext.init(.unicode);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "display", .{ .read = true });
    defer file.close(io);
    const bytes = "before\n> quote words\n```zig\ncode_0123456789界END\n```\na | b\n--- | :---:\nx | 界\nafter\n";
    try file.writeStreamingAll(io, bytes);
    const backing: TestSource = .{ .io = io, .file = file };
    const source: vaxis.unicode.PagedSource = .{ .userdata = &backing, .length = bytes.len, .readFn = TestSource.read };
    var rich = try Self.build(io, tmp.dir, source, null);
    defer rich.close();
    var reader: vaxis.unicode.PagedReader = .{ .source = source };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{ .width = 12 }, .max = .{ .width = 12, .height = null }, .cell_size = .{} };
    var index = try fw.PagedText.Index.initStyled(&reader, ctx, 12, rich.provider());
    var quote_row: ?usize = null;
    var code_row: ?usize = null;
    var table_row: ?usize = null;
    for (0..index.len) |row| {
        const value = (try index.rowAt(row)).?;
        if (value.line_number == 1 and quote_row == null) quote_row = row;
        if (value.line_number == 3) code_row = row;
        if (value.line_number == 5) table_row = row;
    }
    const quote = try (try index.builder().itemAtIdxForDraw(quote_row.?, 0, ctx.arena)).?.draw(ctx);
    try std.testing.expectEqualStrings("│", quote.readCell(0, 0).char.grapheme);
    try std.testing.expect(quote.readCell(0, 0).style.dim);
    const code_widget = (try index.builder().itemAtIdxForDraw(code_row.?, 0, ctx.arena)).?;
    const code = try code_widget.drawHorizontalFn.?(code_widget.userdata, ctx, 15, 5);
    try std.testing.expectEqualStrings("界", code.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("D", code.readCell(4, 0).char.grapheme);
    const table_widget = (try index.builder().itemAtIdxForDraw(table_row.?, 0, ctx.arena)).?;
    const rendered = try table_widget.drawHorizontalFn.?(table_widget.userdata, ctx, 0, 12);
    try std.testing.expectEqualStrings("a", rendered.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("│", rendered.readCell(2, 0).char.grapheme);
    try std.testing.expectEqualStrings("b", rendered.readCell(4, 0).char.grapheme);
    try std.testing.expect(index.fault == null);
    var original: [bytes.len]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try file.readPositionalAll(io, &original, 0));
    try std.testing.expectEqualSlices(u8, bytes, &original);
}

const WindowTestSource = struct {
    window: *@import("NativeRowWindow.zig"),
    index: *fw.PagedText.Index,

    fn has(raw: *const anyopaque, row: usize, _: usize) bool {
        const self: *const @This() = @ptrCast(@alignCast(raw));
        return row < self.window.count();
    }

    fn build(raw: *const anyopaque, row: usize, cursor: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!?fw.Widget {
        const self: *const @This() = @ptrCast(@alignCast(raw));
        const global = self.window.global(row) orelse return null;
        return self.index.builder().itemAtIdxForDraw(global, cursor, arena);
    }
};

test "native rich source windows cross both directions and preserve resize anchor" {
    const RowWindow = @import("NativeRowWindow.zig");
    fw.DrawContext.init(.unicode);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "source", .{ .read = true });
    defer file.close(io);
    const bytes = "first paragraph words\n> quote one\n> quote two\n```zig\ncode_0123456789界END\n```\na | b\n--- | ---\nx | 界\nlast paragraph words\n";
    try file.writeStreamingAll(io, bytes);
    const backing: TestSource = .{ .io = io, .file = file };
    const source: vaxis.unicode.PagedSource = .{ .userdata = &backing, .length = bytes.len, .readFn = TestSource.read };
    var rich = try Self.build(io, tmp.dir, source, null);
    defer rich.close();
    var reader: vaxis.unicode.PagedReader = .{ .source = source };
    var layout: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer layout.deinit();
    const ctx: fw.DrawContext = .{ .arena = layout.allocator(), .min = .{ .width = 12 }, .max = .{ .width = 12, .height = 3 }, .cell_size = .{} };
    var index = try fw.PagedText.Index.initStyled(&reader, ctx, 12, rich.provider());
    var window = RowWindow.init(index.len, 3);
    var adapter: WindowTestSource = .{ .window = &window, .index = &index };
    const builder: fw.ScrollView.Builder = .{ .userdata = &adapter, .hasFn = WindowTestSource.has, .buildFrameFn = WindowTestSource.build };
    var visited: usize = 0;
    var quote = false;
    var code_anchor: ?usize = null;
    var table = false;
    while (true) {
        var frame: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer frame.deinit();
        var scroll: fw.ScrollView = .{ .children = .{ .builder = builder }, .item_count = window.count() };
        const drawn = try scroll.draw(.{ .arena = frame.allocator(), .min = .{}, .max = .{ .width = 12, .height = 3 }, .cell_size = .{} });
        try std.testing.expectEqual(@as(usize, window.count()), drawn.children.len);
        for (0..window.count()) |local| {
            const global = window.global(local).?;
            try std.testing.expectEqual(visited, global);
            const row = (try index.rowAt(global)).?;
            if (row.line_number == 1 or row.line_number == 2) quote = quote or row.style.quote_depth != 0;
            if (row.line_number == 4) {
                try std.testing.expect(row.style.horizontal);
                code_anchor = row.start;
            }
            if (row.line_number == 6) table = table or (row.style.horizontal and row.style.custom);
            visited += 1;
        }
        if (!window.next()) break;
    }
    try std.testing.expectEqual(index.len, visited);
    try std.testing.expect(quote and table and code_anchor != null);
    while (true) {
        var local = window.count();
        while (local != 0) {
            local -= 1;
            visited -= 1;
            try std.testing.expectEqual(visited, window.global(local).?);
        }
        if (!window.previous()) break;
    }
    try std.testing.expectEqual(@as(usize, 0), visited);
    var resized = try fw.PagedText.Index.initStyled(&reader, ctx, 6, rich.provider());
    const restored = (try resized.rowForOffset(code_anchor.?)).?;
    var resized_window = RowWindow.init(resized.len, 3);
    const local = resized_window.select(restored).?;
    try std.testing.expectEqual(restored, resized_window.global(local).?);
    const row = (try resized.rowAt(restored)).?;
    try std.testing.expectEqual(@as(usize, 4), row.line_number);
    try std.testing.expect(row.style.horizontal);
    var original: [bytes.len]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try file.readPositionalAll(io, &original, 0));
    try std.testing.expectEqualSlices(u8, bytes, &original);
}
