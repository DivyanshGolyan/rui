const std = @import("std");
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

fn findField(io: std.Io, file: std.Io.File, object: Range, wanted: []const u8) !?Range {
    var source = try FileSource.init(io, file, object);
    try source.expect('{');
    try source.space();
    if (try source.peek() == '}') {
        _ = try source.take();
        try source.expectEnd();
        return null;
    }
    var found: ?Range = null;
    while (true) {
        var key: protocol.Bounded(max_evidence_bytes) = .{};
        try keyName(&source, &key);
        try source.expect(':');
        try source.space();
        const start = source.offset();
        try skipValue(&source, 1);
        const value = Range{ .start = start, .length = source.offset() - start };
        if (key.eql(wanted)) {
            if (found != null) return error.DuplicateJsonField;
            found = value;
        }
        try source.space();
        const delimiter = try source.take();
        if (delimiter == '}') break;
        if (delimiter != ',') return error.UnexpectedJsonDelimiter;
    }
    try source.expectEnd();
    return found;
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

fn requiredField(io: std.Io, file: std.Io.File, object: Range, name: []const u8) !Range {
    return try findField(io, file, object, name) orelse error.MissingProviderField;
}

fn optionalCompleted(io: std.Io, file: std.Io.File, object: Range) !void {
    const status = try findField(io, file, object, "status") orelse return;
    var value: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, status, &value);
    if (!value.eql("completed")) return error.UnsupportedProviderOutput;
}

fn validateMetadataAuthority(io: std.Io, file: std.Io.File, item: Range) !void {
    const metadata = try findField(io, file, item, "internal_chat_message_metadata_passthrough") orelse return;
    inline for (.{ "cell_id", "executed_tool_calls", "tool_calls_complete" }) |field| {
        if (try findField(io, file, metadata, field) != null) return error.UnsupportedProviderOutput;
    }
}

fn validateReasoning(io: std.Io, file: std.Io.File, item: Range) !void {
    try optionalCompleted(io, file, item);
    if (try findField(io, file, item, "text") != null) return error.UnsupportedProviderOutput;
    const encrypted = try requiredField(io, file, item, "encrypted_content");
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
    for (field_names, type_names) |field_name, type_name| {
        const array_range = try findField(io, file, item, field_name) orelse continue;
        var array = try Array.init(io, file, array_range);
        while (try array.next()) |block| {
            var kind: protocol.Bounded(max_evidence_bytes) = .{};
            _ = try readString(io, file, try requiredField(io, file, block, "type"), &kind);
            if (!kind.eql(type_name)) return error.UnsupportedProviderOutput;
            var text: protocol.Bounded(max_evidence_bytes) = .{};
            _ = readString(io, file, try requiredField(io, file, block, "text"), &text) catch |err| switch (err) {
                error.ProviderValueTooLong => {},
                else => return err,
            };
        }
    }
    try validateMetadataAuthority(io, file, item);
}

