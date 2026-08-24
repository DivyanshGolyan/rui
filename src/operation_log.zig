const std = @import("std");

pub const record_size = 80;
pub const version: u16 = 3;

const magic = "ONEOP\x00\x00\x00";
const offset_version = 8;
const offset_kind = 10;
const offset_flags = 11;
const offset_agent_id = 12;
const offset_agent_generation = 20;
const offset_operation_generation = 24;
const offset_operation_id = 28;
const offset_attempt_id = 36;
const offset_ownership_epoch = 44;
const offset_sequence = 52;
const offset_descriptor_digest = 60;
const offset_result = 68;
const offset_crc = 76;

pub const Kind = enum(u8) {
    accepted = 1,
    completed = 2,
    descriptor_validated = 3,
    permission_decided = 4,
    attempt_started = 5,
    attempt_result = 6,
    attempt_indeterminate = 7,
    denied_result = 8,
};

pub const RecoveryClass = enum(u8) {
    safe_read = 1,
    billable_retry = 2,
    consequential = 3,
};

pub const Record = struct {
    kind: Kind,
    agent_id: u64,
    agent_generation: u32,
    operation_id: u64,
    operation_generation: u32,
    attempt_id: u64,
    ownership_epoch: u64,
    recovery_class: RecoveryClass,
    sequence: u64,
    descriptor_digest: u64,
    result: u64,
};

pub const Writer = struct {
    file: std.Io.File,
    offset: u64,
    last_sequence: u64,

    pub fn create(io: std.Io, path: []const u8) !Writer {
        return createIn(std.Io.Dir.cwd(), io, path);
    }

    pub fn createIn(dir: std.Io.Dir, io: std.Io, path: []const u8) !Writer {
        return .{
            .file = try dir.createFile(io, path, .{}),
            .offset = 0,
            .last_sequence = 0,
        };
    }

    pub fn openAppend(io: std.Io, path: []const u8) !Writer {
        return openAppendIn(std.Io.Dir.cwd(), io, path);
    }

    pub fn openAppendIn(dir: std.Io.Dir, io: std.Io, path: []const u8) !Writer {
        var reader = try Reader.openIn(dir, io, path);
        defer reader.close(io);
        while (try reader.next(io)) |_| {}

        return .{
            .file = try dir.openFile(io, path, .{ .mode = .read_write }),
            .offset = reader.offset,
            .last_sequence = reader.last_sequence,
        };
    }

    pub fn close(self: *Writer, io: std.Io) void {
        self.file.close(io);
    }

    pub fn appendDurable(self: *Writer, io: std.Io, record: Record) !void {
        if (record.sequence <= self.last_sequence) return error.NonMonotonicSequence;
        var bytes: [record_size]u8 = undefined;
        try encode(&bytes, record);
        try self.file.writePositionalAll(io, &bytes, self.offset);
        try self.file.sync(io);
        self.offset += record_size;
        self.last_sequence = record.sequence;
    }
};

pub const Reader = struct {
    file: std.Io.File,
    offset: u64 = 0,
    last_sequence: u64 = 0,

    pub fn open(io: std.Io, path: []const u8) !Reader {
        return openIn(std.Io.Dir.cwd(), io, path);
    }

    pub fn openIn(dir: std.Io.Dir, io: std.Io, path: []const u8) !Reader {
        return .{ .file = try dir.openFile(io, path, .{}) };
    }

    pub fn close(self: *Reader, io: std.Io) void {
        self.file.close(io);
    }

    pub fn next(self: *Reader, io: std.Io) !?Record {
        var bytes: [record_size]u8 = undefined;
        const bytes_read = try self.file.readPositionalAll(io, &bytes, self.offset);
        if (bytes_read == 0) return null;
        if (bytes_read != record_size) return error.TruncatedRecord;
        const record = try decode(&bytes);
        if (record.sequence <= self.last_sequence) return error.NonMonotonicSequence;
        self.offset += record_size;
        self.last_sequence = record.sequence;
        return record;
    }
};

pub fn encode(out: *[record_size]u8, record: Record) !void {
    if (record.agent_id == 0) return error.InvalidAgentIdentity;
    if (record.agent_generation == 0) return error.InvalidAgentGeneration;
    if (record.operation_id == 0) return error.InvalidOperationIdentity;
    if (record.operation_generation == 0) return error.InvalidOperationGeneration;
    const needs_attempt = switch (record.kind) {
        .accepted, .completed, .attempt_started, .attempt_result, .attempt_indeterminate => true,
        .descriptor_validated, .permission_decided, .denied_result => false,
    };
    if (needs_attempt == (record.attempt_id == 0)) return error.InvalidAttemptIdentity;
    if (record.ownership_epoch == 0) return error.InvalidOwnershipEpoch;
    if (record.sequence == 0) return error.InvalidSequence;
    if (record.descriptor_digest == 0) return error.InvalidDescriptorDigest;
    switch (record.kind) {
        .accepted => if (record.result != 0) return error.AcceptedRecordHasResult,
        .descriptor_validated, .attempt_started => if (record.result != 0) return error.IntentRecordHasResult,
        .permission_decided => if (record.result < 1 or record.result > 2) return error.InvalidPermissionResult,
        .completed, .attempt_result, .denied_result => if (record.result == 0) return error.ResultRecordMissingResult,
        .attempt_indeterminate => {},
    }

    @memset(out, 0);
    @memcpy(out[0..magic.len], magic);
    write(u16, out, offset_version, version);
    out[offset_kind] = @intFromEnum(record.kind);
    out[offset_flags] = @intFromEnum(record.recovery_class);
    write(u64, out, offset_agent_id, record.agent_id);
    write(u32, out, offset_agent_generation, record.agent_generation);
    write(u32, out, offset_operation_generation, record.operation_generation);
    write(u64, out, offset_operation_id, record.operation_id);
    write(u64, out, offset_attempt_id, record.attempt_id);
    write(u64, out, offset_ownership_epoch, record.ownership_epoch);
    write(u64, out, offset_sequence, record.sequence);
    write(u64, out, offset_descriptor_digest, record.descriptor_digest);
    write(u64, out, offset_result, record.result);
    write(u32, out, offset_crc, std.hash.Crc32.hash(out[0..offset_crc]));
}

