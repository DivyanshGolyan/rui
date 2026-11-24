const std = @import("std");
const protocol = @import("protocol.zig");
const named_scratch = @import("named_scratch.zig");
const codecs = @import("codecs.zig");
const codec_abi = @import("codec_abi.zig");

pub const default_byte_limit: u64 = 1024 * 1024 * 1024;

pub const Hasher = std.hash.Wyhash;

pub const chunk_bytes = 16 * 1024;

pub fn newHasher() Hasher {
    return .init(0);
}

/// An owned Binding (see replay_binding.zig): the connection and the wire dialect a memo's
/// prefix was built for, and the requested model. A memo serves only the same Binding.
pub const Binding = struct {
    provider: protocol.Provider,
    dialect: codec_abi.Dialect,
    model: protocol.Bounded(protocol.max_model_bytes),

    pub fn eql(self: *const Binding, other: *const Binding) bool {
        return self.provider == other.provider and self.dialect == other.dialect and self.model.eql(other.model.slice());
    }
};

pub const Key = struct {
    session: protocol.Bounded(protocol.max_session_bytes),
    binding: Binding,
    anchor: ?u64,

    pub fn eql(self: *const Key, other: *const Key) bool {
        return self.session.eql(other.session.slice()) and
            self.binding.eql(&other.binding) and
            self.anchor == other.anchor;
    }
};

pub const View = struct {
    floor: u64,
    first_message: u64,
    base: u64,
    tool_set: u64,
};

pub const Memo = struct {
    key: Key,
    admission_position: u64,
    history_position: u64,
    tool_group_cursor: u64,
    view: View,
    carry: codecs.Carry,
    length: u64,
    digest: u64,

    pub fn serves(self: *const Memo, key: *const Key, admission: u64) bool {
        return self.key.eql(key) and self.admission_position <= admission;
    }

    pub fn identical(self: *const Memo, other: *const Memo) bool {
        return self.key.eql(&other.key) and
            self.admission_position == other.admission_position and
            self.history_position == other.history_position and
            self.tool_group_cursor == other.tool_group_cursor and
            std.meta.eql(self.view, other.view) and
            std.meta.eql(self.carry, other.carry) and
            self.length == other.length and
            self.digest == other.digest;
    }
};

pub const Prefix = struct {
    memo: Memo,
    hasher: Hasher,
};

pub const Write = struct {
    slot: usize,
    file: std.Io.File,
    memo: Memo,
    span_start: u64,
    written: u64,
    peak: u64,
    hasher: Hasher,

    pub fn done(self: *const Write) bool {
        return self.written == self.memo.length;
    }
};

pub fn appendOffset(held: ?*const Memo, copied: ?*const Memo) u64 {
    const memo = copied orelse return 0;
    const current = held orelse return 0;
    return if (current.identical(memo)) memo.length else 0;
}

pub fn sessionSlot(entries: []const Table.Entry, session: []const u8) ?usize {
    for (entries, 0..) |entry, slot| if (entry.memo) |memo| if (memo.key.session.eql(session)) return slot;
    return null;
}

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

pub fn nextVictim(entries: []const Table.Entry, except: usize) ?usize {
    var result: ?usize = null;
    for (entries, 0..) |entry, slot| {
        if (slot == except or entry.memo == null) continue;
        if (result == null or entry.used < entries[result.?].used) result = slot;
    }
    return result;
}

