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
    raw_start: u64,
    raw_end: u64,
    table_group: u64 = 0,
    mode: Mode,
    quote_depth: u8,
    quote_prefix: u8,
    table_role: TableRole = .none,
    reserved: [4]u8 = @splat(0),
};
const checkpoint_lines = 256;
const Checkpoint = extern struct {
    raw: u64,
    display: u64,
    mode: u8 = 0,
    run: u8 = 0,
    quote_bytes: u8 = 0,
    quote_depth: u8 = 0,
    quote_indent: u8 = 0,
    reserved: [3]u8 = @splat(0),

    fn encode(raw: usize, display: usize, context: markdown.Context) Checkpoint {
        var result: Checkpoint = .{ .raw = raw, .display = display };
        switch (context) {
            .plain => {},
            .fence => |fence| {
                result.mode = switch (fence.marker) {
                    .backtick => 1,
                    .tilde => 2,
                };
                result.run = fence.run orelse 0;
                if (fence.outer) |quote| {
                    result.quote_bytes = quote.bytes;
                    result.quote_depth = quote.depth;
                    result.quote_indent = quote.indent;
                }
            },
        }
        return result;
    }

    fn context(self: Checkpoint) !markdown.Context {
        if (self.mode == 0) return .plain;
        const marker: markdown.Fence.Marker = switch (self.mode) {
            1 => .backtick,
            2 => .tilde,
            else => return error.InvalidSourceRead,
        };
        const outer: ?markdown.Quote = if (self.quote_depth == 0) null else .{
            .bytes = self.quote_bytes,
            .depth = std.math.cast(u4, self.quote_depth) orelse return error.InvalidSourceRead,
            .indent = std.math.cast(u2, self.quote_indent) orelse return error.InvalidSourceRead,
        };
        return .{ .fence = .{ .marker = marker, .run = if (self.run == 0) null else self.run, .outer = outer } };
    }
};

pub const Table = extern struct {
    first: u64,
    end: u64,
    widths: [table.max_columns]u64 = @splat(0),
    alignment: [table.max_columns]u8 = @splat(0),
    count: u8,
    reserved: [7]u8 = @splat(0),
};

io: std.Io,
source: vaxis.unicode.PagedSource,
raw_source: vaxis.unicode.PagedSource,
file: std.Io.File,
tables: std.Io.File,
count: u64 = 0,
table_count: u64 = 0,
cancellation: ?*const client.Cancellation = null,
cache_base: u64 = 0,
cache_count: usize = 0,
cache_raw: usize = 0,
cache_display: usize = 0,
cache_context: markdown.Context = .plain,
cache: [checkpoint_lines]Line = undefined,

/// The source and its authenticated owner must outlive this disposable index.
/// Scanning is linear in source bytes and retains one bounded head and page.
pub fn build(io: std.Io, dir: std.Io.Dir, source: vaxis.unicode.PagedSource, cancellation: ?*const client.Cancellation) !Self {
    return buildRaw(io, dir, source, source, cancellation);
}

