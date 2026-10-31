//! Shared output projections and scratch metadata codec. No Store or provider parser.
const std = @import("std");
const named_scratch = @import("named_scratch.zig");
const protocol = @import("protocol.zig");

pub const ModelOperationKind = @import("turn_policy.zig").Purpose;
pub const OutputItemKind = enum(u8) { reasoning = 1, message = 2, function_call = 3, compaction = 4 };
pub const OutputRecordTag = enum(u8) {
    item = 1,
    // 2 was a message text record; a message's text is its parts.
    usage = 3,
    item_id = 4,
    name = 5,
    call_id = 6,
    arguments = 7,
    /// One part of an item in Rui's own form, in item order: the encoded
    /// range of its text in the source, with the decoded length and digest
    /// (empty for an opaque block).
    part = 8,
    /// Closes one provider bag: its total length and digest. The bag is the
    /// `member` records of its scope since the previous trailer of that
    /// scope, joined by commas.
    extras = 9,
    /// One raw `"key":value` member of a provider bag, as received.
    member = 10,
};

/// What a part holds. `opaque_block` is a block Rui does not read: its
/// whole object lives in its part bag.
pub const PartKind = enum(u8) { opaque_block = 0, output_text = 1, refusal = 2, summary_text = 3, reasoning_text = 4 };
/// A message's phase in Rui's form; any other literal stays in the item bag.
pub const NeutralPhase = enum(u8) { unphased = 0, commentary = 1, final_answer = 2 };
/// The item array a part belongs to.
pub const PartArray = enum(u8) { none = 0, content = 1, summary = 2 };
/// Whether a bag record belongs to the item or to the latest part.
pub const BagScope = enum(u8) { item = 0, part = 1 };

pub const OutputMetadataRecord = struct {
    tag: OutputRecordTag,
    kind: OutputItemKind = .reasoning,
    ordinal: u64 = 0,
    start: u64,
    length: u64,
    decoded_length: u64 = 0,
    id_digest: [32]u8 = @splat(0),
    content_digest: [32]u8 = @splat(0),
    usage_tokens: ?u64 = null,
    /// An item record's replay rule, judged once at acceptance: a reasoning
    /// item whose nonempty `content` holds only reasoning_text blocks, which
    /// replay leaves out.
    omit_reasoning_text: bool = false,
    /// A part record's kind and array.
    part_kind: PartKind = .opaque_block,
    part_array: PartArray = .none,
    /// A bag record's owner.
    scope: BagScope = .item,
    /// A message item record's phase in Rui's form.
    phase: NeutralPhase = .unphased,

    /// One past the record's last encoded byte.
    pub fn end(self: *const OutputMetadataRecord) !u64 {
        return std.math.add(u64, self.start, self.length);
    }
};

pub const output_metadata_record_bytes = 104;

