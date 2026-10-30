//! Host-local memo of each Session's last encoded history span, on scratch
//! disk.
//!
//! A sealed request's `"input":[ … ]` history is a pure function of the
//! Session's history below its Operation's admission position, the selected
//! compaction anchor and the requested model. History below an admission
//! position never changes, so a later Operation of the same Session with the
//! same anchor and model encodes the same bytes for that prefix. When a
//! request seals, the span is copied from the request into the Session's
//! memo file with its digest, in chunks under the preparation's allowance;
//! the next request reads it back, checks the digest, and skips re-reading
//! and re-encoding every covered entry.
//!
//! Memory holds only a fixed-size index entry per Session, in entries the
//! owner preallocates; the bytes live in one scratch file per table slot,
//! opened only while a preparation copies from or into it. Nothing is
//! durable: a fresh Host deletes leftover memo files with its other owned
//! scratch, a stopping Host deletes them, and any mismatch or file failure
//! falls back to the full rebuild, which stays the source of truth. The table
//! is execution-thread-owned and used by the serial model preparation,
//! bounded by its entries and `byte_limit` of memo file bytes, and replaces
//! the least recently used Session.
const std = @import("std");
const protocol = @import("protocol.zig");
const named_scratch = @import("named_scratch.zig");

/// Default ceiling on memo file bytes. They are not charged to the request
/// scratch budget, whose idle use and request-to-response reuse are part of
/// the Host's observable accounting.
pub const default_byte_limit: u64 = 1024 * 1024 * 1024;

/// Non-cryptographic digest of a span's bytes. It detects a memo file that
/// changed behind the Host; the Store's authentication of each covered entry
/// happened when that entry was first encoded. Wyhash streams about 10 GB/s
/// here in ReleaseSafe; std's streaming XxHash3 measured 27 times slower.
pub const Hasher = std.hash.Wyhash;

/// Most bytes one `writeChunk` call copies; the caller owns a window this size.
pub const chunk_bytes = 16 * 1024;

pub fn newHasher() Hasher {
    return .init(0);
}

pub const Key = struct {
    session: protocol.Bounded(protocol.max_session_bytes),
    model: protocol.Bounded(protocol.max_model_bytes),
    anchor: ?u64,

    pub fn eql(self: *const Key, other: *const Key) bool {
        return self.session.eql(other.session.slice()) and
            self.model.eql(other.model.slice()) and
            self.anchor == other.anchor;
    }
};

/// One Session's index entry. The span bytes are in the slot's file.
pub const Memo = struct {
    key: Key,
    /// Admission position of the Operation whose view produced the span.
    admission_position: u64,
    /// Last history position the span covers.
    history_position: u64,
    /// The producing view's final tool-group scan cursor.
    tool_group_cursor: u64,
    /// Whether the span emitted any entry (the next one needs a comma).
    input_comma: bool,
    /// Exact span length; the file must have exactly this length.
    length: u64,
    /// `Hasher` digest of the span's bytes, set by `Table.commit`.
    digest: u64,

    /// The memo reproduces the prefix of a request with this key whose view
    /// ends at `admission`: same Session, model and anchor, and a view that
    /// contains the whole producing view.
    pub fn serves(self: *const Memo, key: *const Key, admission: u64) bool {
        return self.key.eql(key) and self.admission_position <= admission;
    }

    /// The same memo: every recorded fact, not just its Session.
    pub fn identical(self: *const Memo, other: *const Memo) bool {
        return self.key.eql(&other.key) and
            self.admission_position == other.admission_position and
            self.history_position == other.history_position and
            self.tool_group_cursor == other.tool_group_cursor and
            self.input_comma == other.input_comma and
            self.length == other.length and
            self.digest == other.digest;
    }
};

/// The memo a request copied as its span's prefix, with the digest state
/// after those bytes.
pub const Prefix = struct {
    memo: Memo,
    hasher: Hasher,
};

