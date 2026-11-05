//! Fixed-memory content chunks. The connection owns the streaming buffers;
//! a sink holds only framing state, out of line in Mysql.State.
const std = @import("std");
const wire = @import("../wire/mysql_connection.zig");
const literal = @import("../mysql_literal.zig");
const Failure = @import("../engine.zig").Failure;

pub const chunk_bytes = 128 * 1024;
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
const insert_prefix = "INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES({d},{d},X'";

fn serverFailure(code: u16) Failure {
    return switch (code) {
        1114, 1021 => error.CanonicalStorageFull,
        else => error.StatementFailed,
    };
}

/// Consume the entire response, including after an ERR. A wire error always
/// wins over a server error because the connection can no longer be reused.
fn finishInsert(connection: *wire.Connection, observer: Observer) Failure!u64 {
    var failure: ?Failure = null;
    var changed: ?u64 = null;
    while (!connection.isReady()) {
        const event = connection.next() catch return error.StoreConnectionLost;
        switch (event) {
            .ok => |ok| {
                if (changed != null) failure = error.CorruptStore;
                changed = ok.affected_rows;
            },
            .err => |err| {
                observer.report(err.code);
                failure = serverFailure(err.code);
            },
            .ready => {},
            else => failure = error.CorruptStore,
        }
    }
    if (failure) |err| return err;
    if (changed != 1) return error.CorruptStore;
    return 1;
}

fn beginChunk(connection: *wire.Connection, id: u64, index: u64, length: usize, observer: Observer) Failure!void {
    const size = std.fmt.count(insert_prefix, .{ id, index }) + length * 2 + 2;
    observer.content_query(observer.context);
    const writer = connection.beginQuery(size) catch return error.StoreConnectionLost;
    writer.print(insert_prefix, .{ id, index }) catch return error.StoreConnectionLost;
}

fn endChunk(connection: *wire.Connection, observer: Observer) Failure!u64 {
    connection.writer.writeAll("')") catch return error.StoreConnectionLost;
    connection.endQuery() catch return error.StoreConnectionLost;
    return finishInsert(connection, observer);
}

/// Called after the engine has flushed its deferred control and content row.
pub fn openSink(mysql: anytype, id: u64, length: u64, observer: Observer) Failure!ContentSink {
    try mysql.check();
    return mysql.state.sink.open(&mysql.state.connection, &mysql.state.failure, &mysql.state.changes, id, length, observer);
}

pub const SinkState = struct {
    connection: ?*wire.Connection = null,
    failure: *?Failure = undefined,
    changes: *i64 = undefined,
    observer: Observer = undefined,
    id: u64 = 0,
    length: u64 = 0,
    position: u64 = 0,
    /// Bytes still owed to the currently framed COM_QUERY; zero between chunks.
    remaining: usize = 0,

    pub fn open(self: *SinkState, connection: *wire.Connection, failure: *?Failure, changes: *i64, id: u64, length: u64, observer: Observer) Failure!ContentSink {
        std.debug.assert(self.connection == null);
        if (failure.*) |err| return err;
        self.* = .{ .connection = connection, .failure = failure, .changes = changes, .id = id, .length = length, .observer = observer };
        return self;
    }

    fn latch(self: *SinkState, err: Failure) void {
        // Preserve the server cause, except that a lost stream always wins.
        if (self.failure.* == null or err == error.StoreConnectionLost) self.failure.* = err;
    }

    fn append(self: *SinkState, bytes: []const u8) Failure!void {
        const connection = self.connection.?;
        var rest = bytes;
        while (rest.len > 0) {
            if (self.remaining == 0) {
                const n: usize = @intCast(@min(chunk_bytes, self.length - self.position));
                try beginChunk(connection, self.id, self.position / chunk_bytes, n, self.observer);
                self.remaining = n;
            }
            const n = @min(rest.len, self.remaining);
            literal.writeHex(&connection.writer, rest[0..n]) catch return error.StoreConnectionLost;
            self.remaining -= n;
            self.position += n;
            rest = rest[n..];
            if (self.remaining == 0) self.changes.* += @intCast(try endChunk(connection, self.observer));
        }
    }

    pub fn write(self: ContentSink, bytes: []const u8, offset: u64) error{ ContentWriteFailed, ContentTooLarge }!void {
        if (self.connection == null or self.failure.* != null) return error.ContentWriteFailed;
        if (offset > self.length or bytes.len > self.length - offset) {
            return error.ContentTooLarge;
        }
        if (offset != self.position) {
            return error.ContentWriteFailed;
        }
        self.append(bytes) catch |err| {
            self.latch(err);
            return error.ContentWriteFailed;
        };
    }

    pub fn close(self: ContentSink) void {
        const connection = self.connection orelse return;
        defer self.connection = null;
        if (self.remaining == 0 or connection.lost) return;
        // Finish only the already-framed chunk, not the rest of the content.
        // Its INSERT is rolled back by the caller's failed Access. Incomplete
        // input is not a connection failure: preserve the caller's ordinary
        // file/read error and keep rollback usable.
        const zeros: [128]u8 = @splat(0);
        while (self.remaining > 0) {
            const n = @min(self.remaining, zeros.len);
            literal.writeHex(&connection.writer, zeros[0..n]) catch {
                self.latch(error.StoreConnectionLost);
                return;
            };
            self.remaining -= n;
        }
        const changed = endChunk(connection, self.observer) catch |err| {
            self.latch(err);
            return;
        };
        self.changes.* += @intCast(changed);
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

test "content sink is one pointer and empty content frames no query" {
    try std.testing.expectEqual(@sizeOf(*SinkState), @sizeOf(ContentSink));
    const connection = try std.testing.allocator.create(wire.Connection);
    defer std.testing.allocator.destroy(connection);
    var failure: ?Failure = null;
    var changes: i64 = 0;
    var state: SinkState = .{};
    const sink = try state.open(connection, &failure, &changes, 1, 0, .{ .context = &changes, .server_error = ignoreTestServerError, .content_query = countTestContentQuery });
    try sink.write("", 0);
    sink.close();
    try std.testing.expect(state.connection == null);
    try std.testing.expect(failure == null);
    try std.testing.expectEqual(@as(i64, 0), changes);
}

test "content sink rejects nonsequential and oversized writes before framing" {
    const connection = try std.testing.allocator.create(wire.Connection);
    defer std.testing.allocator.destroy(connection);
    var failure: ?Failure = null;
    var changes: i64 = 0;
    var state: SinkState = .{};
    var sink = try state.open(connection, &failure, &changes, 1, 5, .{ .context = &changes, .server_error = ignoreTestServerError, .content_query = countTestContentQuery });
    try std.testing.expectError(error.ContentWriteFailed, sink.write("x", 1));
    try std.testing.expect(failure == null);
    sink.close();
    try std.testing.expect(failure == null);
    failure = null;
    sink = try state.open(connection, &failure, &changes, 1, 5, .{ .context = &changes, .server_error = ignoreTestServerError, .content_query = countTestContentQuery });
    try std.testing.expectError(error.ContentTooLarge, sink.write("123456", 0));
    try std.testing.expect(failure == null);
    sink.close();
    try std.testing.expect(failure == null);
    try std.testing.expectEqual(@as(i64, 0), changes);
}

fn ignoreTestServerError(_: *anyopaque, _: u16) void {}

fn countTestContentQuery(context: *anyopaque) void {
    const count: *i64 = @ptrCast(@alignCast(context));
    count.* += 1;
}