pub const OutputMetadataWriter = struct {
    io: std.Io,
    file: std.Io.File,
    budget: protocol.ScratchBudget,
    charged: u64 = 0,
    records: u64 = 0,
    decoded_length: u64 = 0,
    fail_writes: bool = false,
    sealed: bool = false,

    pub fn init(
        io: std.Io,
        scratch_path: []const u8,
        name: []const u8,
        budget: protocol.ScratchBudget,
        fail_unlink: bool,
        retained: *?named_scratch.Owner,
    ) !OutputMetadataWriter {
        retained.* = null;
        var scratch = try std.Io.Dir.cwd().openDir(io, scratch_path, .{});
        defer scratch.close(io);
        const file = try scratch.createFile(io, name, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        if (fail_unlink) {
            retained.* = .init(
                io,
                file,
                null,
                name,
                budget,
                0,
                .injected_failure,
            );
            return error.InjectedMetadataUnlinkFailure;
        }
        scratch.deleteFile(io, name) catch |err| {
            retained.* = .init(io, file, null, name, budget, 0, .native);
            return err;
        };
        return .{ .io = io, .file = file, .budget = budget };
    }

    pub fn append(self: *OutputMetadataWriter, record: OutputMetadataRecord) !void {
        std.debug.assert(!self.sealed);
        if (self.fail_writes) return error.InjectedMetadataFailure;
        if (!self.budget.allocate(output_metadata_record_bytes)) {
            return error.MetadataScratchExhausted;
        }
        // A failed write ends validation; retain the complete fixed-record
        // reservation until deinit so a partial OS write is never uncharged.
        self.charged += output_metadata_record_bytes;
        var bytes: [output_metadata_record_bytes]u8 = @splat(0);
        bytes[0] = @backingInt(record.tag);
        bytes[1] = @backingInt(record.kind);
        std.debug.assert(record.usage_tokens == null or record.tag == .usage);
        bytes[2] = @intFromBool(record.usage_tokens != null);
        std.debug.assert(!record.omit_reasoning_text or (record.tag == .item and record.kind == .reasoning));
        bytes[3] = @intFromBool(record.omit_reasoning_text);
        std.debug.assert(record.tag == .part or (record.part_kind == .opaque_block and record.part_array == .none));
        std.debug.assert(record.tag != .part or record.part_array != .none);
        std.debug.assert(record.scope == .item or record.tag == .extras or record.tag == .member);
        bytes[4] = @backingInt(record.part_kind);
        bytes[5] = @backingInt(record.scope);
        bytes[6] = @backingInt(record.part_array);
        std.debug.assert(record.phase == .unphased or (record.tag == .item and record.kind == .message));
        bytes[7] = @backingInt(record.phase);
        // Usage has no item ordinal; this slot holds its certified pressure.
        std.mem.writeInt(u64, bytes[8..16], record.usage_tokens orelse record.ordinal, .little);
        std.mem.writeInt(u64, bytes[16..24], record.start, .little);
        std.mem.writeInt(u64, bytes[24..32], record.length, .little);
        std.mem.writeInt(u64, bytes[32..40], record.decoded_length, .little);
        @memcpy(bytes[40..72], &record.id_digest);
        @memcpy(bytes[72..104], &record.content_digest);
        try self.file.writeStreamingAll(self.io, &bytes);
        self.records += 1;
        if (record.tag == .part and record.kind == .message) {
            self.decoded_length = try std.math.add(u64, self.decoded_length, record.decoded_length);
        }
    }

    pub fn sealForRead(self: *OutputMetadataWriter) !void {
        if (self.sealed) return;
        if (try self.file.length(self.io) != self.charged) return error.MetadataSealFailed;
        self.sealed = true;
    }

    pub fn deinit(self: *OutputMetadataWriter) void {
        self.file.close(self.io);
        self.budget.release(self.charged);
        self.* = undefined;
    }
};

pub const OutputMetadataReader = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,
    length: u64,

    pub fn init(io: std.Io, file: std.Io.File, _: u64) !OutputMetadataReader {
        const length = try file.length(io);
        return .{ .io = io, .file = file, .length = length };
    }

    pub fn next(self: *OutputMetadataReader) !?OutputMetadataRecord {
        if (self.offset == self.length) return null;
        if (self.length - self.offset < output_metadata_record_bytes) return error.CorruptOutputMetadata;
        var bytes: [output_metadata_record_bytes]u8 = undefined;
        const count = try self.file.readPositionalAll(self.io, &bytes, self.offset);
        if (count != bytes.len) return error.CorruptOutputMetadata;
        self.offset += bytes.len;
        if (bytes[2] > 1 or (bytes[2] == 1 and bytes[0] != @backingInt(OutputRecordTag.usage))) return error.CorruptOutputMetadata;
        if (bytes[3] > 1 or (bytes[3] == 1 and (bytes[0] != @backingInt(OutputRecordTag.item) or
            bytes[1] != @backingInt(OutputItemKind.reasoning)))) return error.CorruptOutputMetadata;
        const is_part = bytes[0] == @backingInt(OutputRecordTag.part);
        const is_bag = bytes[0] == @backingInt(OutputRecordTag.extras) or bytes[0] == @backingInt(OutputRecordTag.member);
        if (bytes[4] > 4 or bytes[5] > 1 or bytes[6] > 2 or (!is_part and (bytes[4] != 0 or bytes[6] != 0)) or
            (is_part and bytes[6] == 0) or (!is_bag and bytes[5] != 0)) return error.CorruptOutputMetadata;
        if (bytes[7] > 2 or (bytes[7] != 0 and (bytes[0] != @backingInt(OutputRecordTag.item) or
            bytes[1] != @backingInt(OutputItemKind.message)))) return error.CorruptOutputMetadata;
        return .{
            .tag = switch (bytes[0]) {
                1 => .item,
                3 => .usage,
                4 => .item_id,
                5 => .name,
                6 => .call_id,
                7 => .arguments,
                8 => .part,
                9 => .extras,
                10 => .member,
                else => return error.CorruptOutputMetadata,
            },
            .kind = switch (bytes[1]) {
                1 => .reasoning,
                2 => .message,
                3 => .function_call,
                4 => .compaction,
                else => return error.CorruptOutputMetadata,
            },
            .ordinal = if (bytes[0] == @backingInt(OutputRecordTag.usage)) 0 else std.mem.readInt(u64, bytes[8..16], .little),
            .start = std.mem.readInt(u64, bytes[16..24], .little),
            .length = std.mem.readInt(u64, bytes[24..32], .little),
            .decoded_length = std.mem.readInt(u64, bytes[32..40], .little),
            .id_digest = bytes[40..72].*,
            .content_digest = bytes[72..104].*,
            .usage_tokens = if (bytes[2] == 1) std.mem.readInt(u64, bytes[8..16], .little) else null,
            .omit_reasoning_text = bytes[3] == 1,
            .part_kind = @fromBackingInt(@intCast(bytes[4])),
            .scope = @fromBackingInt(@intCast(bytes[5])),
            .part_array = @fromBackingInt(@intCast(bytes[6])),
            .phase = @fromBackingInt(@intCast(bytes[7])),
        };
    }

    pub fn nextItem(self: *OutputMetadataReader) !?OutputMetadataRecord {
        while (try self.next()) |record| if (record.tag == .item) return record;
        return null;
    }
};