/// A span being written into its slot's file by `Table.begin`, one bounded
/// chunk at a time. It owns the open file until `commit` or `abandon`.
pub const Write = struct {
    slot: usize,
    file: std.Io.File,
    /// The memo kept once the whole span is written; its digest is set then.
    memo: Memo,
    /// Request offset of the span's first byte.
    span_start: u64,
    /// Span bytes already in the file, starting with any kept prefix.
    written: u64,
    /// The slot's counted file bytes while it is rewritten.
    peak: u64,
    /// Digest state of the span's first `written` bytes.
    hasher: Hasher,

    pub fn done(self: *const Write) bool {
        return self.written == self.memo.length;
    }
};

/// Where a new span's file write starts: after the held memo's bytes when
/// that exact memo was copied as the span's prefix, else from the start.
pub fn appendOffset(held: ?*const Memo, copied: ?*const Memo) u64 {
    const memo = copied orelse return 0;
    const current = held orelse return 0;
    return if (current.identical(memo)) memo.length else 0;
}

/// The slot holding `session`'s memo, if any.
pub fn sessionSlot(entries: []const Table.Entry, session: []const u8) ?usize {
    for (entries, 0..) |entry, slot| if (entry.memo) |memo| if (memo.key.session.eql(session)) return slot;
    return null;
}

/// The slot that receives a new memo for `session`: its current slot, else
/// an empty slot, else an unconfirmed removal (rewriting its file settles
/// it), else the least recently used one.
pub fn chooseSlot(entries: []const Table.Entry, session: []const u8) usize {
    std.debug.assert(entries.len != 0);
    if (sessionSlot(entries, session)) |slot| return slot;
    var stranded: ?usize = null;
    var oldest: ?usize = null;
    for (entries, 0..) |entry, slot| {
        if (entry.memo == null) {
            if (entry.file_bytes == 0) return slot;
            if (stranded == null) stranded = slot;
        } else if (oldest == null or entry.used < entries[oldest.?].used) oldest = slot;
    }
    return stranded orelse oldest.?;
}

/// The least recently used memo other than `except`, whose file to reclaim
/// under byte pressure.
pub fn nextVictim(entries: []const Table.Entry, except: usize) ?usize {
    var result: ?usize = null;
    for (entries, 0..) |entry, slot| {
        if (slot == except or entry.memo == null) continue;
        if (result == null or entry.used < entries[result.?].used) result = slot;
    }
    return result;
}

