//! Content rows: importing bytes by digest, and reading them back through
//! locations and readers.

const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const store_access = @import("../access.zig");
const Access = store_access.Access;
const rsql = @import("../rsql.zig");
const sqlite = @import("../sqlite.zig");
const c = sqlite.c;
const Faults = store_core.Faults;
const Ordinary = store_core.Ordinary;

pub const ContentReference = struct {
    length: u64,
    digest: [32]u8,
};

/// Where one canonical content value is, resolved under the Store lock.
/// Read only by `ContentReader.open`.
pub const ContentLocation = struct {
    store: *Store,
    content_id: i64,
    reference: ContentReference,
};

/// Readers allow ranged reads and retain copied bytes and identities, never
/// SQLite handles.
pub const ContentReader = struct {
    pub const content_window_bytes = 64 * 1024;

    content_id: i64,
    store: *Store,
    reference: ContentReference,
    active: bool = true,
    allocator: std.mem.Allocator = std.heap.c_allocator,
    prefetch: ?[]u8 = null,
    prefetch_source: i64 = 0,
    prefetch_start: u64 = 0,
    prefetch_length: usize = 0,
    /// Bytes read in order from the start are hashed; reaching the end
    /// checks the digest before the last window is returned. Reads that
    /// skip ahead stop this check.
    hash: @TypeOf(protocol.contentHasher()) = protocol.contentHasher(),
    verified_position: u64 = 0,
    verified: bool = false,
    /// Where its reads begin: a message part's reader reads only its range,
    /// so read-ahead is sized to that range, not the whole row.
    first: u64 = 0,

    /// Builds the reader where it lives. Needs no Store access.
    pub fn open(self: *ContentReader, location: ContentLocation) void {
        self.* = .{ .content_id = location.content_id, .store = location.store, .reference = location.reference };
    }

    // Allocate outside Store access. Read-ahead is optional: allocation failure
    // keeps the original bounded read path, not a canonical/Host fault. Small
    // values read straight into the caller's window.
    fn prepareRead(self: *ContentReader) void {
        if (self.prefetch == null and self.reference.length - self.first > 1024 * 1024) {
            // Raw: a read fills the window before any byte of it is used;
            // alloc would first write 0xAA over all 128 KB in ReleaseSafe.
            if (self.allocator.rawAlloc(content_prefetch_bytes, .of(u8), @returnAddress())) |bytes|
                self.prefetch = bytes[0..content_prefetch_bytes];
        }
    }

    pub fn read(self: *ContentReader, start: u64, destination: []u8) !usize {
        std.debug.assert(self.active);
        const count = try readOwnedContent(self.store, self, start, destination);
        if (!self.absorb(start, destination[0..count])) return store_core.fence(self.store, error.CorruptStore);
        return count;
    }

    /// Hashes bytes read at `start` that extend the in-order prefix; false
    /// when they reach the end and the digest does not match.
    pub fn absorb(self: *ContentReader, start: u64, bytes: []const u8) bool {
        if (self.verified or start > self.verified_position or start + bytes.len < self.verified_position) return true;
        self.hash.update(bytes[@intCast(self.verified_position - start)..]);
        self.verified_position = start + bytes.len;
        if (self.verified_position != self.reference.length) return true;
        self.verified = true;
        return std.mem.eql(u8, &self.hash.finalResult(), &self.reference.digest);
    }

    /// Read at any public byte offset.
    pub fn readRange(self: *ContentReader, start: u64, destination: []u8) !usize {
        std.debug.assert(self.active and destination.len > 0);
        if (destination.len > content_window_bytes) return error.WindowTooLarge;
        if (start > self.reference.length) return error.RangeOutOfBounds;
        return self.read(start, destination);
    }

    pub fn close(self: *ContentReader) void {
        std.debug.assert(self.active);
        // Raw, as allocated: free would write 0xAA over the window first.
        if (self.prefetch) |bytes| self.allocator.rawFree(bytes, .of(u8), @returnAddress());
        self.prefetch = null;
        self.active = false;
        if (@import("builtin").is_test) _ = self.store.testing_content_work.closes.fetchAdd(1, .monotonic);
    }
};

