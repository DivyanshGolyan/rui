//! Host-local memo of each Session's last encoded history span, on scratch
//! disk.
//!
//! A sealed request's `"input":[ … ]` history is a pure function of the
//! Session's history below its Operation's admission position, the selected
//! compaction anchor and the requested model. History below an admission
//! position never changes, so a later Operation of the same Session with the
//! same anchor and model encodes the same bytes for that prefix. After a
//! successful seal the span is copied from the request into the Session's
//! memo file; the next request copies it back instead of re-reading and
//! re-encoding every entry.
//!
//! Memory holds only a fixed-size index entry per Session; the bytes live in
//! one scratch file per table slot, opened only while a preparation copies
//! from or into it. Nothing is durable: a fresh Host deletes leftover memo
//! files with its other owned scratch, a stopping Host deletes them, and any
//! mismatch or file failure falls back to the full rebuild, which stays the
//! source of truth. The table is execution-thread-owned, bounded by execution
//! capacity and `byte_limit` of memo file bytes, and replaces the least
//! recently used Session.
const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const named_scratch = @import("named_scratch.zig");

const allocator = std.heap.c_allocator;

/// Default ceiling on memo file bytes. They are not charged to the request
/// scratch budget, whose idle use and request-to-response reuse are part of
/// the Host's observable accounting.
pub const default_byte_limit: u64 = 1024 * 1024 * 1024;

pub const Key = struct {
    session: protocol.Bounded(protocol.max_session_bytes),
    model: protocol.Bounded(protocol.max_model_bytes),
    anchor: ?u64,
};

/// One Session's index entry. The span bytes are in the slot's file.
pub const Memo = struct {
    key: Key,
    /// Admission position of the Operation whose view produced the span.
    boundary: u64,
    /// Last history position the span covers.
    history_position: u64,
    /// The producing view's final tool-group scan cursor.
    tool_group_cursor: u64,
    /// Whether the span emitted any entry (the next one needs a comma).
    input_comma: bool,
    /// Exact span length; the file must have exactly this length.
    length: u64,

    /// The memo reproduces the prefix of a request with this key whose view
    /// ends at `admission`: same Session, model and anchor, and a view that
    /// contains the whole producing view.
    pub fn serves(self: *const Memo, key: *const Key, admission: u64) bool {
        return self.key.session.eql(key.session.slice()) and
            self.key.model.eql(key.model.slice()) and
            self.key.anchor == key.anchor and
            self.boundary <= admission;
    }
};

