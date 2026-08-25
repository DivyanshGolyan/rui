const std = @import("std");
const core_state = @import("core_state.zig");

pub const version: u16 = 1;
pub const max_facts: usize = 8;
pub const max_frames: u32 = 4096;
pub const fact_size: usize = 72;
pub const header_size: usize = 40;
pub const max_frame_size: usize = header_size + max_facts * fact_size + core_state.encoded_size;
pub const max_file_size: u64 = (@as(u64, max_frames) + 1) * max_frame_size;

const magic = "ONEWAL\x00\x00";
const checksum_offset = 32;

pub const Kind = enum(u8) {
    task_admitted = 1,
    operation_submitted = 2,
    operation_accepted = 3,
    attempt_admitted = 4,
    authorization = 5,
    result = 6,
    conversation_advanced = 7,
    outcome = 8,
    cancellation = 9,
    shutdown = 10,
    result_applied = 11,
};

pub const RecoveryClass = enum(u8) {
    none = 0,
    model = 1,
    consequential = 2,
};

pub const Disposition = enum(u8) {
    none = 0,
    definitely_unsent = 1,
    possibly_executed = 2,
    terminal = 3,
};

pub const Fact = struct {
    kind: Kind,
    recovery_class: RecoveryClass = .none,
    disposition: Disposition = .none,
    flags: u8 = 0,
    agent_id: u64 = 0,
    operation_id: u64 = 0,
    attempt_id: u64 = 0,
    subject: u64 = 0,
    reference: u64 = 0,
    digest: u64 = 0,
    ownership_epoch: u64 = 0,
    generation: u32 = 0,
    agent_generation: u32 = 0,
};

pub const Transaction = struct {
    sequence: u64,
    facts: [max_facts]Fact = undefined,
    fact_count: u8,
    core: ?[core_state.encoded_size]u8 = null,

    pub fn factSlice(self: *const Transaction) []const Fact {
        return self.facts[0..self.fact_count];
    }
};

pub const Writer = struct {
    file: std.Io.File,
    last_sequence: u64,

    pub fn createIn(dir: std.Io.Dir, io: std.Io, path: []const u8) !Writer {
        const file = try dir.createFile(io, path, .{ .exclusive = true });
        return .{ .file = file, .last_sequence = 0 };
    }

    pub fn openAppendIn(dir: std.Io.Dir, io: std.Io, path: []const u8) !Writer {
        var reader = try Reader.openIn(dir, io, path);
        errdefer reader.close(io);
        while (try reader.next(io)) |_| {}
        const last_sequence = reader.last_sequence;
        const valid_length = reader.cursor;
        const physical_length = reader.length;
        reader.close(io);
        const file = try dir.openFile(io, path, .{ .mode = .read_write });
        errdefer file.close(io);
        if (valid_length != physical_length) {
            try file.setLength(io, valid_length);
            try file.sync(io);
        }
        return .{ .file = file, .last_sequence = last_sequence };
    }

    pub fn openValidatedIn(
        dir: std.Io.Dir,
        io: std.Io,
        path: []const u8,
        last_sequence: u64,
        valid_length: u64,
        physical_length: u64,
    ) !Writer {
        if (last_sequence > max_frames or valid_length > physical_length or
            physical_length > max_file_size)
        {
            return error.InvalidValidatedWalPosition;
        }
        const file = try dir.openFile(io, path, .{ .mode = .read_write });
        errdefer file.close(io);
        if (valid_length != physical_length) {
            try file.setLength(io, valid_length);
            try file.sync(io);
        }
        return .{ .file = file, .last_sequence = last_sequence };
    }

    pub fn append(self: *Writer, io: std.Io, transaction: Transaction) !void {
        if (self.last_sequence >= max_frames) return error.WalCapacityExceeded;
        if (transaction.sequence != self.last_sequence + 1) {
            return error.NonmonotonicSequence;
        }
        var frame: [max_frame_size]u8 = undefined;
        const encoded = try encode(&frame, transaction);
        const position = try self.file.length(io);
        try self.file.writePositionalAll(io, encoded, position);
        try self.file.sync(io);
        self.last_sequence = transaction.sequence;
    }

    pub fn close(self: *Writer, io: std.Io) void {
        self.file.close(io);
    }
};