fn validateAnnotations(io: std.Io, file: std.Io.File, block: Range) !void {
    const annotations = try findField(io, file, block, "annotations") orelse return;
    var array = try Array.init(io, file, annotations);
    while (try array.next()) |annotation| {
        var kind: protocol.Bounded(max_evidence_bytes) = .{};
        _ = try readString(io, file, try requiredField(io, file, annotation, "type"), &kind);
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
    metadata: *store.OutputMetadataWriter,
    answer_hash: *std.crypto.hash.sha2.Sha256,
) !ItemValidation {
    var kind_name: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, try requiredField(io, file, item, "type"), &kind_name);
    const id_digest = try stringDigest(io, file, try requiredField(io, file, item, "id"));
    if (kind_name.eql("reasoning")) {
        try validateReasoning(io, file, item);
        return .{ .kind = .reasoning, .id_digest = id_digest };
    }
    if (!kind_name.eql("message")) return error.UnsupportedProviderOutput;
    try optionalCompleted(io, file, item);
    var role: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, try requiredField(io, file, item, "role"), &role);
    if (!role.eql("assistant")) return error.UnsupportedProviderOutput;
    if (try findField(io, file, item, "phase")) |phase_range| {
        var phase: protocol.Bounded(max_evidence_bytes) = .{};
        _ = try readString(io, file, phase_range, &phase);
        if (!phase.eql("commentary") and !phase.eql("final_answer")) return error.UnsupportedProviderOutput;
    }
    try validateMetadataAuthority(io, file, item);
    const content = try requiredField(io, file, item, "content");
    var array = try Array.init(io, file, content);
    var text_records: u64 = 0;
    while (try array.next()) |block| {
        var block_kind: protocol.Bounded(max_evidence_bytes) = .{};
        _ = try readString(io, file, try requiredField(io, file, block, "type"), &block_kind);
        if (!block_kind.eql("output_text")) return error.UnsupportedProviderOutput;
        try validateAnnotations(io, file, block);
        const text_value = try requiredField(io, file, block, "text");
        var source = try FileSource.init(io, file, text_value);
        var decoded = Decoded{ .hash = answer_hash };
        const text = try parseString(&source, &decoded);
        try source.expectEnd();
        try metadata.append(.{
            .tag = .text,
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
    var kind_name: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, try requiredField(io, file, item, "type"), &kind_name);
    const kind: store.OutputItemKind = if (kind_name.eql("reasoning"))
        .reasoning
    else if (kind_name.eql("message"))
        .message
    else
        return error.UnsupportedProviderOutput;
    return .{
        .kind = kind,
        .id_digest = try stringDigest(io, file, try requiredField(io, file, item, "id")),
        .content_digest = try contentDigestRange(io, file, item),
    };
}

fn eventType(io: std.Io, file: std.Io.File, event: Range, value: *protocol.Bounded(max_evidence_bytes)) !void {
    _ = try readString(io, file, try requiredField(io, file, event, "type"), value);
}

fn validateCompleted(
    io: std.Io,
    file: std.Io.File,
    event: Range,
    metadata: *store.OutputMetadataWriter,
    expected_items: u64,
    evidence: *Evidence,
) !void {
    const response = try requiredField(io, file, event, "response");
    var status: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, try requiredField(io, file, response, "status"), &status);
    if (!status.eql("completed")) return error.UnsupportedProviderOutput;
    _ = try readString(io, file, try requiredField(io, file, response, "id"), &evidence.response_id);
    if (evidence.response_id.len == 0) return error.EmptyProviderIdentity;
    if (try findField(io, file, response, "model")) |model| {
        var wide: protocol.Bounded(max_evidence_bytes) = .{};
        _ = try readString(io, file, model, &wide);
        if (wide.len == 0) return error.EmptyProviderIdentity;
        try evidence.served_model.set(wide.slice());
    }
    const output = try requiredField(io, file, response, "output");
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
    if (try findField(io, file, response, "usage")) |usage| {
        _ = try findField(io, file, usage, "total_tokens");
        try metadata.append(.{
            .tag = .usage,
            .start = usage.start,
            .length = usage.length,
            .content_digest = try contentDigestRange(io, file, usage),
        });
    }
}

fn identityAlreadySeen(metadata: *store.OutputMetadataWriter, identity: *const [32]u8) !bool {
    var reader = try store.OutputMetadataReader.init(metadata.io, metadata.file, 0);
    while (try reader.nextItem()) |record| {
        if (std.mem.eql(u8, &record.id_digest, identity)) return true;
    }
    return false;
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
    answer_length: *u64,
    answer_hash: *std.crypto.hash.sha2.Sha256,
    evidence: *Evidence,
) !void {
    if (completed.*) return error.LateProviderOutput;
    var kind: protocol.Bounded(max_evidence_bytes) = .{};
    try eventType(io, file, event, &kind);
    if (kind.eql("response.output_item.added")) {
        if (added.active) return error.ContradictoryProviderOutput;
        const index = try readIndex(io, file, try requiredField(io, file, event, "output_index"));
        if (index != item_count.*) return error.ContradictoryProviderOutput;
        const identity = try itemIdentity(io, file, try requiredField(io, file, event, "item"));
        added.* = .{ .active = true, .index = index, .kind = identity.kind, .id_digest = identity.id_digest };
        return;
    }
    if (kind.eql("response.output_item.done")) {
        const index = try readIndex(io, file, try requiredField(io, file, event, "output_index"));
        if (index != item_count.*) return error.ContradictoryProviderOutput;
        const item = try requiredField(io, file, event, "item");
        const validation = try validateItem(io, file, item, metadata, answer_hash);
        if (try identityAlreadySeen(metadata, &validation.id_digest)) return error.ContradictoryProviderOutput;
        if (added.active and (added.index != index or added.kind != validation.kind or
            !std.mem.eql(u8, &added.id_digest, &validation.id_digest))) return error.ContradictoryProviderOutput;
        added.active = false;
        if (validation.kind == .message) message_count.* += 1;
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
        if (added.active or item_count.* == 0 or message_count.* != 1) return error.IncompleteProviderOutput;
        try validateCompleted(io, file, event, metadata, item_count.*, evidence);
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
    if (answer_length == 0) return error.EmptyProviderAnswer;
    return .{
        .item_count = item_count,
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
    reader: *store.ContentReader,
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
pub fn writeReplayItem(reader: *store.ContentReader, writer: anytype) !void {
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

fn copyCanonicalRange(reader: *store.ContentReader, start: u64, length: u64, writer: anytype) !void {
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
