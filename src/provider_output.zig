const std = @import("std");
const named_scratch = @import("named_scratch.zig");
const protocol = @import("protocol.zig");
const store = @import("store.zig");

pub const max_evidence_bytes = 256;

pub const Faults = struct {
    metadata: bool = false,
};

pub const Evidence = struct {
    response_id: protocol.Bounded(max_evidence_bytes) = .{},
    served_model: protocol.Bounded(protocol.max_model_bytes) = .{},
};

pub const Validated = struct {
    item_count: u64,
    call_count: u64,
    answer_length: u64,
    answer_digest: [32]u8,
    evidence: Evidence,
};

const Range = struct { start: u64, length: u64 };

const FileSource = struct {
    io: std.Io,
    file: std.Io.File,
    start: u64,
    end: u64,
    position: u64,
    buffer_start: u64 = 0,
    buffer_length: usize = 0,
    buffer: [protocol.content_window_bytes]u8 = undefined,

    fn init(io: std.Io, file: std.Io.File, range: Range) !FileSource {
        const end = try std.math.add(u64, range.start, range.length);
        return .{ .io = io, .file = file, .start = range.start, .end = end, .position = range.start };
    }

    fn offset(self: *const FileSource) u64 {
        return self.position;
    }

    fn peek(self: *FileSource) !?u8 {
        if (self.position == self.end) return null;
        if (self.position < self.buffer_start or self.position >= self.buffer_start + self.buffer_length) {
            self.buffer_start = self.position;
            const wanted: usize = @intCast(@min(self.end - self.position, self.buffer.len));
            const count = try self.file.readPositionalAll(self.io, self.buffer[0..wanted], self.position);
            if (count != wanted) return error.ShortSealedRead;
            self.buffer_length = count;
        }
        return self.buffer[@intCast(self.position - self.buffer_start)];
    }

    fn take(self: *FileSource) !u8 {
        const byte = try self.peek() orelse return error.UnexpectedJsonEnd;
        self.position += 1;
        return byte;
    }

    fn expectEnd(self: *FileSource) !void {
        try self.space();
        if (try self.peek() != null) return error.TrailingJson;
    }

    fn space(self: *FileSource) !void {
        while (try self.peek()) |byte| switch (byte) {
            ' ', '\t', '\r', '\n' => _ = try self.take(),
            else => return,
        };
    }

    fn expect(self: *FileSource, expected: u8) !void {
        try self.space();
        if (try self.take() != expected) return error.UnexpectedJsonDelimiter;
    }
};

const Utf8Validator = struct {
    bytes: [4]u8 = undefined,
    used: u3 = 0,
    expected: u3 = 0,

    fn feed(self: *Utf8Validator, byte: u8) !void {
        if (self.used == 0) {
            if (byte < 0x80) return;
            self.expected = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidJsonUtf8;
        }
        self.bytes[self.used] = byte;
        self.used += 1;
        if (self.used == self.expected) {
            _ = std.unicode.utf8Decode(self.bytes[0..self.expected]) catch return error.InvalidJsonUtf8;
            self.used = 0;
            self.expected = 0;
        }
    }

    fn finish(self: *const Utf8Validator) !void {
        if (self.used != 0) return error.InvalidJsonUtf8;
    }
};

const Decoded = struct {
    bounded: ?*protocol.Bounded(max_evidence_bytes) = null,
    hash: ?*std.crypto.hash.sha2.Sha256 = null,
    length: u64 = 0,
    overflow: bool = false,

    fn emit(self: *Decoded, bytes: []const u8) !void {
        self.length = try std.math.add(u64, self.length, bytes.len);
        if (self.hash) |hash| hash.update(bytes);
        if (self.bounded) |destination| {
            if (self.overflow or destination.len + bytes.len > destination.bytes.len) {
                self.overflow = true;
            } else {
                @memcpy(destination.bytes[destination.len .. destination.len + bytes.len], bytes);
                destination.len += bytes.len;
            }
        }
    }
};

const ParsedString = struct {
    encoded: Range,
    decoded_length: u64,
};

fn parseString(source: anytype, decoded: ?*Decoded) !ParsedString {
    try source.space();
    if (try source.take() != '"') return error.ExpectedJsonString;
    const start = source.offset();
    var validator: Utf8Validator = .{};
    var decoded_length: u64 = 0;
    while (true) {
        const byte = try source.take();
        if (byte == '"') {
            try validator.finish();
            return .{
                .encoded = .{ .start = start, .length = source.offset() - start - 1 },
                .decoded_length = decoded_length,
            };
        }
        if (byte < 0x20) return error.InvalidJsonString;
        if (byte != '\\') {
            try validator.feed(byte);
            if (decoded) |consumer| try consumer.emit(&.{byte});
            decoded_length = try std.math.add(u64, decoded_length, 1);
            continue;
        }
        try validator.finish();
        validator = .{};
        const escape = try source.take();
        const simple: ?u8 = switch (escape) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'b' => 8,
            'f' => 12,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => null,
            else => return error.InvalidJsonEscape,
        };
        if (simple) |value| {
            if (decoded) |consumer| try consumer.emit(&.{value});
            decoded_length = try std.math.add(u64, decoded_length, 1);
            continue;
        }
        var scalar = try readHexScalar(source);
        if (scalar >= 0xd800 and scalar <= 0xdbff) {
            if (try source.take() != '\\' or try source.take() != 'u') return error.InvalidJsonSurrogate;
            const low = try readHexScalar(source);
            if (low < 0xdc00 or low > 0xdfff) return error.InvalidJsonSurrogate;
            scalar = 0x10000 + ((scalar - 0xd800) << 10) + (low - 0xdc00);
        } else if (scalar >= 0xdc00 and scalar <= 0xdfff) return error.InvalidJsonSurrogate;
        var encoded: [4]u8 = undefined;
        const count = try std.unicode.utf8Encode(scalar, &encoded);
        if (decoded) |consumer| try consumer.emit(encoded[0..count]);
        decoded_length = try std.math.add(u64, decoded_length, count);
    }
}