pub const Reader = struct {
    file: std.Io.File,
    cursor: u64 = 0,
    length: u64,
    last_sequence: u64 = 0,
    stopped_at_tail: bool = false,
    frames_read: u32 = 0,

    pub fn openIn(dir: std.Io.Dir, io: std.Io, path: []const u8) !Reader {
        const file = try dir.openFile(io, path, .{});
        errdefer file.close(io);
        const length = try file.length(io);
        if (length > max_file_size) return error.WalCapacityExceeded;
        return .{ .file = file, .length = length };
    }

    pub fn next(self: *Reader, io: std.Io) !?Transaction {
        if (self.stopped_at_tail or self.cursor == self.length) return null;
        if (self.frames_read == max_frames) return error.WalCapacityExceeded;
        const remaining = self.length - self.cursor;
        if (remaining < header_size) {
            self.stopped_at_tail = true;
            return null;
        }
        var header: [header_size]u8 = undefined;
        const header_read = try self.file.readPositionalAll(io, &header, self.cursor);
        if (header_read != header.len) {
            self.stopped_at_tail = true;
            return null;
        }
        const declared_length = read(u32, &header, 12);
        const plausible_length = declared_length >= header_size and declared_length <= max_frame_size;
        if (!plausible_length) return self.handleInvalidTail(io, remaining, null);
        if (remaining < declared_length) {
            self.stopped_at_tail = true;
            return null;
        }
        var frame: [max_frame_size]u8 = undefined;
        const frame_length: usize = @intCast(declared_length);
        const actual = try self.file.readPositionalAll(io, frame[0..frame_length], self.cursor);
        if (actual != frame_length) {
            self.stopped_at_tail = true;
            return null;
        }
        const transaction = decode(frame[0..frame_length]) catch |err| {
            return self.handleInvalidTail(io, remaining, err);
        };
        if (transaction.sequence != self.last_sequence + 1) {
            return self.handleInvalidTail(io, remaining, error.NonmonotonicSequence);
        }
        self.cursor += declared_length;
        self.last_sequence = transaction.sequence;
        self.frames_read += 1;
        return transaction;
    }

    fn handleInvalidTail(
        self: *Reader,
        io: std.Io,
        remaining: u64,
        cause: ?anyerror,
    ) !?Transaction {
        var next_magic_buffer: [8]u8 = undefined;
        var offset: u64 = 1;
        while (offset + next_magic_buffer.len <= remaining) : (offset += 1) {
            const count = try self.file.readPositionalAll(
                io,
                &next_magic_buffer,
                self.cursor + offset,
            );
            if (count == next_magic_buffer.len and std.mem.eql(u8, &next_magic_buffer, magic)) {
                return cause orelse error.CorruptWalHistory;
            }
        }
        self.stopped_at_tail = true;
        return null;
    }

    pub fn close(self: *Reader, io: std.Io) void {
        self.file.close(io);
    }
};

pub fn encode(out: *[max_frame_size]u8, transaction: Transaction) ![]const u8 {
    if (transaction.sequence == 0 or transaction.fact_count == 0 or
        transaction.fact_count > max_facts)
    {
        return error.InvalidTransaction;
    }
    const core_length: usize = if (transaction.core != null) core_state.encoded_size else 0;
    const frame_length = header_size + @as(usize, transaction.fact_count) * fact_size + core_length;
    @memset(out, 0);
    @memcpy(out[0..magic.len], magic);
    write(u16, out, 8, version);
    write(u16, out, 10, header_size);
    write(u32, out, 12, @intCast(frame_length));
    write(u64, out, 16, transaction.sequence);
    write(u16, out, 24, transaction.fact_count);
    write(u16, out, 26, @intCast(core_length));
    var cursor: usize = header_size;
    for (transaction.factSlice()) |fact| {
        try encodeFact(out[cursor..][0..fact_size], fact);
        cursor += fact_size;
    }
    if (transaction.core) |state| {
        _ = try core_state.decode(&state);
        @memcpy(out[cursor..][0..state.len], &state);
    }
    write(u32, out, checksum_offset, frameChecksum(out[0..frame_length]));
    return out[0..frame_length];
}