const lookup_content = rsql.Read(.{
    .sql = "SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=?3",
    .Args = struct { digest: *const [32]u8, length: u64, private: bool },
    .Row = struct { content_id: rsql.Positive },
    .cardinality = .optional,
});

const insert_content = rsql.Write(.{
    .sql = "INSERT INTO content(content_id,digest,byte_length,payload,private) VALUES(?1,?2,?3,zeroblob(?3),?4)",
    .Args = struct { content_id: u64, digest: *const [32]u8, length: u64, private: bool },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// The result of every Action and Turn a Session stop cancels.
pub const stop_cancellation_text = "Cancelled by Session stop.";

/// A content identity, and the row a lookup round found for it.
pub const Import = struct {
    digest: [32]u8,
    length: u64,
    private: bool,
    found: lookup_content.Result = null,

    pub fn ofBytes(bytes: []const u8, private: bool) Import {
        return .{ .digest = protocol.contentDigest(bytes), .length = bytes.len, .private = private };
    }
};

/// `stop_cancellation_text`'s identity, hashed when the Host is built.
pub const stop_cancellation: Import = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk .ofBytes(stop_cancellation_text, false);
};

/// The empty value's identity, hashed when the Host is built.
pub const empty_content: Import = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk .ofBytes("", false);
};

/// Queues the read that finds `value`'s row; `importSlot` follows its round.
/// `value` must outlive the round, which reads its digest in place.
pub fn lookup(a: anytype, value: *Import) void {
    a.read(lookup_content, .{ .digest = &value.digest, .length = value.length, .private = value.private }, &value.found);
}

const ContentSlot = struct { id: i64, existing: bool };

/// After `lookup`'s round: the found row, or a new row queued with a Host
/// identity and a zeroed payload of the right length. `value` must outlive
/// the round that writes it.
pub fn importSlot(a: anytype, value: *const Import) !ContentSlot {
    if (value.found) |row| return .{ .id = @intCast(row.content_id.get()), .existing = true };
    const id = try a.identity(.content_id);
    a.write(insert_content, .{ .content_id = id, .digest = &value.digest, .length = value.length, .private = value.private });
    return .{ .id = @intCast(id), .existing = false };
}

/// After `lookup`'s round: the id of `bytes`, whose identity `value` is,
/// queueing the row and its payload when none exists. `bytes` must outlive
/// the round that writes them.
pub fn importBytes(a: anytype, value: *const Import, bytes: []const u8) !u64 {
    std.debug.assert(bytes.len == value.length);
    const slot = try importSlot(a, value);
    if (!slot.existing) a.writeContent(@intCast(slot.id), bytes);
    return @intCast(slot.id);
}

/// `importSlot` for unconverted code, inside its transaction.
pub fn contentSlot(self: *Store, digest: *const [32]u8, length: u64, private: bool) !ContentSlot {
    var a = Access(.nested, error{}).within(self);
    defer a.deinit();
    var value: Import = .{ .digest = digest.*, .length = length, .private = private };
    lookup(&a, &value);
    try a.run();
    const slot = try importSlot(&a, &value);
    try a.apply();
    return slot;
}

/// `importBytes` for unconverted code, inside its transaction.
pub fn importBytesContent(self: *Store, bytes: []const u8, private: bool, fail_import: bool) !i64 {
    if (fail_import) return error.InjectedContentImportFailure;
    var a = Access(.nested, error{}).within(self);
    defer a.deinit();
    var value: Import = .ofBytes(bytes, private);
    lookup(&a, &value);
    try a.run();
    const id = try importBytes(&a, &value, bytes);
    try a.apply();
    return @intCast(id);
}

pub fn writeCheckedBytes(_: *Store, blob: ?*c.sqlite3_blob, hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8, written: *u64, length: u64) !void {
    if (bytes.len > length - written.*) return error.OutputSourceChanged;
    hash.update(bytes);
    if (blob) |value| {
        if (c.sqlite3_blob_write(value, bytes.ptr, @intCast(bytes.len), @intCast(written.*)) != c.SQLITE_OK) return error.ContentWriteFailed;
    }
    written.* += bytes.len;
}