pub const Table = struct {
    pub const Entry = struct {
        memo: ?Memo = null,
        file_bytes: u64 = 0,
        used: u64 = 0,
    };

    entries: []Entry = &.{},
    byte_limit: u64 = default_byte_limit,
    scratch_path: []const u8 = "",
    bytes: u64 = 0,
    uses: u64 = 0,

    pub fn held(self: *const Table, session: []const u8) ?Memo {
        const slot = sessionSlot(self.entries, session) orelse return null;
        return self.entries[slot].memo.?;
    }

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

    pub fn forget(self: *Table, io: std.Io, memo: *const Memo) void {
        if (self.slotOf(memo)) |slot| _ = self.drop(io, slot);
    }

    pub fn begin(self: *Table, io: std.Io, next: Memo, span_start: u64, prefix: ?*const Prefix) ?Write {
        if (self.entries.len == 0) return null;
        for (self.entries, 0..) |entry, slot| if (entry.memo == null and entry.file_bytes != 0) {
            _ = self.drop(io, slot);
        };
        const current = sessionSlot(self.entries, next.key.session.slice());
        const held_memo: ?*const Memo = if (current) |slot| &self.entries[slot].memo.? else null;
        if (prefix) |value| std.debug.assert(held_memo != null and held_memo.?.identical(&value.memo));
        const append = appendOffset(held_memo, if (prefix) |value| &value.memo else null);
        if (next.length > self.byte_limit) {
            if (current) |slot| _ = self.drop(io, slot);
            return null;
        }
        const slot = chooseSlot(self.entries, next.key.session.slice());
        const entry = &self.entries[slot];
        entry.memo = null;
        const old = entry.file_bytes;
        const peak = @max(old, next.length);
        while (self.bytes - old + peak > self.byte_limit) {
            const victim = nextVictim(self.entries, slot);
            if (victim) |other| _ = self.drop(io, other);
            if (victim == null or self.entries[victim.?].file_bytes != 0) {
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

    pub fn writeChunk(_: *const Table, io: std.Io, write: *Write, request: std.Io.File, limit: usize, window: []u8) !usize {
        const count: usize = @intCast(@min(write.memo.length - write.written, limit, window.len));
        if (try request.readPositionalAll(io, window[0..count], write.span_start + write.written) != count) return error.EndOfStream;
        try appendChunk(io, write, window[0..count]);
        return count;
    }

    pub fn appendChunk(io: std.Io, write: *Write, bytes: []const u8) !void {
        std.debug.assert(bytes.len <= write.memo.length - write.written);
        write.hasher.update(bytes);
        try write.file.writePositionalAll(io, bytes, write.written);
        write.written += bytes.len;
    }

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

    pub fn abandon(self: *Table, io: std.Io, write: *Write) void {
        write.file.close(io);
        _ = self.drop(io, write.slot);
    }

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
    var key: Key = .{ .session = .{}, .binding = .{ .provider = .openai, .dialect = .openai_responses, .model = .{} }, .anchor = anchor };
    try key.session.set(session);
    try key.binding.model.set(model);
    return .{
        .key = key,
        .admission_position = admission_position,
        .history_position = admission_position - 1,
        .tool_group_cursor = 0,
        .view = .{ .floor = 0, .first_message = 0, .base = 0, .tool_set = 1 },
        .carry = codecs.initialCarry(.@"openai-responses/2", null),
        .length = length,
        .digest = 0,
    };
}

test "a memo serves only the same Session, model and anchor with a containing view" {
    const memo = try testMemo("abc123", "model-a", 7, 20, 1);
    var key = memo.key;
    try std.testing.expect(memo.serves(&key, 20));
    try std.testing.expect(memo.serves(&key, 21));
    try std.testing.expect(!memo.serves(&key, 19));
    key.anchor = 9;
    try std.testing.expect(!memo.serves(&key, 30));
    key.anchor = null;
    try std.testing.expect(!memo.serves(&key, 30));
    key = memo.key;
    try key.binding.model.set("model-b");
    try std.testing.expect(!memo.serves(&key, 30));
    key = memo.key;
    key.binding.dialect = .anthropic_messages;
    try std.testing.expect(!memo.serves(&key, 30));
    key = memo.key;
    key.binding.provider = .codex;
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
    var changed = copied;
    changed.admission_position = 21;
    try std.testing.expectEqual(@as(u64, 0), appendOffset(&changed, &copied));
    changed = copied;
    changed.digest = 1;
    try std.testing.expectEqual(@as(u64, 0), appendOffset(&changed, &copied));
    changed = copied;
    try changed.key.binding.model.set("model-b");
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
    try testKeep(&table, try testMemo("c", "m", null, 2, 2), request, 9, null);
    try std.testing.expect(table.held("a") == null);
    try std.testing.expectEqual(@as(u64, 6), table.bytes);
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("cc", try testFileBytes(&table, "c", &buffer));
    try testKeep(&table, try testMemo("d", "m", null, 2, 6), request, 11, null);
    try std.testing.expect(table.held("b") == null);
    try std.testing.expectEqualStrings("dddddd", try testFileBytes(&table, "d", &buffer));
    try testKeep(&table, try testMemo("e", "m", null, 2, 11), request, 1, null);
    try std.testing.expect(table.held("e") == null);
    try request.writePositionalAll(std.testing.io, "ccXY", 20);
    var prefix: Prefix = .{ .memo = table.held("c").?, .hasher = newHasher() };
    prefix.hasher.update("cc");
    try testKeep(&table, try testMemo("c", "m", null, 3, 4), request, 20, &prefix);
    try std.testing.expectEqualStrings("ccXY", try testFileBytes(&table, "c", &buffer));
    try std.testing.expectEqual(@as(u64, 10), table.bytes);
    const memo = table.held("c").?;
    var path_buffer: [Table.path_capacity]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, try table.filePath(&path_buffer, sessionSlot(&entries, "c").?), .{ .mode = .read_write });
    try file.setLength(std.testing.io, 3);
    file.close(std.testing.io);
    try std.testing.expect(table.open(std.testing.io, &memo) == null);
    try std.testing.expect(table.held("c") == null);
    try std.testing.expectEqual(@as(u64, 6), table.bytes);
    table.deinit(std.testing.io);
    var iterator = tmp.dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| try std.testing.expectEqualStrings("request", entry.name);
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
    try testKeep(&table, try testMemo("b", "m", null, 2, 7), request, 0, null);
    try std.testing.expect(table.held("b") == null);
    try std.testing.expectEqual(@as(u64, 4), table.bytes);
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
    try testKeep(&table, try testMemo("b", "m", null, 3, 10), request, 4, null);
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("bbbbbbbbbb", try testFileBytes(&table, "b", &buffer));
    try std.testing.expectEqual(@as(u64, 10), table.bytes);
}
