//! Content rows: importing bytes by digest, and reading them back through
//! locations and readers.

const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const sqlite = @import("../sqlite.zig");
const c = sqlite.c;
const Faults = store_core.Faults;
const Ordinary = store_core.Ordinary;

const content_lookup_sql = "SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=?3";

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

/// One read handle reused only within a locked Store entry point.
/// Its overflow-page index costs SQLite heap of about length/1024 bytes.
pub const ContentBlob = struct {
    handle: ?*c.sqlite3_blob = null,
    content_id: i64 = 0,

    pub fn close(self: *ContentBlob) void {
        // Close reports only an earlier read failure, already returned.
        if (self.handle) |handle| _ = c.sqlite3_blob_close(handle);
        self.* = .{};
    }
};

const ContentSlot = struct { id: i64, existing: bool };

pub fn contentSlot(self: *Store, digest: *const [32]u8, length: u64, private: bool) !ContentSlot {
    const find = try store_core.cached(self, content_lookup_sql);
    defer sqlite.resetCached(find);
    try sqlite.bindBlob(find, 1, digest);
    try sqlite.bindU64(find, 2, length);
    try sqlite.bindI64(find, 3, @as(i64, if (private) 1 else 0));
    const result = c.sqlite3_step(find);
    if (result == c.SQLITE_ROW) {
        const id = c.sqlite3_column_int64(find, 0);
        if (id <= 0) return error.CorruptStore;
        return .{ .id = id, .existing = true };
    }
    if (result != c.SQLITE_DONE) return error.ContentReadFailed;
    const id = try store_core.takeIdentity(self, .content_id);
    const insert = try store_core.cached(
        self,
        "INSERT INTO content(content_id,digest,byte_length,payload,private) VALUES(?4,?1,?2,zeroblob(?2),?3)",
    );
    defer sqlite.resetCached(insert);
    try sqlite.bindBlob(insert, 1, digest);
    try sqlite.bindU64(insert, 2, length);
    try sqlite.bindI64(insert, 3, @as(i64, if (private) 1 else 0));
    try sqlite.bindU64(insert, 4, id);
    switch (c.sqlite3_step(insert)) {
        c.SQLITE_DONE => {},
        c.SQLITE_FULL => return error.CanonicalStorageFull,
        else => return error.StatementFailed,
    }
    return .{ .id = @intCast(id), .existing = false };
}

pub fn importBytesContent(self: *Store, bytes: []const u8, private: bool, fail_import: bool) !i64 {
    if (fail_import) return error.InjectedContentImportFailure;
    const digest = protocol.contentDigest(bytes);
    const slot = try contentSlot(self, &digest, bytes.len, private);
    if (slot.existing or bytes.len == 0) return slot.id;
    var blob: ?*c.sqlite3_blob = null;
    if (c.sqlite3_blob_open(self.database, "main", "content", "payload", slot.id, 1, &blob) != c.SQLITE_OK) {
        return error.ContentWriteFailed;
    }
    defer _ = c.sqlite3_blob_close(blob);
    if (c.sqlite3_blob_write(blob, bytes.ptr, @intCast(bytes.len), 0) != c.SQLITE_OK) {
        return error.ContentWriteFailed;
    }
    return slot.id;
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
    try entry.finish(Ordinary.none, readOwnedContentLocked(self, reader, start, destination[0..wanted]));
    if (@import("builtin").is_test) _ = self.testing_content_work.read.fetchAdd(wanted, .monotonic);
    return wanted;
}

/// Fills all of `destination` or fails, so no reader sees a short window.
pub fn readOwnedContentLocked(self: *Store, reader: *ContentReader, start: u64, destination: []u8) !void {
    return readReaderBlob(self, reader, reader.content_id, start, reader.reference.length, destination);
}