fn readHexScalar(source: anytype) !u21 {
    var value: u21 = 0;
    for (0..4) |_| {
        const byte = try source.take();
        const digit: u8 = switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            'A'...'F' => byte - 'A' + 10,
            else => return error.InvalidJsonEscape,
        };
        value = value * 16 + digit;
    }
    return value;
}

fn skipValue(source: anytype, depth: usize) !void {
    if (depth > protocol.max_json_depth) return error.JsonTooDeep;
    try source.space();
    const first = try source.peek() orelse return error.UnexpectedJsonEnd;
    switch (first) {
        '"' => _ = try parseString(source, null),
        '{' => {
            _ = try source.take();
            try source.space();
            if (try source.peek() == '}') {
                _ = try source.take();
                return;
            }
            while (true) {
                _ = try parseString(source, null);
                try source.expect(':');
                try skipValue(source, depth + 1);
                try source.space();
                const delimiter = try source.take();
                if (delimiter == '}') break;
                if (delimiter != ',') return error.UnexpectedJsonDelimiter;
            }
        },
        '[' => {
            _ = try source.take();
            try source.space();
            if (try source.peek() == ']') {
                _ = try source.take();
                return;
            }
            while (true) {
                try skipValue(source, depth + 1);
                try source.space();
                const delimiter = try source.take();
                if (delimiter == ']') break;
                if (delimiter != ',') return error.UnexpectedJsonDelimiter;
            }
        },
        't' => try literal(source, "true"),
        'f' => try literal(source, "false"),
        'n' => try literal(source, "null"),
        '-', '0'...'9' => try number(source),
        else => return error.InvalidJsonValue,
    }
}

fn literal(source: anytype, expected: []const u8) !void {
    for (expected) |byte| if (try source.take() != byte) return error.InvalidJsonLiteral;
}

fn number(source: anytype) !void {
    if (try source.peek() == '-') _ = try source.take();
    const first = try source.take();
    if (first == '0') {
        if (try source.peek()) |next| if (next >= '0' and next <= '9') return error.InvalidJsonNumber;
    } else if (first >= '1' and first <= '9') {
        while (try source.peek()) |next| if (next >= '0' and next <= '9') {
            _ = try source.take();
        } else break;
    } else return error.InvalidJsonNumber;
    if (try source.peek() == '.') {
        _ = try source.take();
        const digit = try source.take();
        if (digit < '0' or digit > '9') return error.InvalidJsonNumber;
        while (try source.peek()) |next| if (next >= '0' and next <= '9') {
            _ = try source.take();
        } else break;
    }
    if (try source.peek()) |next| if (next == 'e' or next == 'E') {
        _ = try source.take();
        if (try source.peek()) |sign| {
            if (sign == '+' or sign == '-') _ = try source.take();
        }
        const digit = try source.take();
        if (digit < '0' or digit > '9') return error.InvalidJsonNumber;
        while (try source.peek()) |rest| if (rest >= '0' and rest <= '9') {
            _ = try source.take();
        } else break;
    };
}

fn keyName(source: anytype, destination: *protocol.Bounded(max_evidence_bytes)) !void {
    destination.len = 0;
    var decoded = Decoded{ .bounded = destination };
    _ = try parseString(source, &decoded);
    if (decoded.overflow) destination.len = 0;
}

// Ranges borrow the sealed source. Fixed slots depend on the consumer's field
// names, never on provider object size. Unknown fields still receive full syntax
// validation. Defer duplicate errors until lookup so unused fields stay open.
fn Fields(comptime names: []const []const u8) type {
    return struct {
        values: [names.len]?Range = @splat(null),
        duplicates: [names.len]bool = @splat(false),

        fn get(self: @This(), comptime name: []const u8) !?Range {
            inline for (names, 0..) |candidate, index| {
                if (comptime std.mem.eql(u8, candidate, name)) {
                    if (self.duplicates[index]) return error.DuplicateJsonField;
                    return self.values[index];
                }
            }
            @compileError("uncollected provider field: " ++ name);
        }

        fn required(self: @This(), comptime name: []const u8) !Range {
            return try self.get(name) orelse error.MissingProviderField;
        }
    };
}

fn collectFields(source: *FileSource, comptime names: []const []const u8) !Fields(names) {
    var fields: Fields(names) = .{};
    try source.expect('{');
    try source.space();
    if (try source.peek() == '}') {
        _ = try source.take();
        try source.expectEnd();
        return fields;
    }
    while (true) {
        var key: protocol.Bounded(max_evidence_bytes) = .{};
        try keyName(source, &key);
        try source.expect(':');
        try source.space();
        const start = source.offset();
        try skipValue(source, 1);
        const value = Range{ .start = start, .length = source.offset() - start };
        inline for (names, 0..) |name, index| {
            if (key.eql(name)) {
                fields.duplicates[index] = fields.values[index] != null;
                fields.values[index] = value;
            }
        }
        try source.space();
        const delimiter = try source.take();
        if (delimiter == '}') break;
        if (delimiter != ',') return error.UnexpectedJsonDelimiter;
    }
    try source.expectEnd();
    return fields;
}

fn readFields(io: std.Io, file: std.Io.File, object: Range, comptime names: []const []const u8) !Fields(names) {
    var source = try FileSource.init(io, file, object);
    return collectFields(&source, names);
}

fn readString(io: std.Io, file: std.Io.File, value: Range, destination: *protocol.Bounded(max_evidence_bytes)) !ParsedString {
    destination.len = 0;
    var decoded = Decoded{ .bounded = destination };
    var source = try FileSource.init(io, file, value);
    const parsed = try parseString(&source, &decoded);
    try source.expectEnd();
    if (decoded.overflow) return error.ProviderValueTooLong;
    return parsed;
}

fn stringDigest(io: std.Io, file: std.Io.File, value: Range) ![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var decoded = Decoded{ .hash = &hash };
    var source = try FileSource.init(io, file, value);
    const parsed = try parseString(&source, &decoded);
    try source.expectEnd();
    if (parsed.decoded_length == 0) return error.EmptyProviderIdentity;
    return hash.finalResult();
}

