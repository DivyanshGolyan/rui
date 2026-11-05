//! Content rows: importing bytes by digest, and reading them back through
//! locations and readers.

const std = @import("std");
const protocol = @import("../../protocol.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const store_access = @import("../access.zig");
const Access = store_access.Access;
const rsql = @import("../rsql.zig");
const Faults = store_core.Faults;
const Ordinary = store_core.Ordinary;

pub const ContentReference = struct {
    length: u64,
    digest: [32]u8,
};

/// Where one canonical content value is, resolved in one Store entry point.
/// Read only by `ContentReader.open`.
pub const ContentLocation = struct {
    store: *Store,
    content_id: i64,
    reference: ContentReference,
};

/// The digest check of one content value's bytes as they are read from
/// its start: every reader of content uses it (`ContentReader`,
/// `streamVerified`).
pub const DigestCheck = struct {
    hash: @TypeOf(protocol.contentHasher()) = protocol.contentHasher(),
    /// The bytes hashed so far, in order from the value's start.
    position: u64 = 0,
    /// Whether the check is over: the digest was compared at the end, or
    /// the caller ended it.
    verified: bool = false,

    /// Hashes the part of `bytes`, read at `start`, that extends the
    /// in-order prefix; bytes that start past it are not hashed. False
    /// only when the bytes reach `reference.length` and the digest does
    /// not match `reference.digest`. Empty content reaches its end with no
    /// bytes, so its digest is never compared.
    pub fn absorb(check: *DigestCheck, reference: ContentReference, start: u64, bytes: []const u8) bool {
        if (check.verified or start > check.position or start + bytes.len < check.position) return true;
        check.hash.update(bytes[@intCast(check.position - start)..]);
        check.position = start + bytes.len;
        if (check.position != reference.length) return true;
        check.verified = true;
        return std.mem.eql(u8, &check.hash.finalResult(), &reference.digest);
    }
};

/// The bytes `streamVerified` reads a value in at once: main's report
/// window.
pub const verified_window_bytes = 2048;

/// Streams content `content_id`, whose metadata is `reference`, to
/// `sink.write(bytes)` in windows of `verified_window_bytes`, each a
/// round of `a` of its own (`readRaw`), hashed in order by `DigestCheck`,
/// which compares the digest once the last window is hashed. So a wrong
/// payload's earlier windows reach `sink` before the call is
/// `CorruptStore`: the caller must not seal what `sink` wrote. Empty
/// content reads nothing and is not compared. Not inlined, so its window
/// sits only on the chains that stream.
pub noinline fn streamVerified(a: anytype, content_id: u64, reference: ContentReference, sink: anytype) !void {
    var check: DigestCheck = .{};
    var window: [verified_window_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < reference.length) {
        const bytes = window[0..@intCast(@min(window.len, reference.length - offset))];
        try a.readRaw(content_id, offset, bytes);
        if (!check.absorb(reference, offset, bytes)) return error.CorruptStore;
        try sink.write(bytes);
        offset += bytes.len;
    }
}

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
    check: DigestCheck = .{},
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

    /// Streams inside an existing read access, without re-entering the Store
    /// queue. No read-ahead: the caller's content-byte budget is exact.
    pub fn readWithAccess(self: *ContentReader, a: anytype, start: u64, destination: []u8) !usize {
        std.debug.assert(self.active and a.store == self.store);
        if (destination.len > content_window_bytes) return error.WindowTooLarge;
        if (start > self.reference.length) return error.RangeOutOfBounds;
        const wanted: usize = @intCast(@min(destination.len, self.reference.length - start));
        try readWindow(a, self, start, destination[0..wanted]);
        if (!self.absorb(start, destination[0..wanted])) return error.CorruptStore;
        if (@import("builtin").is_test) _ = self.store.testing_content_work.read.fetchAdd(wanted, .monotonic);
        return wanted;
    }

    /// `DigestCheck.absorb` against this reader's reference.
    pub fn absorb(self: *ContentReader, start: u64, bytes: []const u8) bool {
        return self.check.absorb(self.reference, start, bytes);
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
/// `value` must outlive the round, which defines its `found`.
pub fn lookup(a: anytype, value: *Import) void {
    a.read(lookup_content, .{ .digest = value.digest, .length = value.length, .private = value.private }, &value.found);
}

/// Two values' rows in one statement, for a round that needs both, where
/// two `lookup`s would run two.
const lookup_pair = rsql.Read(.{
    .sql = "SELECT (SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=?3) AS first," ++
        "(SELECT content_id FROM content WHERE digest=?4 AND byte_length=?5 AND private=?6) AS second",
    .Args = struct { first_digest: [32]u8, first_length: u64, first_private: bool, second_digest: [32]u8, second_length: u64, second_private: bool },
    .Row = struct { first: ?rsql.Positive, second: ?rsql.Positive },
    .cardinality = .one,
});

pub const Pair = lookup_pair.Result;

/// `lookup` of two values at once; `foundPair` follows its round. `rows`
/// must outlive the round.
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

/// After `lookupPair`'s round: each value's row, as `lookup` leaves it.
pub fn foundPair(rows: *const Pair, first: *Import, second: *Import) void {
    first.found = if (rows.first) |id| .{ .content_id = id } else null;
    second.found = if (rows.second) |id| .{ .content_id = id } else null;
}

const ContentSlot = struct { id: i64, existing: bool };

/// Sets `value.found` to the row this Access already queued for its
/// identity, if any: a lookup made before that insert reads none.
fn adoptInserted(a: anytype, value: *Import) void {
    if (value.found == null) if (a.insertedContent(&value.digest, value.length, value.private)) |id| {
        value.found = .{ .content_id = .of(id) };
    };
}

/// After `lookup`'s round: the found row, the row this Access already
/// queued for an equal identity through any value, or a new row queued
/// with a Host identity and a zeroed payload of the right length, which
/// the Access records.
pub fn importSlot(a: anytype, value: *Import) !ContentSlot {
    adoptInserted(a, value);
    if (value.found) |row| return .{ .id = @intCast(row.content_id.get()), .existing = true };
    const id = try a.identity(.content_id);
    a.write(insert_content, .{ .content_id = id, .digest = value.digest, .length = value.length, .private = value.private });
    a.recordInserted(&value.digest, value.length, value.private, id);
    value.found = .{ .content_id = .of(id) };
    return .{ .id = @intCast(id), .existing = false };
}

/// Queues a new row for `value`'s identity with a Host identity and a
/// zeroed payload, and returns its id. It records nothing on the Access:
/// it is for a caller that keeps its own table of the identities it
/// imports, as model settlement's batches do, where `importSlot` records
/// each row in the Access's `max_inserted` table for an entry point's few
/// values. Its `found` is not read.
pub fn insertRow(a: anytype, value: *const Import) !u64 {
    const id = try a.identity(.content_id);
    a.write(insert_content, .{ .content_id = id, .digest = value.digest, .length = value.length, .private = value.private });
    return id;
}

/// After `lookup`'s round: the id of `bytes`, whose identity `value` is,
/// queueing the row and its payload when none exists. `bytes` must outlive
/// the round that writes them.
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

/// `contentIdOf` in its own read Access. Noinline keeps the Access off
/// every caller's frame, as `model_settlement.readAttemptKind` does.
noinline fn readContentId(entry: *const store_core.Entry, reference: ContentReference, private: bool) !i64 {
    var a: Access(.read, error{}) = .open(entry);
    defer a.deinit();
    return contentIdOf(&a, reference, private);
}

/// The id of the row `reference` and `private` name, in one round. A
/// reference names a row, so a missing one is `CorruptStore`, and so is a
/// failed step, main's name for both. Public so a test counts its rounds.
pub fn contentIdOf(a: anytype, reference: ContentReference, private: bool) !i64 {
    var found: lookup_content.Result = undefined;
    a.read(lookup_content, .{ .digest = reference.digest, .length = reference.length, .private = private }, &found);
    try store_access.runAs(a, error.CorruptStore);
    const row = found orelse return error.CorruptStore;
    return @intCast(row.content_id.get());
}

fn readOwnedContent(self: *Store, reader: *ContentReader, start: u64, destination: []u8) !usize {
    if (destination.len > ContentReader.content_window_bytes) return error.WindowTooLarge;
    if (start > reader.reference.length) return error.RangeOutOfBounds;
    const wanted: usize = @intCast(@min(destination.len, reader.reference.length - start));
    if (wanted != 0) reader.prepareRead();
    try self.queue().run(readOwnedContentHeld, .{ self, reader, start, destination[0..wanted] });
    if (@import("builtin").is_test) _ = self.testing_content_work.read.fetchAdd(wanted, .monotonic);
    return wanted;
}

fn readOwnedContentHeld(self: *Store, reader: *ContentReader, start: u64, destination: []u8) !void {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    var a: Access(.read, error{}) = .open(&entry);
    defer a.deinit();
    try entry.finish(Ordinary.none, readWindow(&a, reader, start, destination));
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

/// The identity of sealed caller content, as `lookup` finds it.
pub fn sealedIdentity(field: *const protocol.ContentField) Import {
    return .{ .digest = field.digest, .length = field.length, .private = false };
}

/// After `lookup`'s round: the id of the sealed content `field`, whose
/// identity `value` is. A file must still hold `field.length` bytes. A new
/// row is queued, then the file streams into its payload while hashed
/// (`contentSink`, which steps the insert in process), so a file that
/// changed fails before COMMIT; a row that exists still has its file
/// verified. It ends no round.
pub fn importSealed(a: anytype, io: std.Io, field: *const protocol.ContentField, value: *Import, faults: Faults) !u64 {
    std.debug.assert(field.state == .value);
    if (field.file) |source| {
        if (try source.length(io) != field.length) return error.ContentChanged;
    } else if (field.length != 0 or !std.mem.eql(u8, &protocol.contentDigest(""), &field.digest)) {
        return error.MissingContentCustody;
    }
    const slot = try importSlot(a, value);
    const id: u64 = @intCast(slot.id);
    if (slot.existing or field.length == 0) {
        if (field.file) |source| try verifyExternalContent(io, source, field.length, &field.digest, null, faults);
        return id;
    }
    const file = field.file orelse return error.MissingContentCustody;
    const sink = try a.contentSink(id, field.length);
    defer sink.close();
    try verifyExternalContent(io, file, field.length, &field.digest, sink, faults);
    return id;
}

pub const ContentMetadata = struct { length: u64, digest: [32]u8, private: bool };

/// A content row's metadata. Every id a reader holds names a row, so a
/// missing one is `CorruptStore`.
pub const content_metadata = rsql.Read(.{
    .sql = "SELECT byte_length,digest,private FROM content WHERE content_id=?1",
    .Args = struct { content_id: u64 },
    .Row = struct { byte_length: u64, digest: [32]u8, private: bool },
    .cardinality = .one,
});

pub fn metadataOf(row: *const content_metadata.Row) ContentMetadata {
    return .{ .length = row.byte_length, .digest = row.digest, .private = row.private };
}

// Every public metadata/byte route validates the exposed content itself.
pub fn publicMetadata(row: *const content_metadata.Row) error{CorruptStore}!ContentMetadata {
    if (row.private) return error.CorruptStore;
    return metadataOf(row);
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