// Each reader owns its copied source window. Neither interleaved readers
// nor another row at the same offset can borrow those bytes. Entry still
// owns and closes the SQLite handle before callbacks or yields.
fn readReaderBlob(self: *Store, reader: *ContentReader, content_id: i64, start: u64, end: u64, destination: []u8) !void {
    if (destination.len == 0) return;
    const window = reader.prefetch orelse return readBlob(self, content_id, start, destination);
    var filled: usize = 0;
    while (filled < destination.len) {
        const position = start + filled;
        if (reader.prefetch_source != content_id or position < reader.prefetch_start or
            position >= reader.prefetch_start + reader.prefetch_length)
        {
            reader.prefetch_length = 0;
            const wanted: usize = @intCast(@min(window.len, end - position));
            try readBlob(self, content_id, position, window[0..wanted]);
            reader.prefetch_source = content_id;
            reader.prefetch_start = position;
            reader.prefetch_length = wanted;
        }
        const offset: usize = @intCast(position - reader.prefetch_start);
        const count = @min(destination.len - filled, reader.prefetch_length - offset);
        @memcpy(destination[filled..][0..count], window[offset..][0..count]);
        filled += count;
    }
}

// Called only inside one Entry. Reuse avoids repeated overflow-page walks
// within synchronous work, never across callbacks or preparation yields.
fn readBlob(self: *Store, content_id: i64, start: u64, destination: []u8) !void {
    if (destination.len == 0) return;
    if (start > std.math.maxInt(c_int)) return error.RangeOutOfBounds;
    const blob = &self.read_blob;
    if (blob.handle == null) {
        // A failed open leaves the handle null.
        if (c.sqlite3_blob_open(self.database, "main", "content", "payload", content_id, 0, &blob.handle) != c.SQLITE_OK) return error.ContentReadFailed;
        blob.content_id = content_id;
    } else if (blob.content_id != content_id) {
        // A failed reopen aborts the handle; close remains its release.
        if (c.sqlite3_blob_reopen(blob.handle, content_id) != c.SQLITE_OK) return error.ContentReadFailed;
        blob.content_id = content_id;
    }
    if (c.sqlite3_blob_read(blob.handle, destination.ptr, @intCast(destination.len), @intCast(start)) != c.SQLITE_OK) return error.ContentReadFailed;
    if (@import("builtin").is_test) _ = self.testing_content_work.blob.fetchAdd(destination.len, .monotonic);
}

pub fn importEmptyContent(self: *Store) !i64 {
    var empty: protocol.ContentField = .{ .state = .value };
    empty.digest = protocol.contentDigest("");
    return importContent(self, &empty, .{});
}

pub fn importContent(self: *Store, content: *const protocol.ContentField, faults: Faults) !i64 {
    std.debug.assert(content.state == .value);
    if (content.file) |source| {
        if (try source.length(self.io) != content.length) return error.ContentChanged;
    } else if (content.length != 0 or
        !std.mem.eql(u8, &protocol.contentDigest(""), &content.digest))
    {
        return error.MissingContentCustody;
    }
    const slot = try contentSlot(self, &content.digest, content.length, false);
    if (slot.existing) {
        if (content.file) |source| {
            try verifyExternalContent(self.io, source, content.length, &content.digest, null, faults);
        }
        return slot.id;
    }
    const content_id = slot.id;

    if (content.length == 0) {
        if (content.file) |source| {
            try verifyExternalContent(self.io, source, content.length, &content.digest, null, faults);
        }
        return content_id;
    }
    var blob: ?*c.sqlite3_blob = null;
    if (c.sqlite3_blob_open(self.database, "main", "content", "payload", content_id, 1, &blob) != c.SQLITE_OK) {
        return error.ContentWriteFailed;
    }
    defer _ = c.sqlite3_blob_close(blob);
    const file = content.file orelse return error.MissingContentCustody;
    // Verify the exact bytes copied while the row is still uncommitted.
    // The caller rolls back the whole transaction if verification fails.
    try verifyExternalContent(self.io, file, content.length, &content.digest, blob, faults);
    return content_id;
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
    const statement = try store_core.cached(self, content_lookup_sql);
    defer sqlite.resetCached(statement);
    try sqlite.bindBlob(statement, 1, &reference.digest);
    try sqlite.bindU64(statement, 2, reference.length);
    try sqlite.bindI64(statement, 3, @as(i64, if (private) 1 else 0));
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    const content_id = c.sqlite3_column_int64(statement, 0);
    if (content_id <= 0) return error.CorruptStore;
    return content_id;
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
    destination: ?*c.sqlite3_blob,
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
        if (destination) |blob| {
            if (offset > std.math.maxInt(c_int)) return error.ContentTooLarge;
            if (c.sqlite3_blob_write(blob, copy.window[0..count].ptr, @intCast(count), @intCast(offset)) != c.SQLITE_OK) {
                return error.ContentWriteFailed;
            }
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
