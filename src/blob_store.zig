const std = @import("std");
const binding = @import("binding.zig");

pub const header_size = 64;
pub const max_blob_size = 1024 * 1024;
pub const validation_window_size = 4096;
pub const version: u16 = 2;

const magic = "ONEBLOB\x00";

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
        var temp_name_buffer: [25]u8 = undefined;
        const temp_name = try std.fmt.bufPrint(&temp_name_buffer, "{s}.tmp", .{final_name});
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
        var temp_name_buffer: [25]u8 = undefined;
        const temp_name = try std.fmt.bufPrint(&temp_name_buffer, "{s}.tmp", .{final_name});
        try self.dir.rename(temp_name, self.dir, final_name, io);
        try syncDir(self.dir, io);
    }

    pub fn abort(self: *Writer, io: std.Io) void {
        if (!self.open) return;
        self.file.close(io);
        self.open = false;
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
