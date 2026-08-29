const std = @import("std");
const binding = @import("binding.zig");

pub const header_size = 64;
pub const max_blob_size = 1024 * 1024;
pub const validation_window_size = 4096;
pub const max_startup_sweep_entries: usize = 65_536;
pub const version: u16 = 2;

const magic = "ONEBLOB\x00";
const drafts_path = ".drafts";

pub const Metadata = struct {
    length: u64,
    digest: binding.Blob,
};

pub const Writer = struct {
    dir: std.Io.Dir,
    file: std.Io.File,
    reference: u64,
    length: u64 = 0,
    hasher: binding.Hasher(binding.Blob) = .init(),
    open: bool = true,

    pub fn begin(dir: std.Io.Dir, io: std.Io, reference: u64) !Writer {
        if (reference == 0) return error.InvalidBlobReference;
        var final_name_buffer: [21]u8 = undefined;
        const final_name = try blobName(reference, &final_name_buffer);
        if (dir.access(io, final_name, .{})) |_| {
            return error.BlobAlreadyExists;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try ensureDraftDir(dir, io);
        var temp_name_buffer: [33]u8 = undefined;
        const temp_name = try draftName(final_name, &temp_name_buffer);
        const file = try dir.createFile(io, temp_name, .{});
        var empty_header: [header_size]u8 = @splat(0);
        try file.writePositionalAll(io, &empty_header, 0);
        return .{ .dir = dir, .file = file, .reference = reference };
    }

    pub fn append(self: *Writer, io: std.Io, bytes: []const u8) !void {
        if (!self.open) return error.BlobWriterClosed;
        if (bytes.len == 0) return;
        if (self.length + bytes.len > max_blob_size) return error.BlobTooLarge;
        try self.file.writePositionalAll(io, bytes, header_size + self.length);
        self.hasher.update(bytes);
        self.length += bytes.len;
    }

    pub fn finish(self: *Writer, io: std.Io) !void {
        if (!self.open) return error.BlobWriterClosed;
        if (self.length == 0) return error.EmptyBlob;
        var header: [header_size]u8 = undefined;
        encodeHeaderFields(&header, self.length, self.hasher.final());
        try self.file.writePositionalAll(io, &header, 0);
        try self.file.sync(io);
        self.file.close(io);
        self.open = false;
        var final_name_buffer: [21]u8 = undefined;
        const final_name = try blobName(self.reference, &final_name_buffer);
        var temp_name_buffer: [33]u8 = undefined;
        const temp_name = try draftName(final_name, &temp_name_buffer);
        try self.dir.rename(temp_name, self.dir, final_name, io);
        try syncDir(self.dir, io);
    }

    pub fn abort(self: *Writer, io: std.Io) void {
        if (!self.open) return;
        self.file.close(io);
        self.open = false;
        var final_name_buffer: [21]u8 = undefined;
        const final_name = blobName(self.reference, &final_name_buffer) catch return;
        var temp_name_buffer: [33]u8 = undefined;
        const temp_name = draftName(final_name, &temp_name_buffer) catch return;
        // A draft is never readable as evidence: only the final rename publishes it.
        // Cleanup is therefore best-effort here; the bounded startup sweep removes
        // crash-left or deletion-failed `.tmp` files before the store is served.
        self.dir.deleteFile(io, temp_name) catch {};
    }
};

pub const Reader = struct {
    file: std.Io.File,
    meta: Metadata,
    open: bool = true,

    pub fn openIn(dir: std.Io.Dir, io: std.Io, reference: u64) !Reader {
        var name_buffer: [21]u8 = undefined;
        const name = try blobName(reference, &name_buffer);
        var file = try dir.openFile(io, name, .{});
        errdefer file.close(io);
        const meta = try validateFile(file, io);
        return .{ .file = file, .meta = meta };
    }

    pub fn readWindow(self: *Reader, io: std.Io, offset: u64, out: []u8) ![]const u8 {
        if (!self.open) return error.BlobReaderClosed;
        if (offset > self.meta.length) return error.InvalidBlobOffset;
        const remaining = self.meta.length - offset;
        const read_length: usize = @intCast(@min(remaining, out.len));
        const actual = try self.file.readPositionalAll(io, out[0..read_length], header_size + offset);
        if (actual != read_length) return error.TruncatedBlob;
        return out[0..actual];
    }

    pub fn close(self: *Reader, io: std.Io) void {
        if (!self.open) return;
        self.file.close(io);
        self.open = false;
    }
};

pub fn put(dir: std.Io.Dir, io: std.Io, reference: u64, bytes: []const u8) !void {
    if (reference == 0) return error.InvalidBlobReference;
    if (bytes.len == 0) return error.EmptyBlob;
    if (bytes.len > max_blob_size) return error.BlobTooLarge;

    var writer = try Writer.begin(dir, io, reference);
    errdefer writer.abort(io);
    try writer.append(io, bytes);
    try writer.finish(io);
}

pub fn metadata(dir: std.Io.Dir, io: std.Io, reference: u64) !Metadata {
    var reader = try Reader.openIn(dir, io, reference);
    defer reader.close(io);
    return reader.meta;
}

pub fn readWindow(
    dir: std.Io.Dir,
    io: std.Io,
    reference: u64,
    offset: u64,
    out: []u8,
) ![]const u8 {
    var reader = try Reader.openIn(dir, io, reference);
    defer reader.close(io);
    return reader.readWindow(io, offset, out);
}

/// Removes crash-left unpublished writers. The caller must hold the owning
/// Session lock. Drafts live in a dedicated bounded scratch namespace, so the
/// amount of sealed immutable evidence cannot consume the cleanup budget.
pub fn sweepIncomplete(dir: std.Io.Dir, io: std.Io) !usize {
    var drafts = dir.openDir(io, drafts_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer drafts.close(io);
    var iterator = drafts.iterate();
    var scanned: usize = 0;
    var removed: usize = 0;
    while (try iterator.next(io)) |entry| {
        if (scanned == max_startup_sweep_entries) return error.BlobSweepEntryLimitExceeded;
        scanned += 1;
        if (entry.kind != .file or !isIncompleteName(entry.name)) continue;
        try drafts.deleteFile(io, entry.name);
        removed += 1;
    }
    if (removed != 0) try syncDir(drafts, io);
    return removed;
}

fn ensureDraftDir(dir: std.Io.Dir, io: std.Io) !void {
    dir.createDir(io, drafts_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
    try syncDir(dir, io);
}

fn draftName(final_name: []const u8, buffer: *[33]u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, drafts_path ++ "/{s}.tmp", .{final_name});
}

fn isIncompleteName(name: []const u8) bool {
    if (name.len != 25 or !std.mem.eql(u8, name[16..], ".blob.tmp")) return false;
    for (name[0..16]) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn validateFile(file: std.Io.File, io: std.Io) !Metadata {
    const stat = try file.stat(io);
    if (stat.size < header_size) return error.TruncatedBlob;
    if (stat.size > header_size + max_blob_size) return error.BlobTooLarge;
    var header: [header_size]u8 = undefined;
    const header_read = try file.readPositionalAll(io, &header, 0);
    if (header_read != header_size) return error.TruncatedBlob;
    const meta = try decodeHeader(&header);
    if (stat.size != header_size + meta.length) return error.InvalidBlobLength;

    var hasher = binding.Hasher(binding.Blob).init();
    var window: [validation_window_size]u8 = undefined;
    var offset: u64 = 0;
    while (offset < meta.length) {
        const expected: usize = @intCast(@min(meta.length - offset, window.len));
        const actual = try file.readPositionalAll(io, window[0..expected], header_size + offset);
        if (actual != expected) return error.TruncatedBlob;
        hasher.update(window[0..actual]);
        offset += actual;
    }
    if (!binding.eql(binding.Blob, hasher.final(), meta.digest)) {
        return error.BlobChecksumMismatch;
    }
    return meta;
}

fn encodeHeaderFields(out: *[header_size]u8, length: u64, digest: binding.Blob) void {
    @memset(out, 0);
    @memcpy(out[0..magic.len], magic);
    write(u16, out, 8, version);
    write(u16, out, 10, header_size);
    write(u32, out, 12, 0);
    write(u64, out, 16, length);
    @memcpy(out[24..56], &digest.bytes);
    write(u32, out, 60, std.hash.Crc32.hash(out[0..60]));
}

fn decodeHeader(bytes: *const [header_size]u8) !Metadata {
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidBlobMagic;
    if (read(u16, bytes, 8) != version) return error.UnsupportedBlobVersion;
    if (read(u16, bytes, 10) != header_size) return error.InvalidBlobHeader;
    if (read(u32, bytes, 12) != 0) return error.UnsupportedBlobFlags;
    if (read(u32, bytes, 56) != 0 or
        read(u32, bytes, 60) != std.hash.Crc32.hash(bytes[0..60]))
    {
        return error.BlobHeaderChecksumMismatch;
    }
    const length = read(u64, bytes, 16);
    if (length == 0 or length > max_blob_size) return error.InvalidBlobLength;
    return .{ .length = length, .digest = .{ .bytes = bytes[24..56].* } };
}

fn blobName(reference: u64, buffer: *[21]u8) ![]const u8 {
    if (reference == 0) return error.InvalidBlobReference;
    return std.fmt.bufPrint(buffer, "{x:0>16}.blob", .{reference});
}

fn syncDir(dir: std.Io.Dir, io: std.Io) !void {
    const directory_file: std.Io.File = .{
        .handle = dir.handle,
        .flags = .{ .nonblocking = false },
    };
    try directory_file.sync(io);
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

test "blob publication and bounded reads are canonical" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = "a bounded durable model response";

    try put(tmp.dir, io, 42, payload);
    const meta = try metadata(tmp.dir, io, 42);
    try std.testing.expectEqual(@as(u64, payload.len), meta.length);
    var window: [7]u8 = undefined;
    try std.testing.expectEqualStrings("bounded", try readWindow(tmp.dir, io, 42, 2, &window));
    try std.testing.expectError(error.BlobAlreadyExists, put(tmp.dir, io, 42, payload));
}

test "startup sweep removes only crash-left provisional drafts" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try put(tmp.dir, io, 41, "sealed before semantic admission");
    var interrupted = try Writer.begin(tmp.dir, io, 42);
    try interrupted.append(io, "partial and non-authoritative");
    interrupted.file.close(io);
    interrupted.open = false; // Simulate process loss before abort or finish.
    try tmp.dir.writeFile(io, .{ .sub_path = ".drafts/not-a-blob.tmp", .data = "unrelated" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root-history.blob", .data = "sealed population is outside scratch" });

    try std.testing.expectEqual(@as(usize, 1), try sweepIncomplete(tmp.dir, io));
    try std.testing.expectEqualStrings(
        "sealed before semantic admission",
        blk: {
            var bytes: [64]u8 = undefined;
            break :blk try readWindow(tmp.dir, io, 41, 0, &bytes);
        },
    );
    try std.testing.expectError(error.FileNotFound, metadata(tmp.dir, io, 42));
    try tmp.dir.access(io, ".drafts/not-a-blob.tmp", .{});
    try tmp.dir.access(io, "root-history.blob", .{});
}

test "sealed population is outside the bounded draft sweep namespace" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try put(tmp.dir, io, 1, "sealed");
    var root = tmp.dir.iterate();
    var saw_sealed = false;
    while (try root.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "0000000000000001.blob")) saw_sealed = true;
    }
    try std.testing.expect(saw_sealed);
    try std.testing.expectEqual(@as(usize, 0), try sweepIncomplete(tmp.dir, io));

    // The bounded enumerator sees only this namespace. A historical population
    // larger than the draft budget therefore cannot affect startup recovery.
    try std.testing.expect(max_startup_sweep_entries < std.math.maxInt(usize));
    _ = try metadata(tmp.dir, io, 1);
}

test "blob validation rejects corruption before returning a window" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try put(tmp.dir, io, 43, "response");
    var file = try tmp.dir.openFile(io, "000000000000002b.blob", .{ .mode = .read_write });
    defer file.close(io);
    try file.writePositionalAll(io, "X", header_size + 2);
    try file.sync(io);
    var window: [8]u8 = undefined;
    try std.testing.expectError(
        error.BlobChecksumMismatch,
        readWindow(tmp.dir, io, 43, 0, &window),
    );
}