fn readIndex(io: std.Io, file: std.Io.File, value: Range) !u64 {
    var source = try FileSource.init(io, file, value);
    try source.space();
    var result: u64 = 0;
    var digits: usize = 0;
    while (try source.peek()) |byte| {
        if (byte < '0' or byte > '9') break;
        _ = try source.take();
        result = try std.math.add(u64, try std.math.mul(u64, result, 10), byte - '0');
        digits += 1;
    }
    if (digits == 0) return error.InvalidProviderIndex;
    try source.expectEnd();
    return result;
}

const Array = struct {
    source: FileSource,
    done: bool = false,
    first: bool = true,

    fn init(io: std.Io, file: std.Io.File, range: Range) !Array {
        var source = try FileSource.init(io, file, range);
        try source.expect('[');
        return .{ .source = source };
    }

    fn next(self: *Array) !?Range {
        if (self.done) return null;
        try self.source.space();
        if (try self.source.peek() == ']') {
            _ = try self.source.take();
            try self.source.expectEnd();
            self.done = true;
            return null;
        }
        if (!self.first) try self.source.expect(',');
        try self.source.space();
        const start = self.source.offset();
        try skipValue(&self.source, 1);
        self.first = false;
        return .{ .start = start, .length = self.source.offset() - start };
    }
};

fn optionalCompleted(io: std.Io, file: std.Io.File, status_range: ?Range) !void {
    const status = status_range orelse return;
    var value: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, status, &value);
    if (!value.eql("completed")) return error.UnsupportedProviderOutput;
}

fn optionalFalse(io: std.Io, file: std.Io.File, value_range: ?Range) !void {
    const value = value_range orelse return;
    var source = try FileSource.init(io, file, value);
    try source.space();
    if (try source.peek() == 'n') {
        try literal(&source, "null");
    } else if (try source.peek() == 't') {
        try literal(&source, "true");
        try source.expectEnd();
        return error.UnsupportedProviderOutput;
    } else {
        try literal(&source, "false");
    }
    try source.expectEnd();
}

fn optionalEmptyString(io: std.Io, file: std.Io.File, value_range: ?Range) !void {
    const value = value_range orelse return;
    var source = try FileSource.init(io, file, value);
    try source.space();
    if (try source.peek() == 'n') {
        try literal(&source, "null");
        try source.expectEnd();
        return;
    }
    const parsed = try parseString(&source, null);
    try source.expectEnd();
    if (parsed.decoded_length != 0) return error.UnsupportedProviderOutput;
}

fn validateCaller(io: std.Io, file: std.Io.File, caller_range: ?Range) !void {
    const caller = caller_range orelse return;
    var source = try FileSource.init(io, file, caller);
    try source.space();
    if (try source.peek() == 'n') {
        try literal(&source, "null");
        try source.expectEnd();
        return;
    }
    const fields = try collectFields(&source, &.{"type"});
    const type_range = try fields.get("type") orelse return error.UnsupportedProviderOutput;
    var caller_type: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, type_range, &caller_type);
    if (!caller_type.eql("direct")) return error.UnsupportedProviderOutput;
}

fn validateFunctionCallControls(io: std.Io, file: std.Io.File, fields: ItemFields) !void {
    try validateCaller(io, file, try fields.get("caller"));
    try optionalFalse(io, file, try fields.get("async"));
    try optionalEmptyString(io, file, try fields.get("namespace"));
    try optionalEmptyString(io, file, try fields.get("encrypted_function_args"));
}

fn validateMetadataAuthority(io: std.Io, file: std.Io.File, metadata_range: ?Range) !void {
    const metadata = metadata_range orelse return;
    const fields = try readFields(io, file, metadata, &.{ "cell_id", "executed_tool_calls", "tool_calls_complete" });
    inline for (.{ "cell_id", "executed_tool_calls", "tool_calls_complete" }) |field| {
        if (try fields.get(field) != null) return error.UnsupportedProviderOutput;
    }
}

const item_field_names = &.{ "type", "id", "status", "role", "phase", "internal_chat_message_metadata_passthrough", "content", "text", "encrypted_content", "summary", "name", "call_id", "arguments", "caller", "async", "namespace", "encrypted_function_args" };
const ItemFields = Fields(item_field_names);

fn validateReasoning(io: std.Io, file: std.Io.File, fields: ItemFields) !void {
    try optionalCompleted(io, file, try fields.get("status"));
    if (try fields.get("text") != null) return error.UnsupportedProviderOutput;
    const encrypted = (try fields.get("encrypted_content")) orelse return error.ContinuationUnavailable;
    var ignored: protocol.Bounded(max_evidence_bytes) = .{};
    const parsed = readString(io, file, encrypted, &ignored) catch |err| switch (err) {
        error.ProviderValueTooLong => blk: {
            var source = try FileSource.init(io, file, encrypted);
            break :blk try parseString(&source, null);
        },
        else => return err,
    };
    if (parsed.decoded_length == 0) return error.ContinuationUnavailable;
    const field_names = [_][]const u8{ "summary", "content" };
    const type_names = [_][]const u8{ "summary_text", "reasoning_text" };
    inline for (field_names, type_names) |field_name, type_name| {
        if (try fields.get(field_name)) |array_range| {
            var array = try Array.init(io, file, array_range);
            while (try array.next()) |block| {
                const block_fields = try readFields(io, file, block, &.{ "type", "text", "annotations" });
                var kind: protocol.Bounded(max_evidence_bytes) = .{};
                _ = try readString(io, file, try block_fields.required("type"), &kind);
                if (!kind.eql(type_name)) return error.UnsupportedProviderOutput;
                var text: protocol.Bounded(max_evidence_bytes) = .{};
                _ = readString(io, file, try block_fields.required("text"), &text) catch |err| switch (err) {
                    error.ProviderValueTooLong => {},
                    else => return err,
                };
            }
        }
    }
    try validateMetadataAuthority(io, file, try fields.get("internal_chat_message_metadata_passthrough"));
}

fn validateAnnotations(io: std.Io, file: std.Io.File, annotations_range: ?Range) !void {
    const annotations = annotations_range orelse return;
    var array = try Array.init(io, file, annotations);
    while (try array.next()) |annotation| {
        const fields = try readFields(io, file, annotation, &.{"type"});
        var kind: protocol.Bounded(max_evidence_bytes) = .{};
        _ = try readString(io, file, try fields.required("type"), &kind);
        if (!kind.eql("url_citation")) return error.UnsupportedProviderOutput;
    }
}