pub const Table = struct {
    capacity: usize = 0,
    byte_limit: u64 = default_byte_limit,
    scratch_path: []const u8 = "",
    entries: []Entry = &.{},
    bytes: u64 = 0,
    uses: u64 = 0,

    pub const Entry = struct {
        held: ?Memo = null,
        used: u64 = 0,
    };

    /// The Session's memo and its slot, if any.
    pub fn find(self: *Table, session: []const u8) ?struct { memo: Memo, slot: usize } {
        for (self.entries, 0..) |entry, slot| if (entry.held) |memo| if (memo.key.session.eql(session))
            return .{ .memo = memo, .slot = slot };
        return null;
    }

    /// Open the slot's file to read a memo that `find` returned. A file that
    /// is missing, unreadable or not exactly the recorded length loses the
    /// memo.
    pub fn open(self: *Table, io: std.Io, slot: usize) ?std.Io.File {
        const memo = self.entries[slot].held.?;
        var path_buffer: [path_capacity]u8 = undefined;
        const path = self.filePath(&path_buffer, slot) catch return self.forget(io, slot);
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return self.forget(io, slot);
        const length = file.length(io) catch {
            file.close(io);
            return self.forget(io, slot);
        };
        if (length != memo.length) {
            file.close(io);
            return self.forget(io, slot);
        }
        return file;
    }

    /// Drop the slot's memo and remove its file.
    pub fn forget(self: *Table, io: std.Io, slot: usize) ?std.Io.File {
        self.release(io, &self.entries[slot], slot);
        return null;
    }

    /// Keep `memo` for the Session whose span is `request[span_start..]`.
    /// When the Session's current memo supplied the first `prefix` bytes of
    /// that span and its file still holds exactly them, only the rest is
    /// appended. Any failure loses the memo and never the request.
    pub fn store(self: *Table, io: std.Io, memo: Memo, request: std.Io.File, span_start: u64, prefix: u64) void {
        if (self.capacity == 0) return;
        if (self.entries.len == 0) {
            const entries = allocator.alloc(Entry, self.capacity) catch return;
            @memset(entries, .{});
            self.entries = entries;
        }
        const existing = self.find(memo.key.session.slice());
        if (memo.length > self.byte_limit) {
            if (existing) |found| _ = self.forget(io, found.slot);
            return;
        }
        var append_from: u64 = 0;
        const slot = if (existing) |found| slot: {
            if (prefix != 0 and found.memo.length == prefix) append_from = prefix;
            self.bytes -= found.memo.length;
            self.entries[found.slot].held = null;
            break :slot found.slot;
        } else self.vacancy(io);
        while (self.bytes + memo.length > self.byte_limit) {
            const victim = self.oldest(slot) orelse break;
            self.release(io, &self.entries[victim], victim);
        }
        self.write(io, slot, request, span_start, memo.length, append_from) catch {
            self.removeFile(io, slot);
            self.entries[slot] = .{};
            return;
        };
        self.uses += 1;
        self.entries[slot] = .{ .held = memo, .used = self.uses };
        self.bytes += memo.length;
    }

    /// Remove every memo file; the Host is stopping.
    pub fn deinit(self: *Table, io: std.Io) void {
        for (self.entries, 0..) |*entry, slot| if (entry.held != null) self.release(io, entry, slot);
        allocator.free(self.entries);
        self.* = .{};
    }

    const path_capacity = protocol.max_store_bytes + 64;

    fn filePath(self: *const Table, buffer: []u8, slot: usize) ![]const u8 {
        var name_buffer: [64]u8 = undefined;
        const name = try named_scratch.NumericName.@"history-memo".format(&name_buffer, slot + 1, 1);
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.scratch_path, name });
    }

    fn write(self: *Table, io: std.Io, slot: usize, request: std.Io.File, span_start: u64, length: u64, append_from: u64) !void {
        var path_buffer: [path_capacity]u8 = undefined;
        const file = try std.Io.Dir.cwd().createFile(io, try self.filePath(&path_buffer, slot), .{
            .truncate = false,
            .exclusive = false,
            .permissions = .fromMode(0o600),
        });
        defer file.close(io);
        var from = append_from;
        if (from != 0 and try file.length(io) != from) from = 0;
        try file.setLength(io, from);
        while (from < length) {
            const copied = try copyRange(io, request, span_start + from, file, from, length - from);
            from += copied;
        }
    }

    /// An empty slot, else the least recently used one, emptied.
    fn vacancy(self: *Table, io: std.Io) usize {
        var result: usize = 0;
        for (self.entries, 0..) |entry, slot| {
            if (entry.held == null) return slot;
            if (entry.used < self.entries[result].used) result = slot;
        }
        self.release(io, &self.entries[result], result);
        return result;
    }

    fn oldest(self: *Table, except: usize) ?usize {
        var result: ?usize = null;
        for (self.entries, 0..) |entry, slot| {
            if (slot == except or entry.held == null) continue;
            if (result == null or entry.used < self.entries[result.?].used) result = slot;
        }
        return result;
    }

    fn release(self: *Table, io: std.Io, entry: *Entry, slot: usize) void {
        self.bytes -= entry.held.?.length;
        entry.* = .{};
        self.removeFile(io, slot);
    }

    /// Best effort: an undeletable file is overwritten by the slot's next
    /// memo and removed with other owned scratch when a Host starts.
    fn removeFile(self: *Table, io: std.Io, slot: usize) void {
        var path_buffer: [path_capacity]u8 = undefined;
        const file_path = self.filePath(&path_buffer, slot) catch return;
        std.Io.Dir.cwd().deleteFile(io, file_path) catch {};
    }
};

/// Copy up to `length` bytes between files at explicit offsets, in the
/// kernel where the platform allows it. Returns the count copied; reaching
/// the source's end first is an error.
pub fn copyRange(io: std.Io, source: std.Io.File, source_offset: u64, destination: std.Io.File, destination_offset: u64, length: u64) !usize {
    if (length == 0) return 0;
    if (builtin.os.tag == .linux) {
        var in_offset: i64 = @intCast(source_offset);
        var out_offset: i64 = @intCast(destination_offset);
        const wanted: usize = @intCast(@min(length, 1 << 30));
        const result = std.os.linux.copy_file_range(source.handle, &in_offset, destination.handle, &out_offset, wanted, 0);
        switch (std.os.linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.EndOfStream;
                return result;
            },
            // Unsupported here: fall back to reading and writing.
            .XDEV, .NOSYS, .OPNOTSUPP, .INVAL => {},
            .NOSPC => return error.NoSpaceLeft,
            else => return error.CopyFailed,
        }
    }
    var buffer: [16 * 1024]u8 = undefined;
    const count: usize = @intCast(@min(length, buffer.len));
    const read = try source.readPositionalAll(io, buffer[0..count], source_offset);
    if (read == 0) return error.EndOfStream;
    try destination.writePositionalAll(io, buffer[0..read], destination_offset);
    return read;
}

fn testMemo(session: []const u8, model: []const u8, anchor: ?u64, boundary: u64, length: u64) !Memo {
    var key: Key = .{ .session = .{}, .model = .{}, .anchor = anchor };
    try key.session.set(session);
    try key.model.set(model);
    return .{
        .key = key,
        .boundary = boundary,
        .history_position = boundary - 1,
        .tool_group_cursor = 0,
        .input_comma = length != 0,
        .length = length,
    };
}