/// Syntax always comes from authenticated bytes; geometry addresses their
/// independently sanitized display projection. LF positions synchronize the
/// two streams without interpreting escaped control spellings as syntax.
pub fn buildRaw(io: std.Io, dir: std.Io.Dir, raw_source: vaxis.unicode.PagedSource, source: vaxis.unicode.PagedSource, cancellation: ?*const client.Cancellation) !Self {
    const file = try scratch(io, dir);
    errdefer file.close(io);
    const tables = try scratch(io, dir);
    errdefer tables.close(io);
    var self: Self = .{ .io = io, .source = source, .raw_source = raw_source, .file = file, .tables = tables, .cancellation = cancellation };
    var raw_reader: vaxis.unicode.PagedReader = .{ .source = raw_source };
    var reader: vaxis.unicode.PagedReader = .{ .source = source };
    var context: markdown.Context = .plain;
    var head: [markdown.head_limit]u8 = undefined;
    var head_len: usize = 0;
    var raw_start: usize = 0;
    var start: usize = 0;
    var at: usize = 0;
    var projected: usize = 0;
    while (at < raw_source.length) : (at += 1) {
        if (at % 4096 == 0) if (cancellation) |stop| if (stop.stopped.load(.acquire)) return error.Cancelled;
        const byte = (try raw_reader.readByte(at)) orelse return error.InvalidSourceRead;
        if (byte == '\n') {
            while (projected < source.length and (try reader.readByte(projected)).? != '\n') : (projected += 1) {
                if (projected % 4096 == 0) if (cancellation) |stop| if (stop.stopped.load(.acquire)) return error.Cancelled;
            }
            if (projected == source.length) return error.InvalidSourceRead;
            try self.append(&context, head[0..head_len], start, projected, projected + 1, raw_start, at, .line_feed);
            start = projected + 1;
            projected = start;
            raw_start = at + 1;
            head_len = 0;
        } else if (head_len < head.len) {
            head[head_len] = byte;
            head_len += 1;
        }
    }
    if (cancellation) |stop| if (stop.stopped.load(.acquire)) return error.Cancelled;
    if (raw_start < raw_source.length) {
        while (projected < source.length) : (projected += 1) {
            if ((try reader.readByte(projected)).? == '\n') return error.InvalidSourceRead;
            if (projected % 4096 == 0) if (cancellation) |stop| if (stop.stopped.load(.acquire)) return error.Cancelled;
        }
        try self.append(&context, head[0..head_len], start, source.length, source.length, raw_start, raw_source.length, .canonical_eof);
    } else if (start != source.length) return error.InvalidSourceRead;
    try self.indexTables(raw_source, cancellation);
    self.cancellation = null;
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

fn append(self: *Self, context: *markdown.Context, head: []const u8, start: usize, _: usize, _: usize, raw_start: usize, _: usize, ending: markdown.HeadEnding) !void {
    if (self.count % checkpoint_lines == 0) {
        const point = Checkpoint.encode(raw_start, start, context.*);
        try self.file.writeStreamingAll(self.io, std.mem.asBytes(&point));
    }
    const decision = switch (context.step(head, if (head.len == markdown.head_limit) .limit_cut else ending)) {
        .resolved => |value| value,
        .need_more => return error.InvalidSourceRead,
    };
    context.* = decision.next;
    self.count = try std.math.add(u64, self.count, 1);
}

/// Reconstruct at most one bounded checkpoint block from immutable raw and
/// projection files. A table interval adds presentation facts afterward.
pub fn lineAt(self_const: *const Self, index: u64) !?Line {
    const self = @constCast(self_const);
    if (index >= self.count) return null;
    const base = index / checkpoint_lines * checkpoint_lines;
    if (self.cache_count == 0 or self.cache_base != base) {
        var point: Checkpoint = undefined;
        const offset = try std.math.mul(u64, index / checkpoint_lines, @sizeOf(Checkpoint));
        if (try self.file.readPositionalAll(self.io, std.mem.asBytes(&point), offset) != @sizeOf(Checkpoint)) return error.TruncatedResponse;
        self.cache_base = base;
        self.cache_count = 0;
        self.cache_raw = std.math.cast(usize, point.raw) orelse return error.SourceTooLarge;
        self.cache_display = std.math.cast(usize, point.display) orelse return error.SourceTooLarge;
        self.cache_context = try point.context();
    }
    var raw_reader: vaxis.unicode.PagedReader = .{ .source = self.raw_source };
    var display_reader: vaxis.unicode.PagedReader = .{ .source = self.source };
    const wanted: usize = @intCast(index - base);
    while (self.cache_count <= wanted) {
        const raw_start = self.cache_raw;
        const start = self.cache_display;
        var head: [markdown.head_limit]u8 = undefined;
        var head_len: usize = 0;
        var raw_at = raw_start;
        while (raw_at < self.raw_source.length) : (raw_at += 1) {
            if (raw_at % 4096 == 0) if (self.cancellation) |stop| if (stop.stopped.load(.acquire)) return error.Cancelled;
            const byte = (try raw_reader.readByte(raw_at)) orelse return error.InvalidSourceRead;
            if (byte == '\n') break;
            if (head_len < head.len) {
                head[head_len] = byte;
                head_len += 1;
            }
        }
        var end = start;
        while (end < self.source.length) : (end += 1) {
            if (end % 4096 == 0) if (self.cancellation) |stop| if (stop.stopped.load(.acquire)) return error.Cancelled;
            if (((try display_reader.readByte(end)) orelse return error.InvalidSourceRead) == '\n') break;
        }
        const lf = raw_at < self.raw_source.length;
        if (lf != (end < self.source.length)) return error.InvalidSourceRead;
        const ending: markdown.HeadEnding = if (head_len == head.len) .limit_cut else if (lf) .line_feed else .canonical_eof;
        const decision = switch (self.cache_context.step(head[0..head_len], ending)) {
            .resolved => |value| value,
            .need_more => return error.InvalidSourceRead,
        };
        const quote = if (decision.projection.mode == .prose) decision.projection.quote else null;
        self.cache[self.cache_count] = .{
            .start = start,
            .end = end,
            .next = end + @intFromBool(lf),
            .raw_start = raw_start,
            .raw_end = raw_at,
            .mode = if (decision.projection.mode == .prose) .prose else .@"opaque",
            .quote_depth = if (quote) |value| value.depth else 0,
            .quote_prefix = if (quote) |value| value.bytes else 0,
        };
        self.cache_count += 1;
        self.cache_raw = raw_at + @intFromBool(lf);
        self.cache_display = end + @intFromBool(lf);
        self.cache_context = decision.next;
    }
    var line = self.cache[wanted];
    var low: u64 = 0;
    var high = self.table_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const group = (try self.tableAt(middle)) orelse return error.InvalidSourceRead;
        if (index < group.first) {
            high = middle;
            continue;
        }
        if (index >= group.end) {
            low = middle + 1;
            continue;
        }
        line.table_group = middle;
        line.table_role = if (index == group.first) .header else if (index == group.first + 1) .rule else .body;
        break;
    }
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
        const bytes = (try readLine(self.raw_source, line, &line_buffer)) orelse return error.InvalidSourceRead;
        const parsed = switch (table.parse(bytes, lineEnding(line), @intCast(group.count))) {
            .row => |value| value,
            else => return error.InvalidSourceRead,
        };
        for (parsed.cells[0..parsed.count], 0..) |cell, col| {
            if (col != 0) try painter.text(" │ ");
            var safe_buffer: [table.max_source_bytes * @import("TerminalText.zig").max_bytes_per_byte + 16]u8 = undefined;
            const value = try safeCell(bytes[cell.start..cell.end], &safe_buffer);
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
        const first = (try self.lineAt(i)).?;
        const delimiter = (try self.lineAt(i + 1)).?;
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
        var group: Table = .{ .first = i, .end = undefined, .count = columns.count };
        for (columns.alignment[0..columns.count], 0..) |alignment, col| group.alignment[col] = @backingInt(alignment);
        try measure(&group, header, first_row);
        var next = i + 2;
        while (next < self.count) : (next += 1) {
            if (cancellation) |stop| if (stop.stopped.load(.acquire)) return error.Cancelled;
            const line = (try self.lineAt(next)).?;
            if (!eligible(line)) break;
            const raw = (try readLine(source, line, &first_buf)) orelse break;
            const parsed = switch (table.parse(raw, lineEnding(line), columns.count)) {
                .row => |value| value,
                else => break,
            };
            if (!parsed.has_pipe) break;
            try measure(&group, raw, parsed);
        }
        group.end = next;
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
    const len = line.raw_end - line.raw_start;
    if (len > buffer.len) return null;
    var filled: usize = 0;
    while (filled < len) {
        const n = try source.readFn(source.userdata, line.raw_start + filled, buffer[filled..@intCast(len)]);
        if (n == 0 or n > len - filled) return error.InvalidSourceRead;
        filled += n;
    }
    return buffer[0..@intCast(len)];
}

fn safeCell(raw: []const u8, buffer: []u8) ![]const u8 {
    var terminal: @import("TerminalText.zig") = .{ .mode = .multiline };
    var writer: std.Io.Writer = .fixed(buffer);
    try terminal.feed(&writer, raw);
    try terminal.finish(&writer);
    return writer.buffered();
}

fn measure(group: *Table, raw: []const u8, row: table.Row) !void {
    const ctx: fw.DrawContext = .{ .arena = std.heap.page_allocator, .min = .{}, .max = .{}, .cell_size = .{} };
    var buffer: [table.max_source_bytes * @import("TerminalText.zig").max_bytes_per_byte + 16]u8 = undefined;
    for (row.cells[0..row.count], 0..) |cell, col| {
        const safe = try safeCell(raw[cell.start..cell.end], &buffer);
        group.widths[col] = @max(group.widths[col], ctx.hardLineWidth(safe));
    }
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
    try std.testing.expectEqual((try std.math.divCeil(u64, index.count, checkpoint_lines)) * @sizeOf(Checkpoint), try index.file.length(io));
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
    var table_seen = false;
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
            if (row.line_number == 6) table_seen = table_seen or (row.style.horizontal and row.style.custom);
            visited += 1;
        }
        if (!window.next()) break;
    }
    try std.testing.expectEqual(index.len, visited);
    try std.testing.expect(quote and table_seen and code_anchor != null);
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