pub fn decode(bytes: *const [record_size]u8) !Record {
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidMagic;
    if (read(u16, bytes, offset_version) != version) return error.UnsupportedVersion;
    const recovery_class: RecoveryClass = switch (bytes[offset_flags]) {
        1 => .safe_read,
        2 => .billable_retry,
        3 => .consequential,
        else => return error.InvalidRecoveryClass,
    };

    const stored_crc = read(u32, bytes, offset_crc);
    if (stored_crc != std.hash.Crc32.hash(bytes[0..offset_crc])) {
        return error.ChecksumMismatch;
    }

    const kind: Kind = switch (bytes[offset_kind]) {
        1 => .accepted,
        2 => .completed,
        3 => .descriptor_validated,
        4 => .permission_decided,
        5 => .attempt_started,
        6 => .attempt_result,
        7 => .attempt_indeterminate,
        8 => .denied_result,
        else => return error.InvalidKind,
    };
    const record: Record = .{
        .kind = kind,
        .agent_id = read(u64, bytes, offset_agent_id),
        .agent_generation = read(u32, bytes, offset_agent_generation),
        .operation_id = read(u64, bytes, offset_operation_id),
        .operation_generation = read(u32, bytes, offset_operation_generation),
        .attempt_id = read(u64, bytes, offset_attempt_id),
        .ownership_epoch = read(u64, bytes, offset_ownership_epoch),
        .recovery_class = recovery_class,
        .sequence = read(u64, bytes, offset_sequence),
        .descriptor_digest = read(u64, bytes, offset_descriptor_digest),
        .result = read(u64, bytes, offset_result),
    };

    var canonical: [record_size]u8 = undefined;
    try encode(&canonical, record);
    if (!std.mem.eql(u8, bytes, &canonical)) return error.NonCanonicalRecord;
    return record;
}

pub fn validateExpected(
    record: Record,
    expected_agent_id: u64,
    expected_agent_generation: u32,
    expected_operation_id: u64,
    expected_operation_generation: u32,
    expected_ownership_epoch: u64,
) !void {
    if (record.agent_id != expected_agent_id) return error.AgentIdentityMismatch;
    if (record.agent_generation != expected_agent_generation) return error.AgentGenerationMismatch;
    if (record.operation_id != expected_operation_id) return error.OperationIdentityMismatch;
    if (record.operation_generation != expected_operation_generation) {
        return error.OperationGenerationMismatch;
    }
    if (record.ownership_epoch != expected_ownership_epoch) return error.OwnershipEpochMismatch;
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

test "operation record round trip" {
    const expected: Record = .{
        .kind = .completed,
        .agent_id = 42,
        .agent_generation = 7,
        .operation_id = 99,
        .operation_generation = 4,
        .attempt_id = 100,
        .ownership_epoch = 2,
        .recovery_class = .safe_read,
        .sequence = 3,
        .descriptor_digest = 101,
        .result = 1234,
    };
    var bytes: [record_size]u8 = undefined;
    try encode(&bytes, expected);
    const actual = try decode(&bytes);
    try std.testing.expectEqualDeep(expected, actual);
}

test "operation record rejects corruption and unsupported metadata" {
    const accepted: Record = .{
        .kind = .accepted,
        .agent_id = 42,
        .agent_generation = 7,
        .operation_id = 99,
        .operation_generation = 4,
        .attempt_id = 100,
        .ownership_epoch = 2,
        .recovery_class = .safe_read,
        .sequence = 3,
        .descriptor_digest = 101,
        .result = 0,
    };
    var bytes: [record_size]u8 = undefined;
    try encode(&bytes, accepted);

    bytes[offset_operation_id] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&bytes));
    bytes[offset_operation_id] ^= 1;

    bytes[offset_kind] = 9;
    write(u32, &bytes, offset_crc, std.hash.Crc32.hash(bytes[0..offset_crc]));
    try std.testing.expectError(error.InvalidKind, decode(&bytes));

    bytes[offset_kind] = @intFromEnum(Kind.accepted);
    bytes[offset_flags] = 0;
    write(u32, &bytes, offset_crc, std.hash.Crc32.hash(bytes[0..offset_crc]));
    try std.testing.expectError(error.InvalidRecoveryClass, decode(&bytes));
}