pub const Table = struct {
    /// A table slot. Zero bytes are an empty slot, so the owner may supply
    /// zero-mapped pages.
    pub const Entry = struct {
        memo: ?Memo = null,
        /// Bytes the slot's file may hold, counted in `Table.bytes` until its
        /// removal is confirmed. Equals the memo's length while one is held; a
        /// slot without a memo and with file bytes is an unconfirmed removal.
        file_bytes: u64 = 0,
        used: u64 = 0,
    };

    /// Preallocated by the owner, one per unit of execution capacity, and
    /// borrowed until `deinit`. Empty keeps nothing.
    entries: []Entry = &.{},
    byte_limit: u64 = default_byte_limit,
    scratch_path: []const u8 = "",
    /// Sum of the entries' `file_bytes`; never above `byte_limit`.
    bytes: u64 = 0,
    uses: u64 = 0,

    /// The Session's memo, if any.
    pub fn held(self: *const Table, session: []const u8) ?Memo {
        const slot = sessionSlot(self.entries, session) orelse return null;
        return self.entries[slot].memo.?;
    }

    /// Open the file of `memo`, which `held` returned. A file that is
    /// missing, unreadable or not exactly the recorded length loses the
    /// memo. The caller checks the digest as it reads.
    pub fn open(self: *Table, io: std.Io, memo: *const Memo) ?std.Io.File {
        const slot = self.slotOf(memo) orelse return null;
        var path_buffer: [path_capacity]u8 = undefined;
        const path = self.filePath(&path_buffer, slot) catch return self.drop(io, slot);
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return self.drop(io, slot);
        const length = file.length(io) catch {
            file.close(io);
            return self.drop(io, slot);
        };
        if (length != memo.length) {
            file.close(io);
            return self.drop(io, slot);
        }
        return file;
    }

    /// Drop `memo` if the table still holds it, and remove its file.
    pub fn forget(self: *Table, io: std.Io, memo: *const Memo) void {
        if (self.slotOf(memo)) |slot| _ = self.drop(io, slot);
    }

    /// Start keeping `next` for the Session whose span is
    /// `request[span_start..]`: reserve its slot and bytes and open its file.
    /// When `prefix` names the memo this request copied and the table still
    /// holds it, its file keeps those bytes and only the rest is appended.
    /// The caller then writes the span with `writeChunk` under its own
    /// allowance and ends with `commit` or `abandon`; until then the slot
    /// holds no memo and counts the larger of its old and new file lengths.
    /// Null keeps nothing. Any failure loses the memo and never the request.
    pub fn begin(self: *Table, io: std.Io, next: Memo, span_start: u64, prefix: ?*const Prefix) ?Write {
        if (self.entries.len == 0) return null;
        // Retry unconfirmed removals; a confirmed one releases its bytes.
        for (self.entries, 0..) |entry, slot| if (entry.memo == null and entry.file_bytes != 0) {
            _ = self.drop(io, slot);
        };
        const current = sessionSlot(self.entries, next.key.session.slice());
        const held_memo: ?*const Memo = if (current) |slot| &self.entries[slot].memo.? else null;
        // Model preparation is serial: nothing replaces or drops a memo
        // between a preparation's verified copy and its seal.
        if (prefix) |value| std.debug.assert(held_memo != null and held_memo.?.identical(&value.memo));
        const append = appendOffset(held_memo, if (prefix) |value| &value.memo else null);
        if (next.length > self.byte_limit) {
            if (current) |slot| _ = self.drop(io, slot);
            return null;
        }
        const slot = chooseSlot(self.entries, next.key.session.slice());
        const entry = &self.entries[slot];
        entry.memo = null;
        // While it is rewritten the file holds at most the larger length.
        const old = entry.file_bytes;
        const peak = @max(old, next.length);
        while (self.bytes - old + peak > self.byte_limit) {
            const victim = nextVictim(self.entries, slot);
            if (victim) |other| _ = self.drop(io, other);
            if (victim == null or self.entries[victim.?].file_bytes != 0) {
                // Only unconfirmed removals remain: keep the bound.
                _ = self.drop(io, slot);
                return null;
            }
        }
        self.bytes = self.bytes - old + peak;
        entry.file_bytes = peak;
        var write: Write = .{
            .slot = slot,
            .file = undefined,
            .memo = next,
            .span_start = span_start,
            .written = append,
            .peak = peak,
            .hasher = if (append != 0) prefix.?.hasher else newHasher(),
        };
        write.file = self.openWrite(io, &write) catch {
            _ = self.drop(io, slot);
            return null;
        };
        return write;
    }

    /// Copy the span's next bytes, at most `limit` and `window.len`, from
    /// `request` to the same offsets of the memo file through the caller's
    /// `window`, hashing them. Returns how many it copied; `write.done()`
    /// tells when the span is complete.
    pub fn writeChunk(_: *const Table, io: std.Io, write: *Write, request: std.Io.File, limit: usize, window: []u8) !usize {
        const count: usize = @intCast(@min(write.memo.length - write.written, limit, window.len));
        if (try request.readPositionalAll(io, window[0..count], write.span_start + write.written) != count) return error.EndOfStream;
        write.hasher.update(window[0..count]);
        try write.file.writePositionalAll(io, window[0..count], write.written);
        write.written += count;
        return count;
    }

    /// Keep the completely written span as its Session's memo.
    pub fn commit(self: *Table, io: std.Io, write: *Write) void {
        std.debug.assert(write.done());
        write.file.close(io);
        const entry = &self.entries[write.slot];
        self.bytes -= write.peak - write.memo.length;
        entry.file_bytes = write.memo.length;
        self.uses += 1;
        entry.used = self.uses;
        entry.memo = write.memo;
        entry.memo.?.digest = write.hasher.final();
    }

    /// Keep nothing of an unfinished span and reclaim its file.
    pub fn abandon(self: *Table, io: std.Io, write: *Write) void {
        write.file.close(io);
        _ = self.drop(io, write.slot);
    }

    /// Remove every memo file; the Host is stopping. A file whose removal
    /// is unconfirmed stays for the next Host's owned-scratch cleanup.
    pub fn deinit(self: *Table, io: std.Io) void {
        for (0..self.entries.len) |slot| _ = self.drop(io, slot);
        self.* = .{};
    }

    const path_capacity = protocol.max_store_bytes + 64;

    fn slotOf(self: *const Table, memo: *const Memo) ?usize {
        const slot = sessionSlot(self.entries, memo.key.session.slice()) orelse return null;
        return if (self.entries[slot].memo.?.identical(memo)) slot else null;
    }

    fn filePath(self: *const Table, buffer: []u8, slot: usize) ![]const u8 {
        var name_buffer: [64]u8 = undefined;
        const name = try named_scratch.NumericName.@"history-memo".format(&name_buffer, slot + 1, 1);
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.scratch_path, name });
    }

    /// Open the slot's file for `write`, keeping its first `written` bytes.
    /// A file that no longer has the prefix's length is rewritten whole.
    fn openWrite(self: *Table, io: std.Io, write: *Write) !std.Io.File {
        var path_buffer: [path_capacity]u8 = undefined;
        const file = try std.Io.Dir.cwd().createFile(io, try self.filePath(&path_buffer, write.slot), .{
            .truncate = false,
            .exclusive = false,
            .permissions = .fromMode(0o600),
        });
        errdefer file.close(io);
        if (write.written != 0 and try file.length(io) != write.written) {
            write.written = 0;
            write.hasher = newHasher();
        }
        try file.setLength(io, write.written);
        return file;
    }

    /// Drop the slot's memo and reclaim its file. Confirmed removal or
    /// absence releases the slot's bytes once; any other failure keeps them
    /// counted, and a later store, eviction or stop retries. Returns null so
    /// `open` can return it.
    fn drop(self: *Table, io: std.Io, slot: usize) ?std.Io.File {
        const entry = &self.entries[slot];
        entry.memo = null;
        if (entry.file_bytes == 0) return null;
        var path_buffer: [path_capacity]u8 = undefined;
        const file_path = self.filePath(&path_buffer, slot) catch return null;
        std.Io.Dir.cwd().deleteFile(io, file_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return null,
        };
        self.bytes -= entry.file_bytes;
        entry.file_bytes = 0;
        return null;
    }
};