pub fn decode(frame: []const u8) !Transaction {
    if (frame.len < header_size or !std.mem.eql(u8, frame[0..magic.len], magic)) {
        return error.InvalidWalFrame;
    }
    if (read(u16, frame, 8) != version) return error.UnsupportedWalVersion;
    if (read(u16, frame, 10) != header_size or read(u32, frame, 12) != frame.len) {
        return error.InvalidWalFrame;
    }
    const sequence = read(u64, frame, 16);
    const fact_count = read(u16, frame, 24);
    const core_length = read(u16, frame, 26);
    if (sequence == 0 or fact_count == 0 or fact_count > max_facts or
        (core_length != 0 and core_length != core_state.encoded_size))
    {
        return error.InvalidWalFrame;
    }
    const expected_length = header_size + @as(usize, fact_count) * fact_size + core_length;
    if (expected_length != frame.len) return error.InvalidWalFrame;
    if (read(u32, frame, checksum_offset) != frameChecksum(frame)) {
        return error.WalChecksumMismatch;
    }
    var transaction: Transaction = .{
        .sequence = sequence,
        .fact_count = @intCast(fact_count),
    };
    var cursor: usize = header_size;
    for (0..fact_count) |index| {
        transaction.facts[index] = try decodeFact(frame[cursor..][0..fact_size]);
        cursor += fact_size;
    }
    if (core_length != 0) {
        var state: [core_state.encoded_size]u8 = undefined;
        @memcpy(&state, frame[cursor..][0..core_state.encoded_size]);
        _ = try core_state.decode(&state);
        transaction.core = state;
    }
    return transaction;
}

fn encodeFact(out: []u8, fact: Fact) !void {
    if (fact.agent_id == 0 or fact.agent_generation == 0 or fact.ownership_epoch == 0) {
        return error.InvalidFactIdentity;
    }
    @memset(out, 0);
    out[0] = @intFromEnum(fact.kind);
    out[1] = @intFromEnum(fact.recovery_class);
    out[2] = @intFromEnum(fact.disposition);
    out[3] = fact.flags;
    write(u32, out, 4, fact.generation);
    write(u32, out, 8, fact.agent_generation);
    write(u64, out, 12, fact.agent_id);
    write(u64, out, 20, fact.operation_id);
    write(u64, out, 28, fact.attempt_id);
    write(u64, out, 36, fact.subject);
    write(u64, out, 44, fact.reference);
    write(u64, out, 52, fact.digest);
    write(u64, out, 60, fact.ownership_epoch);
}

fn decodeFact(bytes: []const u8) !Fact {
    const fact: Fact = .{
        .kind = std.enums.fromInt(Kind, bytes[0]) orelse return error.InvalidFactKind,
        .recovery_class = std.enums.fromInt(RecoveryClass, bytes[1]) orelse
            return error.InvalidRecoveryClass,
        .disposition = std.enums.fromInt(Disposition, bytes[2]) orelse
            return error.InvalidAttemptDisposition,
        .flags = bytes[3],
        .generation = read(u32, bytes, 4),
        .agent_generation = read(u32, bytes, 8),
        .agent_id = read(u64, bytes, 12),
        .operation_id = read(u64, bytes, 20),
        .attempt_id = read(u64, bytes, 28),
        .subject = read(u64, bytes, 36),
        .reference = read(u64, bytes, 44),
        .digest = read(u64, bytes, 52),
        .ownership_epoch = read(u64, bytes, 60),
    };
    if (fact.agent_id == 0 or fact.agent_generation == 0 or fact.ownership_epoch == 0 or
        bytes[68] != 0 or bytes[69] != 0 or bytes[70] != 0 or bytes[71] != 0)
    {
        return error.InvalidFact;
    }
    return fact;
}