test "native rich syntax uses exact raw CRLF not literal escape spelling" {
    fw.DrawContext.init(.unicode);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const raw_file = try tmp.dir.createFile(io, "raw", .{ .read = true });
    defer raw_file.close(io);
    const display_file = try tmp.dir.createFile(io, "display", .{ .read = true });
    defer display_file.close(io);
    const raw = "```zig\r\ncode\r\n```\r\nafter long prose\r\na | b\r\n--- | ---\r\nx | y\r\n```\n```\\x0d\nnot closed\n```\nafter real close\n";
    const display = "```zig\\x0d\ncode\\x0d\n```\\x0d\nafter long prose\\x0d\na | b\\x0d\n--- | ---\\x0d\nx | y\\x0d\n```\n```\\x0d\nnot closed\n```\nafter real close\n";
    try raw_file.writeStreamingAll(io, raw);
    try display_file.writeStreamingAll(io, display);
    const raw_backing: TestSource = .{ .io = io, .file = raw_file };
    const display_backing: TestSource = .{ .io = io, .file = display_file };
    const raw_source: vaxis.unicode.PagedSource = .{ .userdata = &raw_backing, .length = raw.len, .readFn = TestSource.read };
    const source: vaxis.unicode.PagedSource = .{ .userdata = &display_backing, .length = display.len, .readFn = TestSource.read };
    var rich = try Self.buildRaw(io, tmp.dir, raw_source, source, null);
    defer rich.close();
    try std.testing.expectEqual(Mode.@"opaque", (try rich.lineAt(2)).?.mode);
    try std.testing.expectEqual(Mode.prose, (try rich.lineAt(3)).?.mode);
    try std.testing.expectEqual(TableRole.header, (try rich.lineAt(4)).?.table_role);
    try std.testing.expectEqual(TableRole.rule, (try rich.lineAt(5)).?.table_role);
    try std.testing.expectEqual(TableRole.body, (try rich.lineAt(6)).?.table_role);
    // A literal backslash-x sequence is not a real CRLF closer.
    try std.testing.expectEqual(Mode.@"opaque", (try rich.lineAt(9)).?.mode);
    try std.testing.expectEqual(Mode.prose, (try rich.lineAt(11)).?.mode);
    var original: [raw.len]u8 = undefined;
    try std.testing.expectEqual(raw.len, try raw_file.readPositionalAll(io, &original, 0));
    try std.testing.expectEqualSlices(u8, raw, &original);
}