fn testMemo(session: []const u8, model: []const u8, anchor: ?u64, admission_position: u64, length: u64) !Memo {
    var key: Key = .{ .session = .{}, .model = .{}, .anchor = anchor };
    try key.session.set(session);
    try key.model.set(model);
    return .{
        .key = key,
        .admission_position = admission_position,
        .history_position = admission_position - 1,
        .tool_group_cursor = 0,
        .input_comma = length != 0,
        .length = length,
        .digest = 0,
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

test "a span appends only to the exact memo it copied" {
    const copied = try testMemo("abc123", "model-a", null, 20, 9);
    try std.testing.expectEqual(@as(u64, 9), appendOffset(&copied, &copied));
    try std.testing.expectEqual(@as(u64, 0), appendOffset(&copied, null));
    try std.testing.expectEqual(@as(u64, 0), appendOffset(null, &copied));
    // Another memo of the same Session and length is not the copied one.
    var changed = copied;
    changed.admission_position = 21;
    try std.testing.expectEqual(@as(u64, 0), appendOffset(&changed, &copied));
    changed = copied;
    changed.digest = 1;
    try std.testing.expectEqual(@as(u64, 0), appendOffset(&changed, &copied));
    changed = copied;
    try changed.key.model.set("model-b");
    try std.testing.expectEqual(@as(u64, 0), appendOffset(&changed, &copied));
    changed = copied;
    changed.key.anchor = 3;
    try std.testing.expectEqual(@as(u64, 0), appendOffset(&changed, &copied));
}

test "a new memo takes its Session's slot, an empty slot, a stranded file, then the oldest" {
    var entries: [4]Table.Entry = @splat(.{});
    try std.testing.expectEqual(@as(usize, 0), chooseSlot(&entries, "a"));
    entries[0] = .{ .memo = try testMemo("a", "m", null, 2, 3), .file_bytes = 3, .used = 5 };
    entries[1] = .{ .memo = try testMemo("b", "m", null, 2, 3), .file_bytes = 3, .used = 2 };
    entries[2] = .{ .memo = try testMemo("c", "m", null, 2, 3), .file_bytes = 3, .used = 7 };
    try std.testing.expectEqual(@as(usize, 2), chooseSlot(&entries, "c"));
    try std.testing.expectEqual(@as(usize, 3), chooseSlot(&entries, "d"));
    entries[3] = .{ .memo = try testMemo("d", "m", null, 2, 3), .file_bytes = 3, .used = 9 };
    try std.testing.expectEqual(@as(usize, 1), chooseSlot(&entries, "e"));
    // An unconfirmed removal is rewritten before a memo is replaced, but
    // after an empty slot.
    entries[2] = .{ .file_bytes = 3 };
    try std.testing.expectEqual(@as(usize, 2), chooseSlot(&entries, "e"));
    entries[3] = .{};
    try std.testing.expectEqual(@as(usize, 3), chooseSlot(&entries, "e"));
}

test "byte pressure reclaims the least recently used other memo" {
    var entries: [3]Table.Entry = @splat(.{});
    try std.testing.expectEqual(@as(?usize, null), nextVictim(&entries, 0));
    entries[0] = .{ .memo = try testMemo("a", "m", null, 2, 3), .file_bytes = 3, .used = 1 };
    entries[1] = .{ .memo = try testMemo("b", "m", null, 2, 3), .file_bytes = 3, .used = 2 };
    try std.testing.expectEqual(@as(?usize, 0), nextVictim(&entries, 1));
    try std.testing.expectEqual(@as(?usize, 1), nextVictim(&entries, 0));
    // An unconfirmed removal is retried by each store, not chosen here.
    entries[0] = .{ .file_bytes = 4 };
    try std.testing.expectEqual(@as(?usize, null), nextVictim(&entries, 1));
    try std.testing.expectEqual(@as(?usize, 1), nextVictim(&entries, 2));
}

fn testFileBytes(table: *Table, session: []const u8, buffer: []u8) ![]const u8 {
    const memo = table.held(session) orelse return error.TestUnexpectedResult;
    const file = table.open(std.testing.io, &memo) orelse return error.TestUnexpectedResult;
    defer file.close(std.testing.io);
    const bytes = buffer[0..try file.readPositionalAll(std.testing.io, buffer, 0)];
    try std.testing.expectEqual(Hasher.hash(0, bytes), memo.digest);
    return bytes;
}

/// Keep `memo` through bounded chunks, as a preparation does.
fn testKeep(table: *Table, memo: Memo, request: std.Io.File, span_start: u64, prefix: ?*const Prefix) !void {
    var write = table.begin(std.testing.io, memo, span_start, prefix) orelse return;
    var window: [8]u8 = undefined;
    while (!write.done()) _ = table.writeChunk(std.testing.io, &write, request, 3, &window) catch |err| {
        table.abandon(std.testing.io, &write);
        return err;
    };
    table.commit(std.testing.io, &write);
}

test "the table keeps span files bounded by capacity and bytes and removes them" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const request = try tmp.dir.createFile(std.testing.io, "request", .{ .read = true });
    defer request.close(std.testing.io);
    try request.writePositionalAll(std.testing.io, "[aaaabbbbccdddddd", 0);
    var entries: [2]Table.Entry = @splat(.{});
    var table: Table = .{ .entries = &entries, .byte_limit = 10, .scratch_path = root };
    defer table.deinit(std.testing.io);
    try std.testing.expect(table.held("a") == null);
    try testKeep(&table, try testMemo("a", "m", null, 2, 4), request, 1, null);
    try testKeep(&table, try testMemo("b", "m", null, 2, 4), request, 5, null);
    // Capacity replaces the least recently used Session, a.
    try testKeep(&table, try testMemo("c", "m", null, 2, 2), request, 9, null);
    try std.testing.expect(table.held("a") == null);
    try std.testing.expectEqual(@as(u64, 6), table.bytes);
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("cc", try testFileBytes(&table, "c", &buffer));
    // Byte pressure evicts the oldest other Session, b.
    try testKeep(&table, try testMemo("d", "m", null, 2, 6), request, 11, null);
    try std.testing.expect(table.held("b") == null);
    try std.testing.expectEqualStrings("dddddd", try testFileBytes(&table, "d", &buffer));
    // A span larger than the whole bound is not kept.
    try testKeep(&table, try testMemo("e", "m", null, 2, 11), request, 1, null);
    try std.testing.expect(table.held("e") == null);
    // A memo that supplied the span's prefix gains only the appended rest,
    // and the digest continues from the prefix's state.
    try request.writePositionalAll(std.testing.io, "ccXY", 20);
    var prefix: Prefix = .{ .memo = table.held("c").?, .hasher = newHasher() };
    prefix.hasher.update("cc");
    try testKeep(&table, try testMemo("c", "m", null, 3, 4), request, 20, &prefix);
    try std.testing.expectEqualStrings("ccXY", try testFileBytes(&table, "c", &buffer));
    try std.testing.expectEqual(@as(u64, 10), table.bytes);
    // A file that lost its recorded length loses the memo and its file.
    const memo = table.held("c").?;
    var path_buffer: [Table.path_capacity]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, try table.filePath(&path_buffer, sessionSlot(&entries, "c").?), .{ .mode = .read_write });
    try file.setLength(std.testing.io, 3);
    file.close(std.testing.io);
    try std.testing.expect(table.open(std.testing.io, &memo) == null);
    try std.testing.expect(table.held("c") == null);
    try std.testing.expectEqual(@as(u64, 6), table.bytes);
    // Stopping removes every memo file.
    table.deinit(std.testing.io);
    var iterator = tmp.dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| try std.testing.expectEqualStrings("request", entry.name);
    // A Host without execution capacity keeps nothing.
    var empty: Table = .{ .scratch_path = root };
    try testKeep(&empty, try testMemo("a", "m", null, 2, 1), request, 1, null);
    try std.testing.expect(empty.held("a") == null);
}