fn frameChecksum(frame: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(frame[0..checksum_offset]);
    crc.update(&.{ 0, 0, 0, 0 });
    crc.update(frame[checksum_offset + 4 ..]);
    return crc.final();
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

fn testFact(kind: Kind) Fact {
    return .{
        .kind = kind,
        .agent_id = 7,
        .agent_generation = 1,
        .operation_id = 11,
        .attempt_id = 13,
        .subject = 17,
        .reference = 19,
        .digest = 23,
        .generation = 2,
        .ownership_epoch = 1,
    };
}

test "transaction frame preserves several semantic facts and Core State" {
    var state_bytes: [core_state.encoded_size]u8 = undefined;
    try core_state.encode(&state_bytes, .{
        .agent_id = 7,
        .agent_generation = 1,
        .accumulator = 7,
    });
    var transaction: Transaction = .{ .sequence = 1, .fact_count = 2, .core = state_bytes };
    transaction.facts[0] = testFact(.operation_accepted);
    transaction.facts[1] = testFact(.attempt_admitted);
    transaction.facts[1].disposition = .possibly_executed;
    var frame: [max_frame_size]u8 = undefined;
    const encoded = try encode(&frame, transaction);
    const decoded = try decode(encoded);
    try std.testing.expectEqual(@as(u64, 1), decoded.sequence);
    try std.testing.expectEqualSlices(Fact, transaction.factSlice(), decoded.factSlice());
    try std.testing.expectEqualSlices(u8, &state_bytes, &decoded.core.?);
}

test "reader exposes only complete checksummed transaction frames" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var first: Transaction = .{ .sequence = 1, .fact_count = 1 };
    first.facts[0] = testFact(.task_admitted);
    var second: Transaction = .{ .sequence = 2, .fact_count = 1 };
    second.facts[0] = testFact(.outcome);
    var first_buffer: [max_frame_size]u8 = undefined;
    var second_buffer: [max_frame_size]u8 = undefined;
    const first_bytes = try encode(&first_buffer, first);
    const second_bytes = try encode(&second_buffer, second);
    for (0..second_bytes.len) |cut| {
        var file = try tmp.dir.createFile(io, "wal", .{ .truncate = true });
        try file.writeStreamingAll(io, first_bytes);
        try file.writeStreamingAll(io, second_bytes[0..cut]);
        try file.sync(io);
        file.close(io);
        var reader = try Reader.openIn(tmp.dir, io, "wal");
        defer reader.close(io);
        try std.testing.expectEqual(@as(u64, 1), (try reader.next(io)).?.sequence);
        try std.testing.expectEqual(@as(?Transaction, null), try reader.next(io));
    }
}

test "a corrupt terminal frame leaves the prior valid prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var writer = try Writer.createIn(tmp.dir, io, "wal");
    var first: Transaction = .{ .sequence = 1, .fact_count = 1 };
    first.facts[0] = testFact(.task_admitted);
    try writer.append(io, first);
    var second: Transaction = .{ .sequence = 2, .fact_count = 1 };
    second.facts[0] = testFact(.outcome);
    try writer.append(io, second);
    writer.close(io);
    var file = try tmp.dir.openFile(io, "wal", .{ .mode = .read_write });
    const length = try file.length(io);
    var byte: [1]u8 = undefined;
    _ = try file.readPositionalAll(io, &byte, length - 1);
    byte[0] ^= 0xff;
    try file.writePositionalAll(io, &byte, length - 1);
    file.close(io);
    var reader = try Reader.openIn(tmp.dir, io, "wal");
    defer reader.close(io);
    try std.testing.expectEqual(@as(u64, 1), (try reader.next(io)).?.sequence);
    try std.testing.expectEqual(@as(?Transaction, null), try reader.next(io));
}

test "append removes every torn terminal suffix before publishing the next frame" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var first: Transaction = .{ .sequence = 1, .fact_count = 1 };
    first.facts[0] = testFact(.task_admitted);
    var second: Transaction = .{ .sequence = 2, .fact_count = 1 };
    second.facts[0] = testFact(.outcome);
    var first_buffer: [max_frame_size]u8 = undefined;
    var second_buffer: [max_frame_size]u8 = undefined;
    const first_bytes = try encode(&first_buffer, first);
    const second_bytes = try encode(&second_buffer, second);
    for (0..second_bytes.len) |cut| {
        var file = try tmp.dir.createFile(io, "wal", .{ .truncate = true });
        try file.writeStreamingAll(io, first_bytes);
        try file.writeStreamingAll(io, second_bytes[0..cut]);
        try file.sync(io);
        file.close(io);

        var writer = try Writer.openAppendIn(tmp.dir, io, "wal");
        try writer.append(io, second);
        writer.close(io);

        var reader = try Reader.openIn(tmp.dir, io, "wal");
        try std.testing.expectEqual(@as(u64, 1), (try reader.next(io)).?.sequence);
        try std.testing.expectEqual(@as(u64, 2), (try reader.next(io)).?.sequence);
        try std.testing.expectEqual(@as(?Transaction, null), try reader.next(io));
        reader.close(io);
    }
}