test "native rich checkpoints bound newline sidecar and recover both ends" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "raw", .{ .read = true });
    defer file.close(io);
    const chunk: [1000]u8 = @splat('\n');
    for (0..100) |_| try file.writeStreamingAll(io, &chunk);
    const backing: TestSource = .{ .io = io, .file = file };
    const source: vaxis.unicode.PagedSource = .{ .userdata = &backing, .length = 100_000, .readFn = TestSource.read };
    var rich = try Self.build(io, tmp.dir, source, null);
    defer rich.close();
    try std.testing.expectEqual(@as(u64, 100_000), rich.count);
    const bytes = try rich.file.length(io);
    try std.testing.expectEqual((try std.math.divCeil(u64, rich.count, checkpoint_lines)) * @sizeOf(Checkpoint), bytes);
    try std.testing.expect(bytes < 10_000);
    try std.testing.expectEqual(@as(u64, 99_999), (try rich.lineAt(99_999)).?.raw_start);
    try std.testing.expectEqual(@as(u64, 0), (try rich.lineAt(0)).?.raw_start);
    try std.testing.expectEqual(@as(u64, 50_001), (try rich.lineAt(50_001)).?.start);
    try std.testing.expectEqual(@as(u64, 0), try rich.tables.length(io));
    std.debug.print("newline-sidecar source=100000 checkpoints={d} cache_bytes={d}\n", .{ bytes, @sizeOf(@TypeOf(rich.cache)) });
}