const ItemValidation = struct {
    kind: store.OutputItemKind,
    id_digest: [32]u8,
    text_records: u64 = 0,
};

fn validateItem(
    io: std.Io,
    file: std.Io.File,
    item: Range,
    ordinal: u64,
    metadata: *store.OutputMetadataWriter,
    answer_hash: *std.crypto.hash.sha2.Sha256,
) !ItemValidation {
    const fields = try readFields(io, file, item, item_field_names);
    var kind_name: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, try fields.required("type"), &kind_name);
    const id_digest = try stringDigest(io, file, try fields.required("id"));
    if (kind_name.eql("reasoning")) {
        try validateReasoning(io, file, fields);
        return .{ .kind = .reasoning, .id_digest = id_digest };
    }
    if (kind_name.eql("function_call")) {
        try optionalCompleted(io, file, try fields.get("status"));
        try validateFunctionCallControls(io, file, fields);
        inline for (.{
            .{ "id", store.OutputRecordTag.item_id, true },
            .{ "name", store.OutputRecordTag.name, true },
            .{ "call_id", store.OutputRecordTag.call_id, true },
            .{ "arguments", store.OutputRecordTag.arguments, false },
        }) |descriptor| {
            var hash = protocol.contentHasher();
            var decoded = Decoded{ .hash = &hash };
            var source = try FileSource.init(io, file, try fields.required(descriptor[0]));
            const value = try parseString(&source, &decoded);
            try source.expectEnd();
            if (descriptor[2] and value.decoded_length == 0) return error.EmptyProviderIdentity;
            const digest = hash.finalResult();
            try metadata.append(.{
                .tag = descriptor[1],
                .kind = .function_call,
                .ordinal = ordinal,
                .start = value.encoded.start,
                .length = value.encoded.length,
                .decoded_length = value.decoded_length,
                .content_digest = digest,
            });
        }
        return .{ .kind = .function_call, .id_digest = id_digest };
    }
    if (!kind_name.eql("message")) return error.UnsupportedProviderOutput;
    try optionalCompleted(io, file, try fields.get("status"));
    var role: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, try fields.required("role"), &role);
    if (!role.eql("assistant")) return error.UnsupportedProviderOutput;
    if (try fields.get("phase")) |phase_range| {
        var phase: protocol.Bounded(max_evidence_bytes) = .{};
        _ = try readString(io, file, phase_range, &phase);
        if (!phase.eql("commentary") and !phase.eql("final_answer")) return error.UnsupportedProviderOutput;
    }
    try validateMetadataAuthority(io, file, try fields.get("internal_chat_message_metadata_passthrough"));
    const content = try fields.required("content");
    var array = try Array.init(io, file, content);
    var text_records: u64 = 0;
    while (try array.next()) |block| {
        const block_fields = try readFields(io, file, block, &.{ "type", "text", "annotations" });
        var block_kind: protocol.Bounded(max_evidence_bytes) = .{};
        _ = try readString(io, file, try block_fields.required("type"), &block_kind);
        if (!block_kind.eql("output_text")) return error.UnsupportedProviderOutput;
        try validateAnnotations(io, file, try block_fields.get("annotations"));
        const text_value = try block_fields.required("text");
        var source = try FileSource.init(io, file, text_value);
        var decoded = Decoded{ .hash = answer_hash };
        const text = try parseString(&source, &decoded);
        try source.expectEnd();
        try metadata.append(.{
            .tag = .text,
            .ordinal = ordinal,
            .start = text.encoded.start,
            .length = text.encoded.length,
            .decoded_length = text.decoded_length,
        });
        text_records += 1;
    }
    if (text_records == 0) return error.MalformedProviderOutput;
    return .{ .kind = .message, .id_digest = id_digest, .text_records = text_records };
}

const Added = struct {
    active: bool = false,
    index: u64 = 0,
    kind: store.OutputItemKind = .reasoning,
    id_digest: [32]u8 = [_]u8{0} ** 32,
};

fn itemIdentity(io: std.Io, file: std.Io.File, item: Range) !struct {
    kind: store.OutputItemKind,
    id_digest: [32]u8,
    content_digest: [32]u8,
} {
    const fields = try readFields(io, file, item, &.{ "type", "id" });
    var kind_name: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, try fields.required("type"), &kind_name);
    const kind: store.OutputItemKind = if (kind_name.eql("reasoning"))
        .reasoning
    else if (kind_name.eql("message"))
        .message
    else if (kind_name.eql("function_call"))
        .function_call
    else
        return error.UnsupportedProviderOutput;
    return .{
        .kind = kind,
        .id_digest = try stringDigest(io, file, try fields.required("id")),
        .content_digest = try contentDigestRange(io, file, item),
    };
}

fn validateCompleted(
    io: std.Io,
    file: std.Io.File,
    response: Range,
    metadata: *store.OutputMetadataWriter,
    expected_items: u64,
    evidence: *Evidence,
) !void {
    const fields = try readFields(io, file, response, &.{ "status", "id", "model", "output", "usage" });
    var status: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, try fields.required("status"), &status);
    if (!status.eql("completed")) return error.UnsupportedProviderOutput;
    _ = try readString(io, file, try fields.required("id"), &evidence.response_id);
    if (evidence.response_id.len == 0) return error.EmptyProviderIdentity;
    if (try fields.get("model")) |model| {
        var wide: protocol.Bounded(max_evidence_bytes) = .{};
        _ = try readString(io, file, model, &wide);
        if (wide.len == 0) return error.EmptyProviderIdentity;
        try evidence.served_model.set(wide.slice());
    }
    const output = try fields.required("output");
    var array = try Array.init(io, file, output);
    var reader = try store.OutputMetadataReader.init(io, metadata.file, expected_items);
    var index: u64 = 0;
    while (try array.next()) |terminal_item| {
        const identity = try itemIdentity(io, file, terminal_item);
        const record = try reader.nextItem() orelse return error.ContradictoryProviderOutput;
        if (record.ordinal != index or record.kind != identity.kind or
            !std.mem.eql(u8, &record.id_digest, &identity.id_digest) or
            !std.mem.eql(u8, &record.content_digest, &identity.content_digest)) return error.ContradictoryProviderOutput;
        index += 1;
    }
    if (index != expected_items or try reader.nextItem() != null) return error.ContradictoryProviderOutput;
    if (try fields.get("usage")) |usage| {
        const usage_fields = try readFields(io, file, usage, &.{"total_tokens"});
        _ = try usage_fields.get("total_tokens");
        try metadata.append(.{
            .tag = .usage,
            .start = usage.start,
            .length = usage.length,
            .content_digest = try contentDigestRange(io, file, usage),
        });
    }
}