pub fn openContentIdentity(self: *Store, reference: ContentReference, private: bool) !ContentLocation {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    return entry.finish(Ordinary.none, openContentIdentityLocked(self, reference, private));
}

fn openContentIdentityLocked(self: *Store, reference: ContentReference, private: bool) !ContentLocation {
    const id = try resolveContentReference(self, reference, private);
    return .{ .store = self, .reference = reference, .content_id = id };
}

fn readOwnedContent(self: *Store, reader: *ContentReader, start: u64, destination: []u8) !usize {
    if (destination.len > ContentReader.content_window_bytes) return error.WindowTooLarge;
    if (start > reader.reference.length) return error.RangeOutOfBounds;
    const wanted: usize = @intCast(@min(destination.len, reader.reference.length - start));
    if (wanted != 0) reader.prepareRead();
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var a: Access(.read, error{}) = .open(&entry);
    defer a.deinit();
    try entry.finish(Ordinary.none, readWindow(&a, reader, start, destination[0..wanted]));
    if (@import("builtin").is_test) _ = self.testing_content_work.read.fetchAdd(wanted, .monotonic);
    return wanted;
}

/// `readWindow` for unconverted code, under the Entry it holds.
pub fn readOwnedContentLocked(self: *Store, reader: *ContentReader, start: u64, destination: []u8) !void {
    var a = Access(.read, error{}).within(self);
    defer a.deinit();
    return readWindow(&a, reader, start, destination);
}

/// Fills all of `destination` from `reader`'s content at `start`, or
/// fails, so no reader sees a short window. Each reader owns its copied
/// source window: neither interleaved readers nor another row at the same
/// offset can borrow those bytes.
fn readWindow(a: anytype, reader: *ContentReader, start: u64, destination: []u8) !void {
    if (destination.len == 0) return;
    const content_id: u64 = @intCast(reader.content_id);
    const window = reader.prefetch orelse return a.readRaw(content_id, start, destination);
    var filled: usize = 0;
    while (filled < destination.len) {
        const position = start + filled;
        if (reader.prefetch_source != reader.content_id or position < reader.prefetch_start or
            position >= reader.prefetch_start + reader.prefetch_length)
        {
            reader.prefetch_length = 0;
            const wanted: usize = @intCast(@min(window.len, reader.reference.length - position));
            try a.readRaw(content_id, position, window[0..wanted]);
            reader.prefetch_source = reader.content_id;
            reader.prefetch_start = position;
            reader.prefetch_length = wanted;
        }
        const offset: usize = @intCast(position - reader.prefetch_start);
        const count = @min(destination.len - filled, reader.prefetch_length - offset);
        @memcpy(destination[filled..][0..count], window[offset..][0..count]);
        filled += count;
    }
}

pub fn importEmptyContent(self: *Store) !i64 {
    return importBytesContent(self, "", false, false);
}

/// The identity of sealed caller content, as `lookup` finds it.
pub fn sealedIdentity(field: *const protocol.ContentField) Import {
    return .{ .digest = field.digest, .length = field.length, .private = false };
}

/// After `lookup`'s round: the id of the sealed content `field`, whose
/// identity `value` is. A file must still hold `field.length` bytes. A new
/// row is queued and its round run, then the file streams into its payload
/// while hashed, so a file that changed fails before COMMIT; a row that
/// exists still has its file verified.
pub fn importSealed(a: anytype, io: std.Io, field: *const protocol.ContentField, value: *const Import, faults: Faults) !u64 {
    std.debug.assert(field.state == .value);
    if (field.file) |source| {
        if (try source.length(io) != field.length) return error.ContentChanged;
    } else if (field.length != 0 or !std.mem.eql(u8, &protocol.contentDigest(""), &field.digest)) {
        return error.MissingContentCustody;
    }
    const slot = try importSlot(a, value);
    const id: u64 = @intCast(slot.id);
    // Run now, so a second import in this Access can queue its own row.
    if (!slot.existing) try a.run();
    if (slot.existing or field.length == 0) {
        if (field.file) |source| try verifyExternalContent(io, source, field.length, &field.digest, null, faults);
        return id;
    }
    const file = field.file orelse return error.MissingContentCustody;
    const sink = try a.contentSink(id);
    defer sink.close();
    try verifyExternalContent(io, file, field.length, &field.digest, sink, faults);
    return id;
}

