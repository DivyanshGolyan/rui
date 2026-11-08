//! Bounded streaming recognition of display-line structure. The projection is
//! immutable and terminal safe; this disposable, unlinked index stores only
//! line offsets and style facts, never source content.
const std = @import("std");
const vaxis = @import("vaxis");
const markdown = @import("markdown_prefix.zig");
const client = @import("client.zig");
const Self = @This();

pub const Mode = enum(u8) { prose, opaque };
pub const Line = extern struct {
    start: u64,
    end: u64,
    next: u64,
    mode: Mode,
    quote_depth: u8,
    quote_prefix: u8,
    reserved: [5]u8 = @splat(0),
};

io: std.Io,
file: std.Io.File,
count: u64 = 0,

/// The source and its authenticated owner must outlive this disposable index.
/// Scanning is linear in source bytes and retains one bounded head and page.
pub fn build(io: std.Io, dir: std.Io.Dir, source: vaxis.unicode.PagedSource, cancellation: ?*const client.Cancellation) !Self {
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(io, &random);
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "rui-lines-{s}.tmp", .{std.fmt.bytesToHex(random, .lower)});
    const file = try dir.createFile(io, name, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
    errdefer file.close(io);
    try dir.deleteFile(io, name);
    var self: Self = .{ .io = io, .file = file };
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
    return self;
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
        .mode = if (decision.projection.mode == .prose) .prose else .opaque,
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

pub fn close(self: *Self) void {
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
    for (1..4) |i| try std.testing.expectEqual(Mode.opaque, (try index.lineAt(i)).?.mode);
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
