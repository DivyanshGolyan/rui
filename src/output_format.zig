//! Shared output projections and scratch metadata codec. No Store or provider parser.
const std = @import("std");
const named_scratch = @import("named_scratch.zig");
const protocol = @import("protocol.zig");

pub const ModelOperationKind = enum { assistant_response, compaction };
pub const OutputItemKind = enum(u8) { reasoning = 1, message = 2, function_call = 3, compaction = 4 };
pub const OutputRecordTag = enum(u8) {
    item = 1,
    text = 2,
    usage = 3,
    item_id = 4,
    name = 5,
    call_id = 6,
    arguments = 7,
};

pub const OutputMetadataRecord = struct {
    tag: OutputRecordTag,
    kind: OutputItemKind = .reasoning,
    ordinal: u64 = 0,
    start: u64,
    length: u64,
    decoded_length: u64 = 0,
    id_digest: [32]u8 = @splat(0),
    content_digest: [32]u8 = @splat(0),
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
        std.mem.writeInt(u64, bytes[8..16], record.ordinal, .little);
        std.mem.writeInt(u64, bytes[16..24], record.start, .little);
        std.mem.writeInt(u64, bytes[24..32], record.length, .little);
        std.mem.writeInt(u64, bytes[32..40], record.decoded_length, .little);
        @memcpy(bytes[40..72], &record.id_digest);
        @memcpy(bytes[72..104], &record.content_digest);
        try self.file.writeStreamingAll(self.io, &bytes);
        self.records += 1;
        if (record.tag == .text) {
            self.decoded_length = try std.math.add(u64, self.decoded_length, record.decoded_length);
        }
    }

    pub fn sealForRead(self: *OutputMetadataWriter) !void {
        if (self.sealed) return;
        try self.file.sync(self.io);
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
        return .{
            .tag = switch (bytes[0]) {
                1 => .item,
                2 => .text,
                3 => .usage,
                4 => .item_id,
                5 => .name,
                6 => .call_id,
                7 => .arguments,
                else => return error.CorruptOutputMetadata,
            },
            .kind = switch (bytes[1]) {
                1 => .reasoning,
                2 => .message,
                3 => .function_call,
                4 => .compaction,
                else => return error.CorruptOutputMetadata,
            },
            .ordinal = std.mem.readInt(u64, bytes[8..16], .little),
            .start = std.mem.readInt(u64, bytes[16..24], .little),
            .length = std.mem.readInt(u64, bytes[24..32], .little),
            .decoded_length = std.mem.readInt(u64, bytes[32..40], .little),
            .id_digest = bytes[40..72].*,
            .content_digest = bytes[72..104].*,
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
