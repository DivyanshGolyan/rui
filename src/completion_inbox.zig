const std = @import("std");

pub const version: u16 = 1;
pub const record_size: usize = 96;
pub const max_records: u32 = 4096;

const magic = "ONEINBOX";
const checksum_offset = 80;

pub const EvidenceKind = enum(u8) {
    model = 1,
    bash = 2,
    apply_patch = 3,
};

pub const Envelope = struct {
    kind: EvidenceKind,
    session_id: u64,
    ownership_epoch: u64,
    agent_id: u64,
    agent_generation: u32,
    operation_id: u64,
    operation_generation: u32,
    attempt_id: u64,
    result_ref: u64,
    result_digest: u64,
};

pub const Writer = struct {
    file: std.Io.File,
    record_count: u32,

    pub fn createIn(dir: std.Io.Dir, io: std.Io, path: []const u8) !Writer {
        return .{ .file = try dir.createFile(io, path, .{ .exclusive = true }), .record_count = 0 };
    }

    pub fn openAppendIn(dir: std.Io.Dir, io: std.Io, path: []const u8) !Writer {
        const file = try dir.openFile(io, path, .{ .mode = .read_write });
        errdefer file.close(io);
        const physical_length = try file.length(io);
        const valid_length = physical_length - physical_length % record_size;
        if (valid_length != physical_length) {
            try file.setLength(io, valid_length);
            try file.sync(io);
        }
        const count = valid_length / record_size;
        if (count > max_records) return error.InboxCapacityExceeded;
        return .{ .file = file, .record_count = @intCast(count) };
    }

    pub fn publish(self: *Writer, io: std.Io, envelope: Envelope) !void {
        if (self.record_count == max_records) return error.InboxCapacityExceeded;
        var record: [record_size]u8 = undefined;
        try encode(&record, envelope);
        try self.file.writePositionalAll(io, &record, try self.file.length(io));
        try self.file.sync(io);
        self.record_count += 1;
    }

    pub fn close(self: *Writer, io: std.Io) void {
        self.file.close(io);
    }
};

pub const Reader = struct {
    file: std.Io.File,
    cursor: u64 = 0,
    length: u64,
    corrupt_records: u32 = 0,
    records_read: u32 = 0,

    pub fn openIn(dir: std.Io.Dir, io: std.Io, path: []const u8) !Reader {
        const file = try dir.openFile(io, path, .{});
        errdefer file.close(io);
        return .{ .file = file, .length = try file.length(io) };
    }

    pub fn next(self: *Reader, io: std.Io) !?Envelope {
        while (try self.step(io)) |record| switch (record) {
            .envelope => |envelope| return envelope,
            .corrupt => continue,
        };
        return null;
    }

    pub const Record = union(enum) { envelope: Envelope, corrupt };

    pub fn step(self: *Reader, io: std.Io) !?Record {
        if (self.cursor + record_size <= self.length) {
            if (self.records_read == max_records) return error.InboxCapacityExceeded;
            var record: [record_size]u8 = undefined;
            const actual = try self.file.readPositionalAll(io, &record, self.cursor);
            self.cursor += record_size;
            self.records_read += 1;
            if (actual != record.len) return null;
            const envelope = decode(&record) catch {
                self.corrupt_records += 1;
                return .corrupt;
            };
            return .{ .envelope = envelope };
        }
        return null;
    }

    pub fn close(self: *Reader, io: std.Io) void {
        self.file.close(io);
    }
};

pub fn encode(out: *[record_size]u8, envelope: Envelope) !void {
    try validate(envelope);
    @memset(out, 0);
    @memcpy(out[0..magic.len], magic);
    write(u16, out, 8, version);
    out[10] = @intFromEnum(envelope.kind);
    write(u32, out, 12, envelope.agent_generation);
    write(u32, out, 16, envelope.operation_generation);
    write(u64, out, 20, envelope.session_id);
    write(u64, out, 28, envelope.ownership_epoch);
    write(u64, out, 36, envelope.agent_id);
    write(u64, out, 44, envelope.operation_id);
    write(u64, out, 52, envelope.attempt_id);
    write(u64, out, 60, envelope.result_ref);
    write(u64, out, 68, envelope.result_digest);
    write(u32, out, checksum_offset, checksum(out));
}

pub fn decode(bytes: *const [record_size]u8) !Envelope {
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidInboxRecord;
    if (read(u16, bytes, 8) != version) return error.UnsupportedInboxVersion;
    if (bytes[11] != 0 or !allZero(bytes[76..80]) or !allZero(bytes[84..])) {
        return error.InvalidInboxRecord;
    }
    if (read(u32, bytes, checksum_offset) != checksum(bytes)) {
        return error.InboxChecksumMismatch;
    }
    const envelope: Envelope = .{
        .kind = std.enums.fromInt(EvidenceKind, bytes[10]) orelse
            return error.InvalidEvidenceKind,
        .agent_generation = read(u32, bytes, 12),
        .operation_generation = read(u32, bytes, 16),
        .session_id = read(u64, bytes, 20),
        .ownership_epoch = read(u64, bytes, 28),
        .agent_id = read(u64, bytes, 36),
        .operation_id = read(u64, bytes, 44),
        .attempt_id = read(u64, bytes, 52),
        .result_ref = read(u64, bytes, 60),
        .result_digest = read(u64, bytes, 68),
    };
    try validate(envelope);
    return envelope;
}

fn validate(envelope: Envelope) !void {
    if (envelope.session_id == 0 or envelope.ownership_epoch == 0 or
        envelope.agent_id == 0 or envelope.agent_generation == 0 or
        envelope.operation_id == 0 or envelope.operation_generation == 0 or
        envelope.attempt_id == 0 or envelope.result_ref == 0 or
        envelope.result_digest == 0)
    {
        return error.InvalidInboxIdentity;
    }
}

fn checksum(bytes: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(bytes[0..checksum_offset]);
    crc.update(&.{ 0, 0, 0, 0 });
    crc.update(bytes[checksum_offset + 4 ..]);
    return crc.final();
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

fn fixture(attempt_id: u64) Envelope {
    return .{
        .kind = .model,
        .session_id = 3,
        .ownership_epoch = 5,
        .agent_id = 7,
        .agent_generation = 1,
        .operation_id = 11,
        .operation_generation = 2,
        .attempt_id = attempt_id,
        .result_ref = 17,
        .result_digest = 19,
    };
}

test "Completion Inbox record is canonical and rejects corruption" {
    var bytes: [record_size]u8 = undefined;
    try encode(&bytes, fixture(13));
    try std.testing.expectEqualDeep(fixture(13), try decode(&bytes));
    bytes[68] ^= 1;
    try std.testing.expectError(error.InboxChecksumMismatch, decode(&bytes));
}

test "reader skips corrupt evidence and ignores a torn tail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var writer = try Writer.createIn(tmp.dir, io, "inbox");
    try writer.publish(io, fixture(13));
    try writer.publish(io, fixture(23));
    writer.close(io);
    var file = try tmp.dir.openFile(io, "inbox", .{ .mode = .read_write });
    var byte: [1]u8 = undefined;
    _ = try file.readPositionalAll(io, &byte, 68);
    byte[0] ^= 1;
    try file.writePositionalAll(io, &byte, 68);
    try file.setLength(io, record_size + record_size / 2);
    file.close(io);
    var reader = try Reader.openIn(tmp.dir, io, "inbox");
    defer reader.close(io);
    try std.testing.expectEqual(@as(?Envelope, null), try reader.next(io));
    try std.testing.expectEqual(@as(u32, 1), reader.corrupt_records);
}