fn knownNonterminal(kind: []const u8) bool {
    const values = [_][]const u8{
        "response.created",
        "response.in_progress",
        "response.output_text.delta",
        "response.output_text.done",
        "response.reasoning_summary_part.added",
        "response.reasoning_summary_part.done",
        "response.reasoning_summary_text.delta",
        "response.reasoning_summary_text.done",
        "response.reasoning_text.delta",
        "response.reasoning_text.done",
        "response.content_part.added",
        "response.content_part.done",
        "response.function_call_arguments.delta",
        "response.function_call_arguments.done",
    };
    for (values) |value| if (std.mem.eql(u8, kind, value)) return true;
    return false;
}

fn processEvent(
    io: std.Io,
    file: std.Io.File,
    event: Range,
    metadata: *store.OutputMetadataWriter,
    added: *Added,
    completed: *bool,
    item_count: *u64,
    message_count: *u64,
    call_count: *u64,
    saw_action: *bool,
    answer_length: *u64,
    answer_hash: *std.crypto.hash.sha2.Sha256,
    evidence: *Evidence,
) !void {
    if (completed.*) return error.LateProviderOutput;
    var kind: protocol.Bounded(max_evidence_bytes) = .{};
    const fields = try readFields(io, file, event, &.{ "type", "output_index", "item", "response" });
    _ = try readString(io, file, try fields.required("type"), &kind);
    if (kind.eql("response.output_item.added")) {
        if (added.active) return error.ContradictoryProviderOutput;
        const index = try readIndex(io, file, try fields.required("output_index"));
        if (index != item_count.*) return error.ContradictoryProviderOutput;
        const identity = try itemIdentity(io, file, try fields.required("item"));
        added.* = .{ .active = true, .index = index, .kind = identity.kind, .id_digest = identity.id_digest };
        return;
    }
    if (kind.eql("response.output_item.done")) {
        const index = try readIndex(io, file, try fields.required("output_index"));
        if (index != item_count.*) return error.ContradictoryProviderOutput;
        const item = try fields.required("item");
        const validation = try validateItem(io, file, item, index, metadata, answer_hash);
        if (added.active and (added.index != index or added.kind != validation.kind or
            !std.mem.eql(u8, &added.id_digest, &validation.id_digest))) return error.ContradictoryProviderOutput;
        added.active = false;
        if (validation.kind == .message) {
            if (saw_action.*) return error.UnsupportedProviderOutput;
            message_count.* += 1;
        }
        if (validation.kind == .function_call) {
            saw_action.* = true;
            call_count.* += 1;
        }
        answer_length.* = metadata.decoded_length;
        try metadata.append(.{
            .tag = .item,
            .kind = validation.kind,
            .ordinal = index,
            .start = item.start,
            .length = item.length,
            .id_digest = validation.id_digest,
            .content_digest = try contentDigestRange(io, file, item),
        });
        item_count.* += 1;
        return;
    }
    if (kind.eql("response.completed")) {
        if (added.active or item_count.* == 0 or message_count.* > 1 or
            (message_count.* == 0 and call_count.* == 0)) return error.IncompleteProviderOutput;
        try validateCompleted(io, file, try fields.required("response"), metadata, item_count.*, evidence);
        try metadata.sealForRead();
        completed.* = true;
        return;
    }
    if (kind.eql("error") or kind.eql("response.failed") or kind.eql("response.incomplete")) {
        return error.IncompleteProviderOutput;
    }
    if (!knownNonterminal(kind.slice())) return error.UnsupportedProviderOutput;
}

fn linePrefix(io: std.Io, file: std.Io.File, line: Range, prefix: []const u8) !bool {
    if (line.length < prefix.len) return false;
    var buffer: [32]u8 = undefined;
    std.debug.assert(prefix.len <= buffer.len);
    const count = try file.readPositionalAll(io, buffer[0..prefix.len], line.start);
    if (count != prefix.len) return error.ShortSealedRead;
    return std.mem.eql(u8, buffer[0..prefix.len], prefix);
}

fn rangeEquals(io: std.Io, file: std.Io.File, range: Range, expected: []const u8) !bool {
    if (range.length != expected.len) return false;
    var buffer: [32]u8 = undefined;
    if (expected.len > buffer.len) return false;
    const count = try file.readPositionalAll(io, buffer[0..expected.len], range.start);
    if (count != expected.len) return error.ShortSealedRead;
    return std.mem.eql(u8, buffer[0..expected.len], expected);
}

fn contentDigestRange(io: std.Io, file: std.Io.File, range: Range) ![32]u8 {
    var hash = protocol.contentHasher();
    var offset: u64 = 0;
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    while (offset < range.length) {
        const wanted: usize = @intCast(@min(range.length - offset, buffer.len));
        const count = try file.readPositionalAll(io, buffer[0..wanted], range.start + offset);
        if (count != wanted) return error.ShortSealedRead;
        hash.update(buffer[0..count]);
        offset += count;
    }
    return hash.finalResult();
}

