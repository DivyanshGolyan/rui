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
    var self: Self = .{ .io = io, .file = file, .tables = tables };
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
        for (columns.alignment[0..columns.count], 0..) |alignment, col| group.alignment[col] = @intFromEnum(alignment);
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
    try std.testing.expectEqual(@intFromEnum(table.Alignment.center), group.alignment[1]);
    try std.testing.expect((try index.tableAt(1)) == null);
    try std.testing.expectEqual(Mode.@"opaque", (try index.lineAt(5005)).?.mode);
    try std.testing.expectEqual(TableRole.none, (try index.lineAt(5006)).?.table_role);
    try std.testing.expectEqual(index.count * @sizeOf(Line), try index.file.length(io));
    try std.testing.expectEqual(@as(u64, @sizeOf(Table)), try index.tables.length(io));
    std.debug.print("rich-index source_bytes={d} lines={d} line_disk_bytes={d} table_disk_bytes={d}\n", .{ source_length, index.count, try index.file.length(io), try index.tables.length(io) });
}