test "an unconfirmed removal stays counted until a retry confirms it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const request = try tmp.dir.createFile(std.testing.io, "request", .{ .read = true });
    defer request.close(std.testing.io);
    try request.writePositionalAll(std.testing.io, "aaaabbbbbb", 0);
    var entries: [2]Table.Entry = @splat(.{});
    var table: Table = .{ .entries = &entries, .byte_limit = 10, .scratch_path = root };
    defer table.deinit(std.testing.io);
    try testKeep(&table, try testMemo("a", "m", null, 2, 4), request, 0, null);
    const memo = table.held("a").?;
    // A nonempty directory in place of the file cannot be removed: the
    // memo is lost but its slot's bytes stay counted.
    var name_buffer: [64]u8 = undefined;
    const name = try named_scratch.NumericName.@"history-memo".format(&name_buffer, 1, 1);
    try tmp.dir.deleteFile(std.testing.io, name);
    try tmp.dir.createDir(std.testing.io, name, .fromMode(0o700));
    var inner_buffer: [96]u8 = undefined;
    const inner = try std.fmt.bufPrint(&inner_buffer, "{s}/x", .{name});
    (try tmp.dir.createFile(std.testing.io, inner, .{})).close(std.testing.io);
    try std.testing.expect(table.open(std.testing.io, &memo) == null);
    try std.testing.expect(table.held("a") == null);
    try std.testing.expectEqual(@as(u64, 4), table.bytes);
    try std.testing.expectEqual(@as(u64, 4), entries[0].file_bytes);
    // The next store retries it; still unconfirmed and with no memo left to
    // evict, the new memo is not kept and the bound holds.
    try testKeep(&table, try testMemo("b", "m", null, 2, 7), request, 0, null);
    try std.testing.expect(table.held("b") == null);
    try std.testing.expectEqual(@as(u64, 4), table.bytes);
    // Once removable, the next retry confirms it and releases its bytes once.
    try tmp.dir.deleteFile(std.testing.io, inner);
    try tmp.dir.deleteDir(std.testing.io, name);
    try testKeep(&table, try testMemo("b", "m", null, 2, 7), request, 0, null);
    try std.testing.expectEqual(@as(u64, 7), table.held("b").?.length);
    try std.testing.expectEqual(@as(u64, 7), table.bytes);
}

