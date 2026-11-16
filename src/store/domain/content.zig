const std = @import("std");
const command_reply = @import("../../command_reply.zig");
const conversation_read = @import("../../conversation_read.zig");
const content_string = @import("../../content_string.zig");
const content_custody = @import("../../content_custody.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const store_access = @import("../access.zig");
const Access = store_access.Access;
const rsql = @import("../rsql.zig");
const Faults = store_core.Faults;
const Ordinary = store_core.Ordinary;

pub const ContentReference = command_reply.ContentReference;

pub const ContentLocation = struct {
    store: *Store,
    content_id: i64,
    reference: ContentReference,
};

pub const DigestCheck = struct {
    hash: @TypeOf(content_string.hasher()) = content_string.hasher(),
    position: u64 = 0,
    verified: bool = false,

    pub fn absorb(check: *DigestCheck, reference: ContentReference, start: u64, bytes: []const u8) bool {
        if (check.verified or start > check.position or start + bytes.len < check.position) return true;
        check.hash.update(bytes[@intCast(check.position - start)..]);
        check.position = start + bytes.len;
        if (check.position != reference.length) return true;
        check.verified = true;
        return std.mem.eql(u8, &check.hash.finalResult(), &reference.digest);
    }
};

pub const verified_window_bytes = 2048;

pub noinline fn streamVerified(a: anytype, content_id: u64, reference: ContentReference, sink: anytype) !void {
    var buffer: [verified_window_bytes]u8 = undefined;
    var windows: Windows = .{ .content_id = content_id, .reference = reference, .buffer = &buffer };
    while (try windows.next(a)) try sink.write(try windows.window());
}

pub const Windows = struct {
    content_id: u64,
    reference: ContentReference,
    buffer: []u8,
    check: DigestCheck = .{},
    offset: u64 = 0,
    length: usize = 0,

    pub fn next(windows: *Windows, a: anytype) !bool {
        windows.offset += windows.length;
        windows.length = 0;
        if (windows.offset >= windows.reference.length) return false;
        windows.length = @intCast(@min(windows.buffer.len, windows.reference.length - windows.offset));
        try a.readRaw(windows.content_id, windows.offset, windows.buffer[0..windows.length]);
        return true;
    }

    pub fn window(windows: *Windows) ![]const u8 {
        const bytes = windows.buffer[0..windows.length];
        if (!windows.check.absorb(windows.reference, windows.offset, bytes)) return error.CorruptStore;
        return bytes;
    }
};

pub const ContentWindow = struct {
    content_id: i64,
    reference: ContentReference,
    allocator: std.mem.Allocator = std.heap.c_allocator,
    prefetch: ?[]u8 = null,
    prefetch_source: i64 = 0,
    prefetch_start: u64 = 0,
    prefetch_length: usize = 0,
    check: DigestCheck = .{},
    first: u64 = 0,
    inline_bytes: ?[]const u8 = null,

    pub fn of(content_id: i64, reference: ContentReference) ContentWindow {
        return .{ .content_id = content_id, .reference = reference };
    }

    fn prepareRead(self: *ContentWindow, start: u64, wanted: usize) void {
        const left = self.reference.length - start;
        if (self.prefetch == null and left > wanted) {
            const size: usize = @intCast(@min(content_prefetch_bytes, left));
            // Raw: a read fills the window before any byte of it is used;
            // alloc would first write 0xAA over all of it in ReleaseSafe.
            if (self.allocator.rawAlloc(size, .of(u8), @returnAddress())) |bytes|
                self.prefetch = bytes[0..size];
        }
    }

    pub fn fills(self: *const ContentWindow, start: u64, destination: []u8) !usize {
        if (destination.len > ContentReader.content_window_bytes) return error.WindowTooLarge;
        if (start > self.reference.length) return error.RangeOutOfBounds;
        return @intCast(@min(destination.len, self.reference.length - start));
    }

    pub fn copyInline(self: *const ContentWindow, start: u64, destination: []u8, count: usize) bool {
        const bytes = self.inline_bytes orelse return false;
        @memcpy(destination[0..count], bytes[@intCast(start)..][0..count]);
        return true;
    }

    pub fn absorb(self: *ContentWindow, start: u64, bytes: []const u8) bool {
        return self.check.absorb(self.reference, start, bytes);
    }

    pub fn release(self: *ContentWindow) void {
        // Raw, as allocated: free would write 0xAA over the window first.
        if (self.prefetch) |bytes| self.allocator.rawFree(bytes, .of(u8), @returnAddress());
        self.prefetch = null;
    }
};

pub const ContentReader = struct {
    pub const content_window_bytes = 64 * 1024;

    window: ContentWindow,
    store: *Store,
    active: bool = true,

    pub fn open(self: *ContentReader, location: ContentLocation) void {
        self.* = .{ .window = .of(location.content_id, location.reference), .store = location.store };
    }

    pub fn read(self: *ContentReader, start: u64, destination: []u8) !usize {
        std.debug.assert(self.active);
        return readContent(self.store, &self.window, start, destination);
    }

    pub fn readWithAccess(self: *ContentReader, a: anytype, start: u64, destination: []u8) !usize {
        std.debug.assert(self.active and a.store == self.store);
        const wanted = try self.window.fills(start, destination);
        try readWindow(a, &self.window, start, destination[0..wanted]);
        if (!self.window.absorb(start, destination[0..wanted])) return error.CorruptStore;
        if (@import("builtin").is_test) _ = self.store.testing_content_work.read.fetchAdd(wanted, .monotonic);
        return wanted;
    }

    pub fn readRange(self: *ContentReader, start: u64, destination: []u8) !usize {
        std.debug.assert(self.active and destination.len > 0);
        if (destination.len > content_window_bytes) return error.WindowTooLarge;
        if (start > self.window.reference.length) return error.RangeOutOfBounds;
        return self.read(start, destination);
    }

    pub fn close(self: *ContentReader) void {
        std.debug.assert(self.active);
        self.window.release();
        self.active = false;
        if (@import("builtin").is_test) _ = self.store.testing_content_work.closes.fetchAdd(1, .monotonic);
    }
};

pub const lookup_content = rsql.Read(.{
    .sql = "SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=?3",
    .Args = struct { digest: [32]u8, length: u64, private: bool },
    .Row = struct { content_id: rsql.Positive },
    .cardinality = .optional,
});

const insert_content = rsql.Write(.{
    .sql = "INSERT INTO content(content_id,digest,byte_length,payload,private) VALUES(?1,?2,?3,zeroblob(?3),?4)",
    .Args = struct { content_id: u64, digest: [32]u8, length: u64, private: bool },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

pub const Import = struct {
    digest: [32]u8,
    length: u64,
    private: bool,
    found: lookup_content.Result = null,

    pub fn ofBytes(bytes: []const u8, private: bool) Import {
        return .{ .digest = content_string.digest(bytes), .length = bytes.len, .private = private };
    }
};

pub const empty_content: Import = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk .ofBytes("", false);
};

pub noinline fn lookup(a: anytype, value: *Import) void {
    a.read(lookup_content, .{ .digest = value.digest, .length = value.length, .private = value.private }, &value.found);
}

const lookup_pair = rsql.Read(.{
    .sql = "SELECT (SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=?3) AS first," ++
        "(SELECT content_id FROM content WHERE digest=?4 AND byte_length=?5 AND private=?6) AS second",
    .Args = struct { first_digest: [32]u8, first_length: u64, first_private: bool, second_digest: [32]u8, second_length: u64, second_private: bool },
    .Row = struct { first: ?rsql.Positive, second: ?rsql.Positive },
    .cardinality = .one,
});

pub const Pair = lookup_pair.Result;

pub fn lookupPair(a: anytype, first: *const Import, second: *const Import, rows: *Pair) void {
    a.read(lookup_pair, .{
        .first_digest = first.digest,
        .first_length = first.length,
        .first_private = first.private,
        .second_digest = second.digest,
        .second_length = second.length,
        .second_private = second.private,
    }, rows);
}

pub fn foundPair(rows: *const Pair, first: *Import, second: *Import) void {
    first.found = if (rows.first) |id| .{ .content_id = id } else null;
    second.found = if (rows.second) |id| .{ .content_id = id } else null;
}

const ContentSlot = struct { id: i64, existing: bool };

fn adoptInserted(a: anytype, value: *Import) void {
    if (value.found == null) if (a.insertedContent(&value.digest, value.length, value.private)) |id| {
        value.found = .{ .content_id = .of(id) };
    };
}

pub fn importSlot(a: anytype, value: *Import) !ContentSlot {
    return acquireSlot(a, value, .tracked);
}

fn acquireSlot(a: anytype, value: *Import, policy: enum { tracked, sequential }) !ContentSlot {
    if (policy == .tracked) adoptInserted(a, value);
    if (value.found) |row| return .{ .id = @intCast(row.content_id.get()), .existing = true };
    const id = try insertRow(a, value);
    if (policy == .tracked) a.recordInserted(&value.digest, value.length, value.private, id);
    value.found = .{ .content_id = .of(id) };
    return .{ .id = @intCast(id), .existing = false };
}

pub fn insertRow(a: anytype, value: *const Import) !u64 {
    const id = try a.identity(.content_id);
    a.write(insert_content, .{ .content_id = id, .digest = value.digest, .length = value.length, .private = value.private });
    a.recordContentRow(id);
    return id;
}

pub fn importBytes(a: anytype, value: *Import, bytes: []const u8) !u64 {
    std.debug.assert(bytes.len == value.length);
    const slot = try importSlot(a, value);
    if (!slot.existing) a.writeContent(@intCast(slot.id), bytes);
    return @intCast(slot.id);
}

pub fn openContentIdentity(self: *Store, reference: ContentReference, private: bool) !ContentLocation {
    return self.queue().run(openContentIdentityHeld, .{ self, reference, private });
}

fn openContentIdentityHeld(self: *Store, reference: ContentReference, private: bool) !ContentLocation {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    const id = try entry.finish(Ordinary.none, readContentId(&entry, reference, private));
    return .{ .store = self, .reference = reference, .content_id = id };
}

noinline fn readContentId(entry: *const store_core.Entry, reference: ContentReference, private: bool) !i64 {
    var a: Access(.read, error{}) = .open(entry);
    defer a.deinit();
    return contentIdOf(&a, reference, private);
}

pub fn contentIdOf(a: anytype, reference: ContentReference, private: bool) !i64 {
    var found: lookup_content.Result = undefined;
    a.read(lookup_content, .{ .digest = reference.digest, .length = reference.length, .private = private }, &found);
    try store_access.runAs(a, error.CorruptStore);
    const row = found orelse return error.CorruptStore;
    return @intCast(row.content_id.get());
}

pub fn readContent(self: *Store, window: *ContentWindow, start: u64, destination: []u8) !usize {
    const count = try readOwnedContent(self, window, start, destination);
    if (!window.absorb(start, destination[0..count])) return store_core.fence(self, error.CorruptStore);
    return count;
}

fn readOwnedContent(self: *Store, window: *ContentWindow, start: u64, destination: []u8) !usize {
    const wanted = try window.fills(start, destination);
    if (!window.copyInline(start, destination, wanted)) {
        if (wanted != 0) window.prepareRead(start, wanted);
        try self.queue().run(readOwnedContentHeld, .{ self, window, start, destination[0..wanted] });
    }
    if (@import("builtin").is_test) _ = self.testing_content_work.read.fetchAdd(wanted, .monotonic);
    return wanted;
}

fn readOwnedContentHeld(self: *Store, window: *ContentWindow, start: u64, destination: []u8) !void {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var a: Access(.read, error{}) = .open(&entry);
    defer a.deinit();
    try entry.finish(Ordinary.none, readWindow(&a, window, start, destination));
}

fn readWindow(a: anytype, window: *ContentWindow, start: u64, destination: []u8) !void {
    if (destination.len == 0) return;
    const content_id: u64 = @intCast(window.content_id);
    const bytes = window.prefetch orelse return a.readRaw(content_id, start, destination);
    var filled: usize = 0;
    while (filled < destination.len) {
        const position = start + filled;
        if (window.prefetch_source != window.content_id or position < window.prefetch_start or
            position >= window.prefetch_start + window.prefetch_length)
        {
            window.prefetch_length = 0;
            const wanted: usize = @intCast(@min(bytes.len, window.reference.length - position));
            try a.readRaw(content_id, position, bytes[0..wanted]);
            window.prefetch_source = window.content_id;
            window.prefetch_start = position;
            window.prefetch_length = wanted;
        }
        const offset: usize = @intCast(position - window.prefetch_start);
        const count = @min(destination.len - filled, window.prefetch_length - offset);
        @memcpy(destination[filled..][0..count], bytes[offset..][0..count]);
        filled += count;
    }
}

pub fn sealedIdentity(field: *const content_custody.ContentField) Import {
    return .{ .digest = field.digest, .length = field.length, .private = false };
}

noinline fn importBorrowed(a: anytype, field: *const content_custody.ContentField, bytes: []const u8, value: *Import) !u64 {
    if (!std.mem.eql(u8, &content_string.digest(bytes), &field.digest)) return error.ContentChanged;
    return importBytes(a, value, bytes);
}

pub fn importSealed(a: anytype, io: std.Io, field: *const content_custody.ContentField, value: *Import, faults: Faults) !u64 {
    std.debug.assert(field.state == .value);
    if (field.borrowedBytes()) |bytes| return importBorrowed(a, field, bytes, value);
    if (field.file) |source| {
        if (try source.length(io) != field.length) return error.ContentChanged;
    } else if (field.length != 0 or !std.mem.eql(u8, &content_string.digest(""), &field.digest)) {
        return error.MissingContentCustody;
    }
    if (field.file) |file| return importRangeSlot(a, io, .{
        .file = file,
        .offset = 0,
        .length = field.length,
        .digest = field.digest,
        .sealed_length = field.length,
    }, try importSlot(a, value), faults);
    return @intCast((try importSlot(a, value)).id);
}

pub fn importRange(a: anytype, io: std.Io, range: content_custody.Range, value: *Import, faults: Faults) !u64 {
    std.debug.assert(!value.private and value.length == range.length and std.mem.eql(u8, &value.digest, &range.digest));
    const slot = try acquireSlot(a, value, .sequential);
    return importRangeSlot(a, io, range, slot, faults);
}

fn importRangeSlot(a: anytype, io: std.Io, range: content_custody.Range, slot: ContentSlot, faults: Faults) !u64 {
    const end = std.math.add(u64, range.offset, range.length) catch return error.ContentChanged;
    if (end > range.sealed_length or try range.file.length(io) != range.sealed_length) return error.ContentChanged;
    const id: u64 = @intCast(slot.id);
    if (slot.existing or range.length == 0) {
        try verifyExternalContent(io, range, null, faults);
        return id;
    }
    const sink = try a.contentSink(id, range.length);
    defer sink.close();
    try verifyExternalContent(io, range, sink, faults);
    return id;
}

pub const ContentMetadata = struct { length: u64, digest: [32]u8, private: bool };

pub const content_metadata = rsql.Read(.{
    .sql = "SELECT byte_length,digest,private FROM content WHERE content_id=?1",
    .Args = struct { content_id: u64 },
    .Row = struct { byte_length: u64, digest: [32]u8, private: bool },
    .cardinality = .one,
});

pub fn metadataOf(row: *const content_metadata.Row) ContentMetadata {
    return .{ .length = row.byte_length, .digest = row.digest, .private = row.private };
}

pub fn publicMetadata(row: *const content_metadata.Row) error{CorruptStore}!ContentMetadata {
    if (row.private) return error.CorruptStore;
    return metadataOf(row);
}

pub fn HashedWindow(comptime window_bytes: usize) type {
    return struct {
        hash: @TypeOf(content_string.hasher()),
        window: [window_bytes]u8 = undefined,
    };
}

fn verifyExternalContent(
    io: std.Io,
    range: content_custody.Range,
    destination: ?store_access.ContentSink,
    faults: Faults,
) !void {
    var copy: HashedWindow(conversation_read.content_window_bytes) = .{ .hash = content_string.hasher() };
    var offset: u64 = 0;
    while (offset < range.length) {
        const wanted: usize = @intCast(@min(range.length - offset, copy.window.len));
        const count = try range.file.readPositionalAll(io, copy.window[0..wanted], range.offset + offset);
        if (count != wanted) return error.ContentReadFailed;
        if (faults.content_read) return error.InjectedContentReadFailure;
        copy.hash.update(copy.window[0..count]);
        if (destination) |sink| {
            try sink.write(copy.window[0..count], offset);
            if (faults.content_import) return error.InjectedContentImportFailure;
        }
        offset += count;
    }
    if (try range.file.length(io) != range.sealed_length) return error.ContentChanged;
    if (!std.mem.eql(u8, &copy.hash.finalResult(), &range.digest)) return error.ContentChanged;
}

const content_prefetch_bytes = 128 * 1024;
pub const import_window_bytes = 512;