pub fn validate(
    io: std.Io,
    source_file: std.Io.File,
    source_length: u64,
    metadata: *store.OutputMetadataWriter,
    faults: Faults,
) !Validated {
    if (faults.metadata) metadata.fail_writes = true;
    var source = try FileSource.init(io, source_file, .{ .start = 0, .length = source_length });
    var data: ?Range = null;
    var completed = false;
    var done_marker = false;
    var item_count: u64 = 0;
    var message_count: u64 = 0;
    var call_count: u64 = 0;
    var saw_action = false;
    var answer_length: u64 = 0;
    var answer_hash = protocol.contentHasher();
    var evidence: Evidence = .{};
    var added: Added = .{};
    while (source.offset() < source.end) {
        const line_start = source.offset();
        while (try source.peek()) |byte| {
            _ = try source.take();
            if (byte == '\n') break;
        }
        var line_end = source.offset();
        if (line_end > line_start) {
            var last: [1]u8 = undefined;
            _ = try source_file.readPositionalAll(io, &last, line_end - 1);
            if (last[0] == '\n') line_end -= 1;
            if (line_end > line_start) {
                _ = try source_file.readPositionalAll(io, &last, line_end - 1);
                if (last[0] == '\r') line_end -= 1;
            }
        }
        const line = Range{ .start = line_start, .length = line_end - line_start };
        if (line.length == 0) {
            if (data) |payload| {
                if (try rangeEquals(io, source_file, payload, "[DONE]")) {
                    if (!completed or done_marker) return error.ContradictoryProviderOutput;
                    done_marker = true;
                } else {
                    if (done_marker) return error.LateProviderOutput;
                    try processEvent(
                        io,
                        source_file,
                        payload,
                        metadata,
                        &added,
                        &completed,
                        &item_count,
                        &message_count,
                        &call_count,
                        &saw_action,
                        &answer_length,
                        &answer_hash,
                        &evidence,
                    );
                }
                data = null;
            }
            continue;
        }
        if (try linePrefix(io, source_file, line, "data:")) {
            if (data != null) return error.UnsupportedMultilineSseData;
            var start = line.start + "data:".len;
            var length = line.length - "data:".len;
            if (length != 0) {
                var first: [1]u8 = undefined;
                _ = try source_file.readPositionalAll(io, &first, start);
                if (first[0] == ' ') {
                    start += 1;
                    length -= 1;
                }
            }
            if (length == 0) return error.EmptySseData;
            data = .{ .start = start, .length = length };
        } else if (!try linePrefix(io, source_file, line, ":") and
            !try linePrefix(io, source_file, line, "event:") and
            !try linePrefix(io, source_file, line, "id:") and
            !try linePrefix(io, source_file, line, "retry:"))
        {
            return error.MalformedSse;
        }
    }
    if (data != null) return error.IncompleteSseEvent;
    if (!completed) return error.IncompleteProviderOutput;
    if (answer_length == 0 and call_count == 0) return error.EmptyProviderAnswer;
    return .{
        .item_count = item_count,
        .call_count = call_count,
        .answer_length = answer_length,
        .answer_digest = answer_hash.finalResult(),
        .evidence = evidence,
    };
}

pub fn failureCode(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedProviderOutput => "unsupported_provider_output",
        error.ContinuationUnavailable => "continuation_unavailable",
        error.MetadataScratchExhausted => "response_metadata_exhausted",
        error.InjectedMetadataFailure => "response_metadata_failed",
        else => "malformed_provider_output",
    };
}

const ContentSource = struct {
    reader: *store.HistoricalReader,
    position: u64 = 0,
    buffer_start: u64 = 0,
    buffer_length: usize = 0,
    buffer: [protocol.content_window_bytes]u8 = undefined,

    fn offset(self: *const ContentSource) u64 {
        return self.position;
    }

    fn peek(self: *ContentSource) !?u8 {
        if (self.position == self.reader.reference.length) return null;
        if (self.position < self.buffer_start or self.position >= self.buffer_start + self.buffer_length) {
            self.buffer_start = self.position;
            const wanted: usize = @intCast(@min(self.reader.reference.length - self.position, self.buffer.len));
            const count = try self.reader.read(self.position, self.buffer[0..wanted]);
            if (count != wanted) return error.ShortCanonicalRead;
            self.buffer_length = count;
        }
        return self.buffer[@intCast(self.position - self.buffer_start)];
    }

    fn take(self: *ContentSource) !u8 {
        const byte = try self.peek() orelse return error.UnexpectedJsonEnd;
        self.position += 1;
        return byte;
    }

    fn space(self: *ContentSource) !void {
        while (try self.peek()) |byte| switch (byte) {
            ' ', '\t', '\r', '\n' => _ = try self.take(),
            else => return,
        };
    }

    fn expect(self: *ContentSource, expected: u8) !void {
        try self.space();
        if (try self.take() != expected) return error.UnexpectedJsonDelimiter;
    }

    fn expectEnd(self: *ContentSource) !void {
        try self.space();
        if (try self.peek() != null) return error.TrailingJson;
    }
};

/// Rebuild one trusted canonical provider item without the one demonstrated
/// response-only top-level field. Unknown open fields and their raw spelling
/// are copied through bounded reads.
pub fn writeReplayItem(reader: *store.HistoricalReader, writer: anytype) !void {
    var source = ContentSource{ .reader = reader };
    try source.expect('{');
    try writer.write("{");
    var emitted = false;
    try source.space();
    if (try source.peek() != '}') {
        while (true) {
            try source.space();
            const field_start = source.offset();
            var key: protocol.Bounded(max_evidence_bytes) = .{};
            try keyName(&source, &key);
            try source.expect(':');
            try skipValue(&source, 1);
            const field_end = source.offset();
            if (!key.eql("created_by")) {
                if (emitted) try writer.write(",");
                try copyCanonicalRange(reader, field_start, field_end - field_start, writer);
                emitted = true;
            }
            try source.space();
            const delimiter = try source.take();
            if (delimiter == '}') break;
            if (delimiter != ',') return error.UnexpectedJsonDelimiter;
        }
    } else {
        _ = try source.take();
    }
    try source.expectEnd();
    try writer.write("}");
}

fn copyCanonicalRange(reader: *store.HistoricalReader, start: u64, length: u64, writer: anytype) !void {
    var offset: u64 = 0;
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    while (offset < length) {
        const wanted: usize = @intCast(@min(length - offset, buffer.len));
        const count = try reader.read(start + offset, buffer[0..wanted]);
        if (count != wanted) return error.ShortCanonicalRead;
        try writer.write(buffer[0..count]);
        offset += count;
    }
}