test "an abandoned span keeps no memo and releases its bytes" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const request = try tmp.dir.createFile(std.testing.io, "request", .{ .read = true });
    defer request.close(std.testing.io);
    try request.writePositionalAll(std.testing.io, "aaaabbbbbbbbbb", 0);
    var entries: [2]Table.Entry = @splat(.{});
    var table: Table = .{ .entries = &entries, .byte_limit = 16, .scratch_path = root };
    defer table.deinit(std.testing.io);
    try testKeep(&table, try testMemo("a", "m", null, 2, 4), request, 0, null);
    try testKeep(&table, try testMemo("b", "m", null, 2, 4), request, 4, null);
    // A new span for a cold Session, which replaces the oldest memo a, and a
    // rewrite of a held one, each abandoned midway, keep no memo and count
    // no bytes of their own.
    var window: [8]u8 = undefined;
    var cold = table.begin(std.testing.io, try testMemo("c", "m", null, 2, 8), 4, null).?;
    try std.testing.expectEqual(@as(usize, 3), try table.writeChunk(std.testing.io, &cold, request, 3, &window));
    try std.testing.expectEqual(@as(u64, 4 + 8), table.bytes);
    table.abandon(std.testing.io, &cold);
    try std.testing.expect(table.held("a") == null);
    try std.testing.expect(table.held("c") == null);
    try std.testing.expectEqual(@as(u64, 4), table.held("b").?.length);
    try std.testing.expectEqual(@as(u64, 4), table.bytes);
    var rewrite = table.begin(std.testing.io, try testMemo("b", "m", null, 3, 10), 4, null).?;
    _ = try table.writeChunk(std.testing.io, &rewrite, request, 5, &window);
    table.abandon(std.testing.io, &rewrite);
    try std.testing.expect(table.held("b") == null);
    try std.testing.expectEqual(@as(u64, 0), table.bytes);
    var iterator = tmp.dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| try std.testing.expectEqualStrings("request", entry.name);
    // The table keeps the next span as usual.
    try testKeep(&table, try testMemo("b", "m", null, 3, 10), request, 4, null);
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("bbbbbbbbbb", try testFileBytes(&table, "b", &buffer));
    try std.testing.expectEqual(@as(u64, 10), table.bytes);
}