test "native rich checkpoint restores fenced quote context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "raw", .{ .read = true });
    defer file.close(io);
    for (0..255) |_| try file.writeStreamingAll(io, "line\n");
    try file.writeStreamingAll(io, "> ```zig\n> code\n> ```\nafter\n");
    const length = try file.length(io);
    const backing: TestSource = .{ .io = io, .file = file };
    const source: vaxis.unicode.PagedSource = .{ .userdata = &backing, .length = @intCast(length), .readFn = TestSource.read };
    var rich = try Self.build(io, tmp.dir, source, null);
    defer rich.close();
    try std.testing.expectEqual(Mode.@"opaque", (try rich.lineAt(256)).?.mode);
    try std.testing.expectEqual(Mode.@"opaque", (try rich.lineAt(257)).?.mode);
    try std.testing.expectEqual(Mode.prose, (try rich.lineAt(258)).?.mode);
    try std.testing.expectEqual(Mode.prose, (try rich.lineAt(0)).?.mode);
    try std.testing.expectEqual(Mode.@"opaque", (try rich.lineAt(256)).?.mode);
}

test "native raw table cells display escaped controls without changing source" {
    fw.DrawContext.init(.unicode);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const raw_file = try tmp.dir.createFile(io, "raw", .{ .read = true });
    defer raw_file.close(io);
    const display_file = try tmp.dir.createFile(io, "display", .{ .read = true });
    defer display_file.close(io);
    const raw = "a\x1b | b\r\n--- | ---\r\nx | y\r\n";
    const display = "a\\x1b | b\\x0d\n--- | ---\\x0d\nx | y\\x0d\n";
    try raw_file.writeStreamingAll(io, raw);
    try display_file.writeStreamingAll(io, display);
    const raw_backing: TestSource = .{ .io = io, .file = raw_file };
    const display_backing: TestSource = .{ .io = io, .file = display_file };
    const raw_source: vaxis.unicode.PagedSource = .{ .userdata = &raw_backing, .length = raw.len, .readFn = TestSource.read };
    const source: vaxis.unicode.PagedSource = .{ .userdata = &display_backing, .length = display.len, .readFn = TestSource.read };
    var rich = try Self.buildRaw(io, tmp.dir, raw_source, source, null);
    defer rich.close();
    try std.testing.expectEqual(TableRole.header, (try rich.lineAt(0)).?.table_role);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 20, .height = 1 }, .cell_size = .{} };
    const surface = try drawTable(&rich, 0, ctx, 0, 20);
    try std.testing.expectEqualStrings("a", surface.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("\\", surface.readCell(1, 0).char.grapheme);
    try std.testing.expectEqualStrings("x", surface.readCell(2, 0).char.grapheme);
    try std.testing.expectEqualStrings("1", surface.readCell(3, 0).char.grapheme);
    try std.testing.expectEqualStrings("b", surface.readCell(4, 0).char.grapheme);
    var original: [raw.len]u8 = undefined;
    try std.testing.expectEqual(raw.len, try raw_file.readPositionalAll(io, &original, 0));
    try std.testing.expectEqualSlices(u8, raw, &original);
}