fn testingObject(tmp: *std.testing.TmpDir, bytes: []const u8) !FileSource {
    const file = try tmp.dir.createFile(std.testing.io, "object", .{ .read = true });
    errdefer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
    return FileSource.init(std.testing.io, file, .{ .start = 0, .length = bytes.len });
}

const TestingValidation = struct { output: Validated, metadata_bytes: u64 };

fn validateTestingSse(tmp: *std.testing.TmpDir, bytes: []const u8, metadata_limit: u64) !TestingValidation {
    const source = try tmp.dir.createFile(std.testing.io, "provider-sse", .{ .read = true });
    errdefer source.close(std.testing.io);
    try source.writeStreamingAll(std.testing.io, bytes);
    try source.sync(std.testing.io);
    var root: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root);
    var used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var metadata = try store.OutputMetadataWriter.init(
        std.testing.io,
        root[0..root_length],
        "provider-test-metadata",
        &used,
        metadata_limit,
        false,
        &retained,
    );
    errdefer metadata.deinit();
    const validated = try validate(std.testing.io, source, bytes.len, &metadata, .{});
    const metadata_bytes = used.load(.acquire);
    metadata.deinit();
    source.close(std.testing.io);
    return .{ .output = validated, .metadata_bytes = metadata_bytes };
}

test "provider preserves ordered trustworthy function call envelopes" {
    const first = "{\"type\":\"function_call\",\"id\":\"item-1\",\"status\":\"completed\",\"name\":\"bash\",\"call_id\":\"call\\nA\",\"arguments\":\"{\\\"cmd\\\":\\\"one\\\"}\"}";
    const second = "{\"type\":\"function_call\",\"id\":\"item-2\",\"status\":\"completed\",\"name\":\"bash\",\"call_id\":\"call-B\",\"arguments\":\"{\\\"cmd\\\":\\\"two\\\"}\"}";
    const valid = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ first ++ "}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ second ++ "}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"response-1\",\"status\":\"completed\",\"output\":[" ++ first ++ "," ++ second ++ "]}}\n\n";
    var valid_tmp = std.testing.tmpDir(.{});
    defer valid_tmp.cleanup();
    const accepted = try validateTestingSse(&valid_tmp, valid, 64 * 1024);
    try std.testing.expectEqual(@as(u64, 2), accepted.output.item_count);
    try std.testing.expectEqual(@as(u64, 2), accepted.output.call_count);
    try std.testing.expectEqual(@as(u64, 0), accepted.output.answer_length);
    try std.testing.expectEqual(@as(u64, 2 * 5 * 104), accepted.metadata_bytes);

    const invalid_second = "{\"type\":\"function_call\",\"id\":\"item-2\",\"status\":\"completed\",\"name\":\"edit\",\"call_id\":\"call-B\",\"arguments\":\"{}\"}";
    const late_invalid = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ first ++ "}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ invalid_second ++ "}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"response-2\",\"status\":\"completed\",\"output\":[" ++ first ++ "," ++ invalid_second ++ "]}}\n\n";
    var invalid_tmp = std.testing.tmpDir(.{});
    defer invalid_tmp.cleanup();
    const mixed = try validateTestingSse(&invalid_tmp, late_invalid, 64 * 1024);
    try std.testing.expectEqual(@as(u64, 2), mixed.output.call_count);

    const message = "{\"type\":\"message\",\"id\":\"message-1\",\"status\":\"completed\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"late\",\"annotations\":[]}]}";
    const late_message = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ first ++ "}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ message ++ "}\n\n";
    var order_tmp = std.testing.tmpDir(.{});
    defer order_tmp.cleanup();
    try std.testing.expectError(error.UnsupportedProviderOutput, validateTestingSse(&order_tmp, late_message, 64 * 1024));
}

test "function call argument stream events are scratch and completed items remain authority" {
    const complete = "{\"type\":\"function_call\",\"id\":\"item-1\",\"status\":\"completed\",\"name\":\"bash\",\"call_id\":\"call-1\",\"arguments\":\"{\\\"cmd\\\":\\\"echo ok\\\"}\"}";
    const stream = "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"item-1\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"item-1\",\"delta\":\"ignored\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"item-1\",\"arguments\":\"ignored\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ complete ++ "}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"response-1\",\"status\":\"completed\",\"output\":[" ++ complete ++ "]}}\n\n";
    var valid_tmp = std.testing.tmpDir(.{});
    defer valid_tmp.cleanup();
    const accepted = try validateTestingSse(&valid_tmp, stream, 64 * 1024);
    try std.testing.expectEqual(@as(u64, 1), accepted.output.call_count);
    try std.testing.expectEqual(@as(u64, 5 * 104), accepted.metadata_bytes);

    const malformed = "{\"type\":\"function_call\",\"id\":\"item-1\",\"name\":\"bash\",\"call_id\":\"call-1\"}";
    const malformed_stream = "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{}\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"arguments\":\"{}\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ malformed ++ "}\n\n";
    var malformed_tmp = std.testing.tmpDir(.{});
    defer malformed_tmp.cleanup();
    try std.testing.expectError(error.MissingProviderField, validateTestingSse(&malformed_tmp, malformed_stream, 64 * 1024));
}

test "provider rejects unsupported consequential function call controls" {
    const supported = "{\"type\":\"function_call\",\"id\":\"item-1\",\"status\":\"completed\",\"name\":\"bash\",\"call_id\":\"call-1\",\"arguments\":\"{}\",\"caller\":{\"type\":\"direct\",\"future\":1},\"async\":false,\"namespace\":\"\",\"encrypted_function_args\":null}";
    const cases = .{
        .{ supported, false },
        .{ "{\"type\":\"function_call\",\"id\":\"item-1\",\"name\":\"bash\",\"call_id\":\"call-1\",\"arguments\":\"{}\",\"caller\":{\"type\":\"program\"}}", true },
        .{ "{\"type\":\"function_call\",\"id\":\"item-1\",\"name\":\"bash\",\"call_id\":\"call-1\",\"arguments\":\"{}\",\"caller\":{}}", true },
        .{ "{\"type\":\"function_call\",\"id\":\"item-1\",\"name\":\"bash\",\"call_id\":\"call-1\",\"arguments\":\"{}\",\"async\":true}", true },
        .{ "{\"type\":\"function_call\",\"id\":\"item-1\",\"name\":\"bash\",\"call_id\":\"call-1\",\"arguments\":\"{}\",\"namespace\":\"remote\"}", true },
        .{ "{\"type\":\"function_call\",\"id\":\"item-1\",\"name\":\"bash\",\"call_id\":\"call-1\",\"arguments\":\"{}\",\"encrypted_function_args\":\"opaque\"}", true },
    };
    inline for (cases) |case| {
        const sse = try std.fmt.allocPrint(
            std.testing.allocator,
            "data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n" ++
                "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"response-1\",\"status\":\"completed\",\"output\":[{s}]}}}}\n\n",
            .{ case[0], case[0] },
        );
        defer std.testing.allocator.free(sse);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        if (case[1]) {
            try std.testing.expectError(error.UnsupportedProviderOutput, validateTestingSse(&tmp, sse, 64 * 1024));
        } else {
            const accepted = try validateTestingSse(&tmp, sse, 64 * 1024);
            try std.testing.expectEqual(@as(u64, 1), accepted.output.call_count);
        }
    }
}