/// `importSealed` for unconverted code, inside its transaction.
pub fn importContent(self: *Store, content: *const protocol.ContentField, faults: Faults) !i64 {
    var a = Access(.nested, error{}).within(self);
    defer a.deinit();
    var value = sealedIdentity(content);
    lookup(&a, &value);
    try a.run();
    const id = try importSealed(&a, self.io, content, &value, faults);
    try a.apply();
    return @intCast(id);
}

pub const ContentMetadata = struct { length: u64, digest: [32]u8, private: bool };

pub fn readContentMetadata(self: *Store, content_id: i64) !ContentMetadata {
    const statement = try store_core.cached(self, "SELECT byte_length,digest,private FROM content WHERE content_id=?1");
    defer sqlite.resetCached(statement);
    try sqlite.bindI64(statement, 1, content_id);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    const length = c.sqlite3_column_int64(statement, 0);
    if (length < 0) return error.CorruptStore;
    return .{ .length = @intCast(length), .digest = try sqlite.readDigest(statement, 1), .private = c.sqlite3_column_int(statement, 2) != 0 };
}

// Every public metadata/byte route validates the exposed content itself.
pub fn readPublicContentMetadata(self: *Store, content_id: i64) !ContentMetadata {
    const metadata = try readContentMetadata(self, content_id);
    if (metadata.private) return error.CorruptStore;
    return metadata;
}

fn resolveContentReference(self: *Store, reference: ContentReference, private: bool) !i64 {
    const statement = try store_core.cachedTyped(self, lookup_content);
    defer sqlite.resetCached(statement);
    try sqlite.bindArgs(statement, lookup_content, &.{ .digest = &reference.digest, .length = reference.length, .private = private }, 0, null);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    var row: lookup_content.Row = undefined;
    try sqlite.decodeRow(lookup_content.Row, statement, &row);
    return @intCast(row.content_id.get());
}

/// A content hash and one window of the bytes it hashes. Declared as
/// `.{ .hash = protocol.contentHasher() }`: the runtime hash makes the
/// literal store field by field, so the window stays unwritten until a read
/// fills it, where `var window: [N]u8 = undefined` would first fill it with
/// 0xAA in ReleaseSafe.
pub fn HashedWindow(comptime window_bytes: usize) type {
    return struct {
        hash: @TypeOf(protocol.contentHasher()),
        window: [window_bytes]u8 = undefined,
    };
}

fn verifyExternalContent(
    io: std.Io,
    file: std.Io.File,
    expected_length: u64,
    expected_digest: *const [32]u8,
    destination: ?store_access.ContentSink,
    faults: Faults,
) !void {
    var copy: HashedWindow(protocol.content_window_bytes) = .{ .hash = protocol.contentHasher() };
    var offset: u64 = 0;
    while (offset < expected_length) {
        const wanted: usize = @intCast(@min(expected_length - offset, copy.window.len));
        const count = try file.readPositionalAll(io, copy.window[0..wanted], offset);
        if (count != wanted) return error.ContentReadFailed;
        if (faults.content_read) return error.InjectedContentReadFailure;
        copy.hash.update(copy.window[0..count]);
        if (destination) |sink| {
            try sink.write(copy.window[0..count], offset);
            if (faults.content_import) return error.InjectedContentImportFailure;
        }
        offset += count;
    }
    if (try file.length(io) != expected_length) return error.ContentChanged;
    if (!std.mem.eql(u8, &copy.hash.finalResult(), expected_digest)) return error.ContentChanged;
}

// Large streaming readers own one bounded heap window, never an inline
// population/worker-stack multiplier. Synchronous locked work needs no heap
// prefetch: it already reuses SQLite's overflow-page index for the whole call.
const content_prefetch_bytes = 128 * 1024;
/// Import-time copy and decode windows: small, so settlement frames stay
/// within the Host stack rule.
pub const import_window_bytes = 512;