/// Decode one scalar from an already-delimited JSON string. The byte source
/// owns bounds and storage; this function retains at most one UTF-8 scalar.
pub fn decodeScalar(source: anytype, encoded: *[4]u8) !usize {
    const byte = try source.take();
    if (byte != '\\') {
        encoded[0] = byte;
        return 1;
    }
    const escape = try source.take();
    encoded[0] = switch (escape) {
        '"', '\\', '/' => escape,
        'b' => 8,
        'f' => 12,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'u' => {
            var scalar = try readHexScalar(source);
            if (scalar >= 0xd800 and scalar <= 0xdbff) {
                if (try source.take() != '\\' or try source.take() != 'u') return error.InvalidJsonSurrogate;
                const low = try readHexScalar(source);
                if (low < 0xdc00 or low > 0xdfff) return error.InvalidJsonSurrogate;
                scalar = 0x10000 + ((scalar - 0xd800) << 10) + (low - 0xdc00);
            } else if (scalar >= 0xdc00 and scalar <= 0xdfff) return error.InvalidJsonSurrogate;
            return try std.unicode.utf8Encode(scalar, encoded);
        },
        else => return error.InvalidJsonEscape,
    };
    return 1;
}

pub fn readHexScalar(source: anytype) !u21 {
    var value: u21 = 0;
    for (0..4) |_| {
        const byte = try source.take();
        const digit = std.fmt.charToDigit(byte, 16) catch return error.InvalidJsonEscape;
        value = value * 16 + digit;
    }
    return value;
}

/// Streams a value's decoded bytes through a whole content window.
pub const EncodedStringReader = EncodedStringWindow(protocol.content_window_bytes);

/// Reads a call name, which the Host only compares with a catalog name or
/// quotes as a 32-byte prefix, so a short window serves it.
pub const NameReader = EncodedStringWindow(64);

/// Bounded decoded view of a certified JSON string range, excluding quotes,
/// read through a `window_bytes` window. Declared with a literal of its
/// range (`.position = record.start, .end = try record.end()`), so the
/// window stays unwritten until a read fills it.
pub fn EncodedStringWindow(comptime window_bytes: usize) type {
    return struct {
        const Self = @This();

        io: std.Io,
        file: std.Io.File,
        position: u64,
        end: u64,
        buffer_start: u64 = 0,
        buffer_length: usize = 0,
        buffer: [window_bytes]u8 = undefined,
        pending: [4]u8 = undefined,
        pending_start: u3 = 0,
        pending_end: u3 = 0,

        pub fn take(self: *Self) !u8 {
            if (self.position == self.end) return error.InvalidEncodedString;
            if (self.position < self.buffer_start or self.position >= self.buffer_start + self.buffer_length) {
                self.buffer_start = self.position;
                const wanted: usize = @intCast(@min(self.end - self.position, self.buffer.len));
                const count = try self.file.readPositionalAll(self.io, self.buffer[0..wanted], self.position);
                if (count != wanted) return error.ShortOutputRead;
                self.buffer_length = count;
            }
            const byte = self.buffer[@intCast(self.position - self.buffer_start)];
            self.position += 1;
            if (byte < 0x20) return error.InvalidEncodedString;
            return byte;
        }

        pub fn next(self: *Self) !?u8 {
            if (self.pending_start == self.pending_end) {
                if (self.position == self.end) return null;
                self.pending_end = @intCast(try decodeScalar(self, &self.pending));
                self.pending_start = 0;
            }
            const byte = self.pending[self.pending_start];
            self.pending_start += 1;
            return byte;
        }
    };
}

pub const JsonStringSource = struct {
    encoded: EncodedStringReader,
    lookahead: ?u8 = null,
    has_lookahead: bool = false,

    pub fn peek(self: *JsonStringSource) !?u8 {
        if (!self.has_lookahead) {
            self.lookahead = try self.encoded.next();
            self.has_lookahead = true;
        }
        return self.lookahead;
    }

    pub fn take(self: *JsonStringSource) !u8 {
        const byte = try self.peek() orelse return error.InvalidDescriptorJson;
        self.has_lookahead = false;
        return byte;
    }
};

test "a metadata record's replay-rule byte is set only on a reasoning item record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (0..256) |flag| for ([_]OutputRecordTag{ .item, .member, .item_id }) |tag| for ([_]OutputItemKind{ .reasoning, .message, .function_call, .compaction }) |kind| {
        var bytes: [output_metadata_record_bytes]u8 = @splat(0);
        bytes[0] = @backingInt(tag);
        bytes[1] = @backingInt(kind);
        bytes[3] = @intCast(flag);
        const file = try tmp.dir.createFile(std.testing.io, "record", .{ .read = true, .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, &bytes);
        var reader = try OutputMetadataReader.init(std.testing.io, file, 1);
        const valid = flag == 0 or (flag == 1 and tag == .item and kind == .reasoning);
        if (reader.next()) |record| {
            try std.testing.expect(valid);
            try std.testing.expectEqual(flag == 1, record.?.omit_reasoning_text);
        } else |err| {
            try std.testing.expect(!valid);
            try std.testing.expectEqual(error.CorruptOutputMetadata, err);
        }
    };
}