test "accepted records cannot contain results" {
    var bytes: [record_size]u8 = undefined;
    try std.testing.expectError(error.AcceptedRecordHasResult, encode(&bytes, .{
        .kind = .accepted,
        .agent_id = 42,
        .agent_generation = 7,
        .operation_id = 99,
        .operation_generation = 4,
        .attempt_id = 100,
        .ownership_epoch = 2,
        .recovery_class = .safe_read,
        .sequence = 3,
        .descriptor_digest = 101,
        .result = 1,
    }));
}

test "expected identity rejects stale records" {
    const record: Record = .{
        .kind = .completed,
        .agent_id = 42,
        .agent_generation = 7,
        .operation_id = 99,
        .operation_generation = 4,
        .attempt_id = 100,
        .ownership_epoch = 2,
        .recovery_class = .safe_read,
        .sequence = 3,
        .descriptor_digest = 101,
        .result = 1,
    };
    try validateExpected(record, 42, 7, 99, 4, 2);
    try std.testing.expectError(error.AgentIdentityMismatch, validateExpected(record, 43, 7, 99, 4, 2));
    try std.testing.expectError(error.AgentGenerationMismatch, validateExpected(record, 42, 8, 99, 4, 2));
    try std.testing.expectError(error.OperationIdentityMismatch, validateExpected(record, 42, 7, 100, 4, 2));
    try std.testing.expectError(error.OperationGenerationMismatch, validateExpected(record, 42, 7, 99, 5, 2));
    try std.testing.expectError(error.OwnershipEpochMismatch, validateExpected(record, 42, 7, 99, 4, 3));
}

test "journal rejects truncation and nonmonotonic sequence" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first: Record = .{
        .kind = .accepted,
        .agent_id = 42,
        .agent_generation = 7,
        .operation_id = 99,
        .operation_generation = 4,
        .attempt_id = 100,
        .ownership_epoch = 2,
        .recovery_class = .safe_read,
        .sequence = 2,
        .descriptor_digest = 101,
        .result = 0,
    };
    const second: Record = .{
        .kind = .completed,
        .agent_id = 42,
        .agent_generation = 7,
        .operation_id = 99,
        .operation_generation = 4,
        .attempt_id = 100,
        .ownership_epoch = 2,
        .recovery_class = .safe_read,
        .sequence = 1,
        .descriptor_digest = 101,
        .result = 1234,
    };
    var first_bytes: [record_size]u8 = undefined;
    var second_bytes: [record_size]u8 = undefined;
    try encode(&first_bytes, first);
    try encode(&second_bytes, second);

    try tmp.dir.writeFile(io, .{ .sub_path = "truncated", .data = first_bytes[0 .. record_size - 1] });
    var truncated = try Reader.openIn(tmp.dir, io, "truncated");
    defer truncated.close(io);
    try std.testing.expectError(error.TruncatedRecord, truncated.next(io));

    var combined: [record_size * 2]u8 = undefined;
    @memcpy(combined[0..record_size], &first_bytes);
    @memcpy(combined[record_size..], &second_bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "nonmonotonic", .data = &combined });
    var nonmonotonic = try Reader.openIn(tmp.dir, io, "nonmonotonic");
    defer nonmonotonic.close(io);
    _ = try nonmonotonic.next(io);
    try std.testing.expectError(error.NonMonotonicSequence, nonmonotonic.next(io));
}

test "writer synchronizes canonical records" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var writer = try Writer.createIn(tmp.dir, io, "journal");
        defer writer.close(io);
        try writer.appendDurable(io, .{
            .kind = .accepted,
            .agent_id = 42,
            .agent_generation = 7,
            .operation_id = 99,
            .operation_generation = 4,
            .attempt_id = 100,
            .ownership_epoch = 2,
            .recovery_class = .safe_read,
            .sequence = 1,
            .descriptor_digest = 101,
            .result = 0,
        });
    }

    var resumed = try Writer.openAppendIn(tmp.dir, io, "journal");
    defer resumed.close(io);
    try resumed.appendDurable(io, .{
        .kind = .completed,
        .agent_id = 42,
        .agent_generation = 7,
        .operation_id = 99,
        .operation_generation = 4,
        .attempt_id = 100,
        .ownership_epoch = 2,
        .recovery_class = .safe_read,
        .sequence = 2,
        .descriptor_digest = 101,
        .result = 1234,
    });
    try std.testing.expectEqual(@as(u64, record_size * 2), resumed.offset);
    try std.testing.expectError(error.NonMonotonicSequence, resumed.appendDurable(io, .{
        .kind = .completed,
        .agent_id = 42,
        .agent_generation = 7,
        .operation_id = 99,
        .operation_generation = 4,
        .attempt_id = 100,
        .ownership_epoch = 2,
        .recovery_class = .safe_read,
        .sequence = 2,
        .descriptor_digest = 101,
        .result = 1234,
    }));
}