test "a memo serves only the same Session, model and anchor with a containing view" {
    const memo = try testMemo("abc123", "model-a", 7, 20, 1);
    var key = memo.key;
    try std.testing.expect(memo.serves(&key, 20));
    try std.testing.expect(memo.serves(&key, 21));
    // An older frozen view, such as a retry of an earlier Operation.
    try std.testing.expect(!memo.serves(&key, 19));
    key.anchor = 9;
    try std.testing.expect(!memo.serves(&key, 30));
    key.anchor = null;
    try std.testing.expect(!memo.serves(&key, 30));
    key = memo.key;
    try key.model.set("model-b");
    try std.testing.expect(!memo.serves(&key, 30));
    key = memo.key;
    try key.session.set("abc124");
    try std.testing.expect(!memo.serves(&key, 30));
}

fn testFileBytes(table: *Table, slot: usize, buffer: []u8) ![]const u8 {
    const file = table.open(std.testing.io, slot) orelse return error.TestUnexpectedResult;
    defer file.close(std.testing.io);
    return buffer[0..try file.readPositionalAll(std.testing.io, buffer, 0)];
}

test "the table keeps span files bounded by capacity and bytes and removes them" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const request = try tmp.dir.createFile(std.testing.io, "request", .{ .read = true });
    defer request.close(std.testing.io);
    try request.writePositionalAll(std.testing.io, "[aaaabbbbccdddddd", 0);
    var table: Table = .{ .capacity = 2, .byte_limit = 10, .scratch_path = root };
    defer table.deinit(std.testing.io);
    try std.testing.expect(table.find("a") == null);
    table.store(std.testing.io, try testMemo("a", "m", null, 2, 4), request, 1, 0);
    table.store(std.testing.io, try testMemo("b", "m", null, 2, 4), request, 5, 0);
    // Capacity replaces the least recently used Session, a.
    table.store(std.testing.io, try testMemo("c", "m", null, 2, 2), request, 9, 0);
    try std.testing.expect(table.find("a") == null);
    try std.testing.expectEqual(@as(u64, 6), table.bytes);
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("cc", try testFileBytes(&table, table.find("c").?.slot, &buffer));
    // Byte pressure evicts the oldest other Session, b.
    table.store(std.testing.io, try testMemo("d", "m", null, 2, 6), request, 11, 0);
    try std.testing.expect(table.find("b") == null);
    try std.testing.expectEqualStrings("dddddd", try testFileBytes(&table, table.find("d").?.slot, &buffer));
    // A span larger than the whole bound is not kept.
    table.store(std.testing.io, try testMemo("e", "m", null, 2, 11), request, 1, 0);
    try std.testing.expect(table.find("e") == null);
    // A memo that supplied the span's prefix gains only the appended rest.
    try request.writePositionalAll(std.testing.io, "ccXY", 20);
    table.store(std.testing.io, try testMemo("c", "m", null, 3, 4), request, 20, 2);
    try std.testing.expectEqualStrings("ccXY", try testFileBytes(&table, table.find("c").?.slot, &buffer));
    try std.testing.expectEqual(@as(u64, 10), table.bytes);
    // A file that lost its recorded length loses the memo and its file.
    const slot = table.find("c").?.slot;
    var path_buffer: [Table.path_capacity]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, try table.filePath(&path_buffer, slot), .{ .mode = .read_write });
    try file.setLength(std.testing.io, 3);
    file.close(std.testing.io);
    try std.testing.expect(table.open(std.testing.io, slot) == null);
    try std.testing.expect(table.find("c") == null);
    try std.testing.expectEqual(@as(u64, 6), table.bytes);
    // Stopping removes every memo file.
    table.deinit(std.testing.io);
    var iterator = tmp.dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| try std.testing.expectEqualStrings("request", entry.name);
    // A Host without execution capacity keeps nothing.
    var empty: Table = .{ .scratch_path = root };
    empty.store(std.testing.io, try testMemo("a", "m", null, 2, 1), request, 1, 0);
    try std.testing.expect(empty.find("a") == null);
}

test "kernel and fallback copies move exact ranges and report a short source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try tmp.dir.createFile(std.testing.io, "source", .{ .read = true });
    defer source.close(std.testing.io);
    try source.writePositionalAll(std.testing.io, "0123456789", 0);
    const destination = try tmp.dir.createFile(std.testing.io, "destination", .{ .read = true });
    defer destination.close(std.testing.io);
    var copied: u64 = 0;
    while (copied < 6) copied += try copyRange(std.testing.io, source, 2 + copied, destination, 1 + copied, 6 - copied);
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("234567", buffer[1..try destination.readPositionalAll(std.testing.io, &buffer, 0)]);
    try std.testing.expectError(error.EndOfStream, copyRange(std.testing.io, source, 10, destination, 0, 4));
}