test "Bash proposal metadata growth is linear and disk-backed" {
    const action_count = 1_000;
    var bytes: [1024 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var item_buffer: [256]u8 = undefined;
    for (0..action_count) |index| {
        const item = try std.fmt.bufPrint(
            &item_buffer,
            "{{\"type\":\"function_call\",\"id\":\"item-{d}\",\"status\":\"completed\",\"name\":\"bash\",\"call_id\":\"call-{d}\",\"arguments\":\"{{}}\"}}",
            .{ index, index },
        );
        var event_buffer: [512]u8 = undefined;
        try writer.writeAll(try std.fmt.bufPrint(
            &event_buffer,
            "data: {{\"type\":\"response.output_item.done\",\"output_index\":{d},\"item\":{s}}}\n\n",
            .{ index, item },
        ));
    }
    try writer.writeAll("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"growth\",\"status\":\"completed\",\"output\":[");
    for (0..action_count) |index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll(try std.fmt.bufPrint(
            &item_buffer,
            "{{\"type\":\"function_call\",\"id\":\"item-{d}\",\"status\":\"completed\",\"name\":\"bash\",\"call_id\":\"call-{d}\",\"arguments\":\"{{}}\"}}",
            .{ index, index },
        ));
    }
    try writer.writeAll("]}}\n\n");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const validated = try validateTestingSse(
        &tmp,
        writer.buffered(),
        action_count * 5 * 104,
    );
    try std.testing.expectEqual(@as(u64, action_count), validated.output.call_count);
    try std.testing.expectEqual(@as(u64, action_count * 5 * 104), validated.metadata_bytes);
    try std.testing.expect(@sizeOf(Validated) < protocol.content_window_bytes);
}

test "provider field collection traverses large open values once for all lookups" {
    const input = "{\"unknown\":\"" ++ "x" ** (protocol.content_window_bytes * 4) ++
        "\",\"type\":\"message\",\"id\":\"m1\",\"status\":\"completed\",\"role\":\"assistant\"," ++
        "\"phase\":\"final_answer\",\"content\":[],\"internal_chat_message_metadata_passthrough\":{}}";
    const names = &.{ "type", "id", "status", "role", "phase", "content", "internal_chat_message_metadata_passthrough" };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source = try testingObject(&tmp, input);
    defer source.file.close(std.testing.io);
    const fields = try collectFields(&source, names);
    inline for (names) |name| _ = try fields.required(name);
    try std.testing.expectEqual(input.len, source.position);
    // The former per-field lookup restarted at byte zero for each of these
    // seven names. The collector consumes exactly one object, with no rereads
    // on lookup, including an unknown value larger than the file window.
    const kind = try fields.required("type");
    try std.testing.expectEqualStrings("\"message\"", input[@intCast(kind.start)..][0..@intCast(kind.length)]);
}

test "provider field collection preserves escaped keys duplicates and missing fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source = try testingObject(&tmp, "{\"ty\\u0070e\":\"message\",\"unused\":1,\"unused\":2}");
    defer source.file.close(std.testing.io);
    const fields = try collectFields(&source, &.{ "type", "id", "unused" });
    _ = try fields.required("type");
    try std.testing.expectEqual(null, try fields.get("id"));
    try std.testing.expectError(error.MissingProviderField, fields.required("id"));
    try std.testing.expectError(error.DuplicateJsonField, fields.get("unused"));
    var duplicate = try testingObject(&tmp, "{\"type\":1,\"ty\\u0070e\":2,\"type\":3}");
    defer duplicate.file.close(std.testing.io);
    const repeated = try collectFields(&duplicate, &.{"type"});
    try std.testing.expectError(error.DuplicateJsonField, repeated.required("type"));
}

test "provider field collection validates unknown and late syntax" {
    const cases = .{
        .{ "{\"type\":1,\"unknown\":\"\xff\"}", error.InvalidJsonUtf8 },
        .{ "{\"type\":1,\"unknown\":\"\\uD800x\"}", error.InvalidJsonSurrogate },
        .{ "{\"type\":1,\"unknown\":[1,]}", error.InvalidJsonValue },
        .{ "{\"type\":1} false", error.TrailingJson },
        .{ "{\"type\":1,\"unknown\":01}", error.InvalidJsonNumber },
        .{ "{\"type\":1,\"unknown\":" ++ "[" ** (protocol.max_json_depth + 1) ++ "0" ++ "]" ** (protocol.max_json_depth + 1) ++ "}", error.JsonTooDeep },
    };
    inline for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var source = try testingObject(&tmp, case[0]);
        defer source.file.close(std.testing.io);
        try std.testing.expectError(case[1], collectFields(&source, &.{"type"}));
    }
}

test "provider field collection cannot grant authority through escaped metadata keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source = try testingObject(&tmp, "{\"cell_\\u0069d\":null,\"unknown\":{\"nested\":[1,true]}}");
    defer source.file.close(std.testing.io);
    try std.testing.expectError(error.UnsupportedProviderOutput, validateMetadataAuthority(
        std.testing.io,
        source.file,
        .{ .start = 0, .length = source.end },
    ));
}
