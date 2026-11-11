//! Fixed-memory content chunks. The connection owns the streaming buffers;
//! a sink holds only framing state, out of line in Mysql.State.
const std = @import("std");
const wire = @import("../wire/mysql_connection.zig");
const literal = @import("../mysql_literal.zig");
const Failure = @import("../engine.zig").Failure;

pub const chunk_bytes = @import("../schema.zig").content_chunk_bytes;
pub const ContentSink = *SinkState;

/// The core owns transaction state. Content responses report server errors
/// through this hook before mapping them, so deadlock transitions have one owner.
pub const Observer = struct {
    context: *anyopaque,
    server_error: *const fn (*anyopaque, u16) void,
    content_query: *const fn (*anyopaque) void,

    fn report(self: Observer, code: u16) void {
        self.server_error(self.context, code);
    }
};

/// A chunk INSERT's text before its payload's hex.
pub const insert_prefix = "INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES({d},{d},X'";
/// A chunk INSERT's text after its payload's hex, the batch's separator
/// included.
pub const insert_suffix = "');";

/// The batch text of a chunk INSERT whose payload is `n` bytes.
pub fn chunkStatementBytes(id: u64, index: u64, n: usize) usize {
    return std.fmt.count(insert_prefix, .{ id, index }) + 2 * n + insert_suffix.len;
}

fn serverFailure(code: u16) Failure {
    return switch (code) {
        1114, 1021 => error.CanonicalStorageFull,
        else => error.StatementFailed,
    };
}

/// Where a sink puts its chunk INSERTs: the Access whose transaction holds
/// the content row. `chunk` queues one INSERT of `n` payload bytes into the
/// open batch, after a round when the batch or its queue lacks room, and
/// returns the batch's writer with the text up to the payload written; the
/// Access steps its result in order with the rest of its round. When it
/// cannot, the Access records why and the sink fails.
pub const Host = @import("../engine.zig").ContentHost;

/// Opens a sink on the content row `id`, whose payload holds `length`
/// bytes. It sends nothing: each chunk rides the Access's batch.
pub fn openSink(state: *SinkState, id: u64, length: u64, host: Host) ContentSink {
    std.debug.assert(!state.open);
    state.* = .{ .open = true, .host = host, .id = id, .length = length };
    return state;
}

pub const SinkState = struct {
    open: bool = false,
    host: Host = undefined,
    id: u64 = 0,
    length: u64 = 0,
    position: u64 = 0,
    /// The writer of the chunk INSERT being written, and the payload bytes
    /// it still owes; null between chunks.
    writer: ?*std.Io.Writer = null,
    remaining: usize = 0,
    /// A chunk could not be queued: the Access holds the cause.
    failed: bool = false,

    fn append(self: *SinkState, bytes: []const u8) error{ContentWriteFailed}!void {
        var rest = bytes;
        while (rest.len > 0) {
            if (self.writer == null) {
                const n: usize = @intCast(@min(chunk_bytes, self.length - self.position));
                self.writer = try self.host.chunk(self.host.context, self.id, self.position / chunk_bytes, n);
                self.remaining = n;
            }
            const w = self.writer.?;
            const n = @min(rest.len, self.remaining);
            // The Access made room for the whole statement.
            literal.writeHex(w, rest[0..n]) catch unreachable;
            self.remaining -= n;
            self.position += n;
            rest = rest[n..];
            if (self.remaining == 0) self.endChunk();
        }
    }

    fn endChunk(self: *SinkState) void {
        self.writer.?.writeAll(insert_suffix) catch unreachable;
        self.writer = null;
    }

    pub fn write(self: ContentSink, bytes: []const u8, offset: u64) error{ ContentWriteFailed, ContentTooLarge }!void {
        if (!self.open or self.failed) return error.ContentWriteFailed;
        if (offset > self.length or bytes.len > self.length - offset) {
            return error.ContentTooLarge;
        }
        if (offset != self.position) {
            return error.ContentWriteFailed;
        }
        self.append(bytes) catch {
            self.failed = true;
            return error.ContentWriteFailed;
        };
    }

    /// Ends the sink. A chunk begun but not filled is padded with zeros so
    /// the batch stays whole text; the caller's failed Access drops it with
    /// the rest of its transaction.
    pub fn close(self: ContentSink) void {
        if (!self.open) return;
        defer self.* = .{};
        if (self.writer) |w| {
            const zeros: [128]u8 = @splat(0);
            while (self.remaining > 0) {
                const n = @min(self.remaining, zeros.len);
                literal.writeHex(w, zeros[0..n]) catch unreachable;
                self.remaining -= n;
            }
            self.endChunk();
        }
    }
};

const select_piece = "SELECT chunk_index,SUBSTRING(bytes,{d},{d}) AS part FROM content_chunk WHERE content_id={d} AND chunk_index={d}";
const select_start = "SELECT part FROM (";
const select_end = ") AS chunks ORDER BY chunk_index";

/// One COM_QUERY for all touched chunks; response bytes go straight to dest.
/// Normal domain windows touch one or two chunks, never a payload-sized buffer.
pub fn readRaw(connection: *wire.Connection, id: u64, offset: u64, dest: []u8, observer: Observer) Failure!void {
    if (dest.len == 0) return;
    if (dest.len > std.math.maxInt(u64) - offset) return error.RangeOutOfBounds;
    var size: usize = select_start.len + select_end.len;
    var position = offset;
    var left = dest.len;
    while (left > 0) {
        const n = @min(left, chunk_bytes - @as(usize, @intCast(position % chunk_bytes)));
        if (position != offset) size += " UNION ALL ".len;
        size += std.fmt.count(select_piece, .{ position % chunk_bytes + 1, n, id, position / chunk_bytes });
        position += n;
        left -= n;
    }
    observer.content_query(observer.context);
    const writer = connection.beginQuery(size) catch return error.StoreConnectionLost;
    writer.writeAll(select_start) catch return error.StoreConnectionLost;
    position = offset;
    left = dest.len;
    while (left > 0) {
        const n = @min(left, chunk_bytes - @as(usize, @intCast(position % chunk_bytes)));
        if (position != offset) writer.writeAll(" UNION ALL ") catch return error.StoreConnectionLost;
        writer.print(select_piece, .{ position % chunk_bytes + 1, n, id, position / chunk_bytes }) catch return error.StoreConnectionLost;
        position += n;
        left -= n;
    }
    writer.writeAll(select_end) catch return error.StoreConnectionLost;
    connection.endQuery() catch return error.StoreConnectionLost;
    var failure: ?Failure = null;
    var filled: usize = 0;
    var value_left: usize = 0;
    var rows: usize = 0;
    var columns: usize = 0;
    var awaiting_value = false;
    while (!connection.isReady()) {
        const event = connection.next() catch return error.StoreConnectionLost;
        switch (event) {
            .columns => |n| if (n != 1) {
                failure = error.CorruptStore;
            },
            .column => |column| {
                columns += 1;
                if (column.charset != 63) failure = error.CorruptStore;
                switch (column.type) {
                    .varchar, .var_string, .string, .tiny_blob, .medium_blob, .long_blob, .blob => {},
                    else => failure = error.CorruptStore,
                }
            },
            .row => {
                if (awaiting_value or value_left != 0) failure = error.CorruptStore;
                awaiting_value = true;
                rows += 1;
            },
            .value => |maybe_n| {
                if (!awaiting_value) failure = error.CorruptStore;
                awaiting_value = false;
                const n = maybe_n orelse 0;
                const at = offset + filled;
                const expected = @min(dest.len - filled, chunk_bytes - @as(usize, @intCast(at % chunk_bytes)));
                if (n != expected or n == 0) failure = error.CorruptStore;
                value_left = n;
            },
            .bytes => |bytes| {
                if (bytes.len > value_left or bytes.len > dest.len - filled) {
                    failure = error.CorruptStore;
                } else {
                    @memcpy(dest[filled..][0..bytes.len], bytes);
                    filled += bytes.len;
                    value_left -= bytes.len;
                }
            },
            .err => |err| {
                observer.report(err.code);
                failure = serverFailure(err.code);
            },
            .rows_end, .ready => {},
            else => failure = error.CorruptStore,
        }
    }
    if (failure) |err| return err;
    const expected_rows = (offset % chunk_bytes + dest.len - 1) / chunk_bytes + 1;
    if (filled != dest.len or value_left != 0 or awaiting_value or rows != expected_rows or columns != 1) return error.CorruptStore;
}

const TestHost = struct {
    buffer: [4096]u8 = undefined,
    writer: std.Io.Writer = undefined,
    chunks: usize = 0,

    fn chunk(context: *anyopaque, id: u64, index: u64, n: usize) error{ContentWriteFailed}!*std.Io.Writer {
        const self: *TestHost = @ptrCast(@alignCast(context));
        if (self.chunks == 0) self.writer = .fixed(&self.buffer);
        self.chunks += 1;
        self.writer.print(insert_prefix, .{ id, index }) catch unreachable;
        std.debug.assert(n <= self.writer.buffer.len);
        return &self.writer;
    }

    fn host(self: *TestHost) Host {
        return .{ .context = self, .chunk = chunk };
    }
};

test "content sink is one pointer and empty content queues no chunk" {
    try std.testing.expectEqual(@sizeOf(*SinkState), @sizeOf(ContentSink));
    var test_host: TestHost = .{};
    var state: SinkState = .{};
    const sink = openSink(&state, 1, 0, test_host.host());
    try sink.write("", 0);
    sink.close();
    try std.testing.expect(!state.open);
    try std.testing.expectEqual(@as(usize, 0), test_host.chunks);
}

test "content sink rejects nonsequential and oversized writes before queueing" {
    var test_host: TestHost = .{};
    var state: SinkState = .{};
    var sink = openSink(&state, 1, 5, test_host.host());
    try std.testing.expectError(error.ContentWriteFailed, sink.write("x", 1));
    sink.close();
    sink = openSink(&state, 1, 5, test_host.host());
    try std.testing.expectError(error.ContentTooLarge, sink.write("123456", 0));
    sink.close();
    try std.testing.expectEqual(@as(usize, 0), test_host.chunks);
}

test "a closed sink pads its unfinished chunk into whole text" {
    var test_host: TestHost = .{};
    var state: SinkState = .{};
    const sink = openSink(&state, 7, 3, test_host.host());
    try sink.write("a", 0);
    sink.close();
    try std.testing.expectEqualStrings("INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES(7,0,X'610000');", test_host.writer.buffered());
    try std.testing.expectEqual(chunkStatementBytes(7, 0, 3), test_host.writer.buffered().len);
}
