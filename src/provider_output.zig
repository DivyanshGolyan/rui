const std = @import("std");
const named_scratch = @import("named_scratch.zig");
const protocol = @import("protocol.zig");
const output_format = @import("output_format.zig");

pub const max_evidence_bytes = 256;

pub const Faults = struct {
    metadata: bool = false,
};

pub const Evidence = struct {
    response_id: protocol.Bounded(max_evidence_bytes) = .{},
    served_model: protocol.Bounded(protocol.max_model_bytes) = .{},
};

pub const Rejection = struct {
    stage: enum { stream, event, item, response } = .stream,
    byte_offset: u64 = 0,
    output_index: ?u64 = null,

    // Only local error names and structural coordinates. Never copy provider
    // strings, IDs, text, arguments or private continuation into this detail.
    pub fn format(self: Rejection, err: anyerror, buffer: *[512]u8) []const u8 {
        return std.fmt.bufPrint(
            buffer,
            "{{\"reason\":\"{s}\",\"stage\":\"{s}\",\"byte_offset\":\"{d}\",\"output_index\":{?d}}}",
            .{ @errorName(err), @tagName(self.stage), self.byte_offset, self.output_index },
        ) catch unreachable;
    }
};

pub const Validated = struct {
    item_count: u64,
    call_count: u64,
    answer_item_ordinal: ?u64,
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

    pub fn take(self: *FileSource) !u8 {
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
    non_whitespace: bool,
};

fn isWhitespace(scalar: u21) bool {
    // Unicode White_Space, matching the provider client's empty-answer test.
    return switch (scalar) {
        0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

fn parseString(source: anytype, decoded: ?*Decoded) !ParsedString {
    try source.space();
    if (try source.take() != '"') return error.ExpectedJsonString;
    const start = source.offset();
    var validator: Utf8Validator = .{};
    var decoded_length: u64 = 0;
    var non_whitespace = false;
    while (true) {
        const byte = try source.take();
        if (byte == '"') {
            try validator.finish();
            return .{
                .encoded = .{ .start = start, .length = source.offset() - start - 1 },
                .decoded_length = decoded_length,
                .non_whitespace = non_whitespace,
            };
        }
        if (byte < 0x20) return error.InvalidJsonString;
        if (byte != '\\') {
            try validator.feed(byte);
            if (!non_whitespace and validator.used == 0) {
                const scalar = if (byte < 0x80) byte else blk: {
                    const count = std.unicode.utf8ByteSequenceLength(validator.bytes[0]) catch unreachable;
                    break :blk std.unicode.utf8Decode(validator.bytes[0..count]) catch unreachable;
                };
                non_whitespace = non_whitespace or !isWhitespace(scalar);
            }
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
            non_whitespace = non_whitespace or !isWhitespace(value);
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
        non_whitespace = non_whitespace or !isWhitespace(scalar);
        if (decoded) |consumer| try consumer.emit(encoded[0..count]);
        decoded_length = try std.math.add(u64, decoded_length, count);
    }
}

const readHexScalar = output_format.readHexScalar;

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

fn collectFields(source: anytype, comptime names: []const []const u8) !Fields(names) {
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

fn exactOverflowCode(io: std.Io, file: std.Io.File, value: ?Range) !bool {
    const range = value orelse return false;
    var code: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, range, &code);
    return code.eql("context_length_exceeded");
}

fn errorOverflow(io: std.Io, file: std.Io.File, range: Range) !bool {
    const fields = try readFields(io, file, range, &.{"code"});
    return exactOverflowCode(io, file, try fields.get("code"));
}

fn malformedOverflow(err: anyerror) !bool {
    return switch (err) {
        error.UnexpectedJsonEnd,
        error.TrailingJson,
        error.UnexpectedJsonDelimiter,
        error.ExpectedJsonString,
        error.InvalidJsonString,
        error.InvalidJsonEscape,
        error.InvalidJsonSurrogate,
        error.InvalidJsonUtf8,
        error.InvalidJsonNumber,
        error.InvalidJsonLiteral,
        error.InvalidJsonValue,
        error.JsonTooDeep,
        error.DuplicateJsonField,
        error.MissingProviderField,
        error.ProviderValueTooLong,
        => false,
        else => err,
    };
}

/// Only a valid provider error envelope grants context-overflow authority.
/// Syntax failures are negative evidence, never permission to drop context.
pub fn contextOverflow(io: std.Io, file: std.Io.File, length: u64, http_status: u32) !bool {
    if (http_status < 400 or http_status >= 600) return false;
    const fields = readFields(io, file, .{ .start = 0, .length = length }, &.{"error"}) catch |err| return malformedOverflow(err);
    const failure = (fields.get("error") catch return false) orelse return false;
    return errorOverflow(io, file, failure) catch |err| malformedOverflow(err);
}

fn streamError(io: std.Io, file: std.Io.File, event: Range, failed_response: bool) !void {
    var failure = event;
    if (failed_response) {
        const fields = try readFields(io, file, event, &.{"response"});
        const response = try readFields(io, file, try fields.required("response"), &.{ "status", "error" });
        var status: protocol.Bounded(max_evidence_bytes) = .{};
        _ = try readString(io, file, try response.required("status"), &status);
        if (!status.eql("failed")) return error.IncompleteProviderOutput;
        failure = try response.get("error") orelse return error.TemporaryProviderFailure;
    } else {
        const fields = try readFields(io, file, event, &.{ "code", "error" });
        // Preserve the top-level Responses error code when supplied. Some
        // error events instead carry the provider error in a nested object.
        if (try fields.get("code") == null) {
            if (try fields.get("error")) |nested| failure = nested;
        }
    }
    if (try rangeEquals(io, file, failure, "null")) return error.TemporaryProviderFailure;
    const fields = try readFields(io, file, failure, &.{"code"});
    var code: protocol.Bounded(max_evidence_bytes) = .{};
    if (try fields.get("code")) |value| {
        if (!try rangeEquals(io, file, value, "null")) _ = try readString(io, file, value, &code);
    }
    if (code.eql("context_length_exceeded")) return error.ContextOverflow;
    // Codex 970111f6 codex-api/src/sse/responses_error.rs. Known terminal
    // quota/request/policy codes do not become retryable unknown failures.
    for ([_][]const u8{ "insufficient_quota", "credit_balance_exhausted", "organization_spend_limit_exceeded", "project_spend_limit_exceeded", "usage_not_included", "usage_limit_reached", "cyber_policy", "bio_policy", "misalignment_policy_violation", "invalid_prompt", "model_not_found" }) |permanent| {
        if (code.eql(permanent)) return error.PermanentProviderFailure;
    }
    return error.TemporaryProviderFailure;
}

fn incompleteOverflow(io: std.Io, file: std.Io.File, event: Range) !bool {
    const fields = try readFields(io, file, event, &.{"response"});
    const response = try readFields(io, file, try fields.required("response"), &.{ "status", "error", "incomplete_details" });
    var status: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, try response.required("status"), &status);
    if (!status.eql("incomplete")) return false;
    if (try response.get("error")) |failure| {
        if (!try rangeEquals(io, file, failure, "null") and try errorOverflow(io, file, failure)) return true;
    }
    if (try response.get("incomplete_details")) |details| {
        const reason = try readFields(io, file, details, &.{"reason"});
        return exactOverflowCode(io, file, try reason.get("reason"));
    }
    return false;
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
    var hash = protocol.contentHasher();
    var decoded = Decoded{ .hash = &hash };
    var source = try FileSource.init(io, file, value);
    const parsed = try parseString(&source, &decoded);
    try source.expectEnd();
    if (parsed.decoded_length == 0) return error.EmptyProviderIdentity;
    return hash.finalResult();
}

/// Bind every public call field to the accepted private provider item, including
/// deduplicated content whose projection may originate in another item.
pub fn authenticateCall(source: anytype, references: anytype) !void {
    const names = &.{ "id", "name", "call_id", "arguments" };
    const fields = try collectFields(source, names);
    inline for (names, 0..) |name, index| {
        const range = try fields.required(name);
        try source.setRange(range.start, range.length);
        var hash = protocol.contentHasher();
        var decoded: Decoded = .{ .hash = &hash };
        const parsed = try parseString(source, &decoded);
        try source.expectEnd();
        if (parsed.decoded_length != references[index].length or
            !std.mem.eql(u8, &hash.finalResult(), &references[index].digest)) return error.CorruptStore;
    }
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
    if (!value.eql("completed")) return error.UnsupportedItemStatus;
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
        return error.UnsupportedAsyncCall;
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
    if (parsed.decoded_length != 0) return error.UnsupportedCallControl;
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
    const type_range = try fields.get("type") orelse return error.UnsupportedCaller;
    var caller_type: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, type_range, &caller_type);
    if (!caller_type.eql("direct")) return error.UnsupportedCaller;
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
        if (try fields.get(field) != null) return error.UnsupportedMetadataAuthority;
    }
}

const item_field_names = &.{ "type", "id", "status", "role", "phase", "internal_chat_message_metadata_passthrough", "content", "text", "encrypted_content", "summary", "name", "call_id", "arguments", "caller", "async", "namespace", "encrypted_function_args" };
const ItemFields = Fields(item_field_names);

fn validateReasoning(io: std.Io, file: std.Io.File, fields: ItemFields) !void {
    try optionalCompleted(io, file, try fields.get("status"));
    if (try fields.get("text") != null) return error.UnsupportedReasoningText;
    const encrypted = (try fields.get("encrypted_content")) orelse return error.ContinuationUnavailable;
    var source = try FileSource.init(io, file, encrypted);
    const parsed = try parseString(&source, null);
    try source.expectEnd();
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
                if (!kind.eql(type_name)) return error.UnsupportedReasoningBlock;
                var text = try FileSource.init(io, file, try block_fields.required("text"));
                _ = try parseString(&text, null);
                try text.expectEnd();
            }
        }
    }
}

fn validateAnnotations(io: std.Io, file: std.Io.File, annotations_range: ?Range) !void {
    const annotations = annotations_range orelse return;
    var array = try Array.init(io, file, annotations);
    while (try array.next()) |annotation| {
        const fields = try readFields(io, file, annotation, &.{"type"});
        var kind: protocol.Bounded(max_evidence_bytes) = .{};
        _ = try readString(io, file, try fields.required("type"), &kind);
        if (!kind.eql("url_citation")) return error.UnsupportedAnnotation;
    }
}

const ItemValidation = struct {
    kind: output_format.OutputItemKind,
    id_digest: [32]u8,
    text_records: u64 = 0,
    non_whitespace: bool = false,
    phase: enum { unphased, commentary, final_answer } = .unphased,
};

fn validateItem(
    io: std.Io,
    file: std.Io.File,
    item: Range,
    ordinal: u64,
    metadata: *output_format.OutputMetadataWriter,
    answer_hash: *std.crypto.hash.sha2.Sha256,
    operation: output_format.ModelOperationKind,
) !ItemValidation {
    const fields = try readFields(io, file, item, item_field_names);
    var kind_name: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, try fields.required("type"), &kind_name);
    const id_digest = try stringDigest(io, file, try fields.required("id"));
    try validateMetadataAuthority(io, file, try fields.get("internal_chat_message_metadata_passthrough"));
    if (kind_name.eql("reasoning")) {
        try validateReasoning(io, file, fields);
        return .{ .kind = .reasoning, .id_digest = id_digest };
    }
    if (kind_name.eql("compaction")) {
        if (operation != .compaction) return error.UnsupportedProviderOutput;
        try optionalCompleted(io, file, try fields.get("status"));
        var encrypted = try FileSource.init(io, file, (try fields.get("encrypted_content")) orelse return error.ContinuationUnavailable);
        const value = try parseString(&encrypted, null);
        try encrypted.expectEnd();
        if (value.decoded_length == 0) return error.ContinuationUnavailable;
        return .{ .kind = .compaction, .id_digest = id_digest };
    }
    if (kind_name.eql("function_call")) {
        if (operation == .compaction) return error.UnsupportedProviderOutput;
        try optionalCompleted(io, file, try fields.get("status"));
        try validateFunctionCallControls(io, file, fields);
        inline for (.{
            .{ "id", output_format.OutputRecordTag.item_id, true },
            .{ "name", output_format.OutputRecordTag.name, true },
            .{ "call_id", output_format.OutputRecordTag.call_id, true },
            .{ "arguments", output_format.OutputRecordTag.arguments, false },
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
    if (!kind_name.eql("message")) return error.UnsupportedItemType;
    try optionalCompleted(io, file, try fields.get("status"));
    var role: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, try fields.required("role"), &role);
    if (!role.eql("assistant")) return error.UnsupportedMessageRole;
    var message_phase: @FieldType(ItemValidation, "phase") = .unphased;
    if (try fields.get("phase")) |phase_range| {
        if (!try rangeEquals(io, file, phase_range, "null")) {
            var phase: protocol.Bounded(max_evidence_bytes) = .{};
            _ = try readString(io, file, phase_range, &phase);
            message_phase = if (phase.eql("commentary")) .commentary else if (phase.eql("final_answer")) .final_answer else return error.UnsupportedMessagePhase;
        }
    }
    const content = try fields.required("content");
    var array = try Array.init(io, file, content);
    var text_records: u64 = 0;
    var non_whitespace = false;
    while (try array.next()) |block| {
        const block_fields = try readFields(io, file, block, &.{ "type", "text", "annotations" });
        var block_kind: protocol.Bounded(max_evidence_bytes) = .{};
        _ = try readString(io, file, try block_fields.required("type"), &block_kind);
        if (!block_kind.eql("output_text")) return error.UnsupportedContentBlock;
        try validateAnnotations(io, file, try block_fields.get("annotations"));
        const text_value = try block_fields.required("text");
        var source = try FileSource.init(io, file, text_value);
        var decoded = Decoded{ .hash = answer_hash };
        const text = try parseString(&source, &decoded);
        try source.expectEnd();
        non_whitespace = non_whitespace or text.non_whitespace;
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
    return .{ .kind = .message, .id_digest = id_digest, .text_records = text_records, .non_whitespace = non_whitespace, .phase = message_phase };
}

/// One sequential compatibility pass. Partial string/number tokens never own
/// payload storage. Frames retain only consequential field facts; errors in
/// meaning are deferred until syntax and the complete source have validated.
/// Initialize/use in final storage (the scanner borrows its nesting buffer).
pub const ReplayValidationCursor = struct {
    scanner: ?std.json.Scanner = null,
    nesting: [16]u8 = undefined,
    allocator: std.heap.FixedBufferAllocator = undefined,
    input: [protocol.content_window_bytes]u8 = undefined,
    utf8: Utf8Validator = .{},
    position: u64 = 0,
    frames: [protocol.max_json_depth + 1]Frame = undefined,
    depth: usize = 0,
    result: Value = .{},
    token_text: protocol.Bounded(max_evidence_bytes) = .{},
    token_length: u64 = 0,
    token_overflow: bool = false,
    token_hash: @TypeOf(protocol.contentHasher()) = protocol.contentHasher(),
    call_fields: @FieldType(protocol.ProposalMetadata, "fields") = undefined,
    call_fields_seen: u4 = 0,

    /// Bind every retained item to its admission-certified type and ID.
    /// Compatibility errors are deferred until these canonical facts agree.
    pub fn authenticateIdentity(self: *const ReplayValidationCursor, kind: output_format.OutputItemKind, id_digest: [32]u8) !void {
        const actual = try self.frames[0].get("type");
        if (!actual.is(@tagName(kind)) or self.call_fields_seen & 1 == 0 or
            !std.mem.eql(u8, &self.call_fields[0].digest, &id_digest)) return error.CorruptStore;
    }

    /// After advance completes, bind admission-certified fields to the exact
    /// decoded top-level strings. One token hasher and four results suffice;
    /// nested/open fields never acquire per-frame hashes or payload copies.
    pub fn authenticate(self: *const ReplayValidationCursor, references: anytype) !void {
        if (self.call_fields_seen != 15) return error.CorruptStore;
        for (self.call_fields, references) |actual, expected| {
            if (actual.length != expected.length or !std.mem.eql(u8, &actual.digest, &expected.digest))
                return error.CorruptStore;
        }
    }

    const names = item_field_names.* ++ [_][]const u8{ "annotations", "cell_id", "executed_tool_calls", "tool_calls_complete" };
    const words = [_][]const u8{ "reasoning", "compaction", "function_call", "message", "completed", "assistant", "commentary", "final_answer", "direct", "output_text", "reasoning_text", "summary_text", "url_citation" };
    const Shape = enum { absent, string, object, array, null_value, false_value, other };
    const Value = struct {
        shape: Shape = .absent,
        word: ?usize = null,
        length: u64 = 0,
        duplicate: bool = false,
        failure: ?anyerror = null,
        output_failure: ?anyerror = null,
        reasoning_failure: ?anyerror = null,
        summary_failure: ?anyerror = null,
        // A block can be checked after the enclosing item's type arrives.
        output: bool = true,
        reasoning: bool = true,
        summary: bool = true,

        fn is(self: Value, word: []const u8) bool {
            return self.shape == .string and self.word != null and std.mem.eql(u8, words[self.word.?], word);
        }
    };
    const Kind = enum { item, block, annotation, caller, metadata, blocks, annotations, ignored };
    const Frame = struct {
        kind: Kind,
        object: bool,
        key: ?usize = null,
        wants_key: bool = true,
        fields: [names.len]Value = @splat(.{}),
        aggregate: Value = .{ .shape = .array },

        fn get(self: *const Frame, comptime name: []const u8) !Value {
            const value = self.fields[index(name).?];
            if (value.duplicate) return error.DuplicateJsonField;
            return value;
        }

        fn requiredString(self: *const Frame, comptime name: []const u8, nonempty: bool) !Value {
            const value = try self.get(name);
            if (value.shape != .string or (nonempty and value.length == 0)) return error.ContinuationUnavailable;
            return value;
        }

        // Canonical consumed-field ambiguity outranks adapter incompatibility,
        // including ambiguity inside a later child after an earlier failure.
        fn validateFields(self: *const Frame, comptime field_names: []const []const u8) !void {
            inline for (field_names) |name| {
                const value = try self.get(name);
                if (value.failure) |err| if (err == error.DuplicateJsonField) return err;
                if (self.kind == .item and value.shape == .array and
                    (comptime std.mem.eql(u8, name, "content") or std.mem.eql(u8, name, "summary")))
                {
                    const kind = try self.get("type");
                    // Each supported child retains its consumed ambiguity,
                    // independently of incompatible siblings. Other block
                    // interpretations and reasoning annotations stay opaque.
                    const failure = if (kind.is("reasoning"))
                        (if (comptime std.mem.eql(u8, name, "summary")) value.summary_failure else value.reasoning_failure)
                    else
                        value.output_failure;
                    if (failure) |err| if (err == error.DuplicateJsonField) return err;
                }
            }
        }
    };

    fn index(name: []const u8) ?usize {
        for (names, 0..) |candidate, i| if (std.mem.eql(u8, candidate, name)) return i;
        return null;
    }

    fn appendText(self: *ReplayValidationCursor, bytes: []const u8) !void {
        self.token_hash.update(bytes);
        self.token_length = try std.math.add(u64, self.token_length, bytes.len);
        if (self.token_overflow or self.token_text.len + bytes.len > max_evidence_bytes) {
            self.token_overflow = true;
        } else {
            @memcpy(self.token_text.bytes[self.token_text.len..][0..bytes.len], bytes);
            self.token_text.len += bytes.len;
        }
    }

    fn accept(self: *ReplayValidationCursor, value: Value) void {
        if (self.depth == 0) {
            self.result = value;
            return;
        }
        const frame = &self.frames[self.depth - 1];
        if (frame.object) {
            if (frame.key) |key| {
                var stored = value;
                stored.duplicate = frame.fields[key].shape != .absent;
                frame.fields[key] = stored;
            }
            frame.wants_key = true;
            frame.key = null;
        } else {
            frame.aggregate.length += 1;
            inline for (.{ "failure", "output_failure", "reasoning_failure", "summary_failure" }) |name| {
                if (@field(value, name)) |err| {
                    const prior = &@field(frame.aggregate, name);
                    if (prior.* == null or prior.*.? != error.DuplicateJsonField) prior.* = err;
                }
            }
            frame.aggregate.output = frame.aggregate.output and value.shape == .object and value.output;
            frame.aggregate.reasoning = frame.aggregate.reasoning and value.shape == .object and value.reasoning;
            frame.aggregate.summary = frame.aggregate.summary and value.shape == .object and value.summary;
        }
    }

    fn childKind(self: *ReplayValidationCursor, object: bool) Kind {
        if (self.depth == 0) return if (object) .item else .ignored;
        const parent = &self.frames[self.depth - 1];
        if (!parent.object) return switch (parent.kind) {
            .blocks => if (object) .block else .ignored,
            .annotations => if (object) .annotation else .ignored,
            else => .ignored,
        };
        const key = parent.key orelse return .ignored;
        const name = names[key];
        if (parent.kind == .item) {
            if (object and std.mem.eql(u8, name, "caller")) return .caller;
            if (object and std.mem.eql(u8, name, "internal_chat_message_metadata_passthrough")) return .metadata;
            if (!object and (std.mem.eql(u8, name, "content") or std.mem.eql(u8, name, "summary"))) return .blocks;
        }
        if (parent.kind == .block and !object and std.mem.eql(u8, name, "annotations")) return .annotations;
        return .ignored;
    }

    fn finishFrame(frame: *const Frame) !Value {
        if (!frame.object) return frame.aggregate;
        switch (frame.kind) {
            .item => {
                try frame.validateFields(&.{ "type", "id", "status", "internal_chat_message_metadata_passthrough" });
                const kind = try frame.get("type");
                if (kind.is("function_call")) {
                    try frame.validateFields(&.{ "name", "call_id", "arguments", "caller", "async", "namespace", "encrypted_function_args" });
                } else if (kind.is("reasoning")) {
                    try frame.validateFields(&.{ "text", "encrypted_content", "summary", "content" });
                } else if (kind.is("compaction")) {
                    try frame.validateFields(&.{"encrypted_content"});
                } else if (kind.is("message")) {
                    try frame.validateFields(&.{ "role", "phase", "content" });
                }
            },
            .block => {
                try frame.validateFields(&.{"type"});
            },
            .annotation, .caller => try frame.validateFields(&.{"type"}),
            .metadata => try frame.validateFields(&.{ "cell_id", "executed_tool_calls", "tool_calls_complete" }),
            else => {},
        }
        var result = Value{ .shape = .object };
        switch (frame.kind) {
            .item => {
                const kind = try frame.requiredString("type", false);
                if (kind.length > max_evidence_bytes) return error.ContinuationUnavailable;
                _ = try frame.requiredString("id", true);
                if (!kind.is("reasoning") and !kind.is("compaction") and !kind.is("function_call") and !kind.is("message")) return error.ContinuationUnavailable;
                const status = try frame.get("status");
                if (status.shape != .absent and !status.is("completed")) return error.ContinuationUnavailable;
                const metadata = try frame.get("internal_chat_message_metadata_passthrough");
                if (metadata.shape != .absent) {
                    if (metadata.shape != .object) return error.ContinuationUnavailable;
                    if (metadata.failure) |err| return err;
                }
                if (kind.is("function_call")) {
                    _ = try frame.requiredString("name", true);
                    _ = try frame.requiredString("call_id", true);
                    _ = try frame.requiredString("arguments", false);
                    const caller = try frame.get("caller");
                    if (caller.shape != .absent and caller.shape != .null_value) {
                        if (caller.shape != .object) return error.ContinuationUnavailable;
                        if (caller.failure) |err| return err;
                    }
                    const asynchronous = try frame.get("async");
                    if (asynchronous.shape != .absent and asynchronous.shape != .null_value and asynchronous.shape != .false_value) return error.ContinuationUnavailable;
                    inline for (.{ "namespace", "encrypted_function_args" }) |name| {
                        const value = try frame.get(name);
                        if (value.shape != .absent and value.shape != .null_value and !(value.shape == .string and value.length == 0)) return error.ContinuationUnavailable;
                    }
                    return result;
                }
                if (kind.is("reasoning") or kind.is("compaction")) {
                    _ = try frame.requiredString("encrypted_content", true);
                    if (kind.is("reasoning")) {
                        if ((try frame.get("text")).shape != .absent) return error.ContinuationUnavailable;
                        inline for (.{ "summary", "content" }) |name| {
                            const blocks = try frame.get(name);
                            if (blocks.shape != .absent) {
                                if (blocks.shape != .array) return error.ContinuationUnavailable;
                                if (!(if (comptime std.mem.eql(u8, name, "summary")) blocks.summary else blocks.reasoning)) return error.ContinuationUnavailable;
                                if (blocks.failure) |err| return err;
                            }
                        }
                    }
                    return result;
                }
                if (!(try frame.requiredString("role", false)).is("assistant")) return error.ContinuationUnavailable;
                const phase = try frame.get("phase");
                if (phase.shape != .absent and phase.shape != .null_value and !phase.is("commentary") and !phase.is("final_answer")) return error.ContinuationUnavailable;
                const content = try frame.get("content");
                if (content.shape != .array or content.length == 0) return error.ContinuationUnavailable;
                if (!content.output) return error.ContinuationUnavailable;
                if (content.failure) |err| return err;
                if (content.output_failure) |err| return err;
            },
            .block => {
                const kind = try frame.requiredString("type", false);
                result.output = kind.is("output_text");
                result.reasoning = kind.is("reasoning_text");
                result.summary = kind.is("summary_text");
                if (!result.output and !result.reasoning and !result.summary) return result;
                frame.validateFields(&.{"text"}) catch |err| {
                    if (result.output) result.output_failure = err else if (result.reasoning) result.reasoning_failure = err else result.summary_failure = err;
                    return result;
                };
                if (result.output) frame.validateFields(&.{"annotations"}) catch |err| {
                    result.output_failure = err;
                    return result;
                };
                _ = frame.requiredString("text", false) catch |err| {
                    result.failure = err;
                    return result;
                };
                // Reasoning blocks retain annotations without interpreting them.
                if (!result.output) return result;
                const annotations = frame.get("annotations") catch |err| {
                    result.output_failure = err;
                    return result;
                };
                result.output_failure = annotations.failure;
                if (annotations.shape != .absent and (annotations.shape != .array or !annotations.output)) result.output_failure = error.ContinuationUnavailable;
            },
            .annotation => {
                result.output = (try frame.requiredString("type", false)).is("url_citation");
            },
            .caller => {
                if (!(try frame.requiredString("type", false)).is("direct")) return error.ContinuationUnavailable;
            },
            .metadata => inline for (.{ "cell_id", "executed_tool_calls", "tool_calls_complete" }) |name| {
                if ((try frame.get(name)).shape != .absent) return error.ContinuationUnavailable;
            },
            else => {},
        }
        return result;
    }

    /// Source implements contentLength/readContent. Each refill is charged at
    /// its actual size, including ignored bytes. Each scanner token (including
    /// partial tokens and open fields) consumes one item of the caller's turn.
    pub fn advance(self: *ReplayValidationCursor, source: anytype, bytes_left: *usize, items_left: *usize) !bool {
        if (self.scanner == null) {
            self.allocator = .init(&self.nesting);
            self.scanner = std.json.Scanner.initStreaming(self.allocator.allocator());
            // Avoid ArrayList's cache-line-sized growth policy. These 128 bits
            // cover the depth guard plus the one opening token it observes.
            try self.scanner.?.stack.bytes.ensureTotalCapacityPrecise(self.nesting.len);
        }
        const scanner = &self.scanner.?;
        while (items_left.* != 0) {
            const token = scanner.next() catch |err| switch (err) {
                error.BufferUnderrun => {
                    if (bytes_left.* == 0) return false;
                    const wanted: usize = @intCast(@min(@min(source.contentLength() - self.position, self.input.len), bytes_left.*));
                    if (wanted == 0) {
                        scanner.endInput();
                        continue;
                    }
                    const count = try source.readContent(self.position, self.input[0..wanted]);
                    if (count != wanted) return error.ShortSealedRead;
                    self.position += count;
                    bytes_left.* -= count;
                    for (self.input[0..count]) |byte| try self.utf8.feed(byte);
                    scanner.feedInput(self.input[0..count]);
                    if (self.position == source.contentLength()) {
                        try self.utf8.finish();
                        scanner.endInput();
                    }
                    continue;
                },
                else => return err,
            };
            items_left.* -= 1;
            if (self.depth > protocol.max_json_depth and token != .object_end and token != .array_end) {
                const frame = &self.frames[self.depth - 1];
                if (!frame.object or !frame.wants_key) return error.JsonTooDeep;
            }
            switch (token) {
                .partial_string => |text| try self.appendText(text),
                .partial_string_escaped_1 => |text| try self.appendText(&text),
                .partial_string_escaped_2 => |text| try self.appendText(&text),
                .partial_string_escaped_3 => |text| try self.appendText(&text),
                .partial_string_escaped_4 => |text| try self.appendText(&text),
                .string => |text| {
                    try self.appendText(text);
                    if (self.depth != 0 and self.frames[self.depth - 1].object and self.frames[self.depth - 1].wants_key) {
                        const frame = &self.frames[self.depth - 1];
                        frame.key = if (self.token_overflow) null else index(self.token_text.slice());
                        frame.wants_key = false;
                    } else {
                        var value = Value{ .shape = .string, .length = self.token_length };
                        if (self.depth == 1) {
                            inline for (.{ "id", "name", "call_id", "arguments" }, 0..) |name, i| {
                                if (self.frames[0].key == index(name)) {
                                    self.call_fields[i] = .{ .length = self.token_length, .digest = self.token_hash.finalResult() };
                                    self.call_fields_seen |= @as(u4, 1) << i;
                                }
                            }
                        }
                        if (!self.token_overflow) for (words, 0..) |word, i| {
                            if (self.token_text.eql(word)) value.word = i;
                        };
                        self.accept(value);
                    }
                    self.token_text.len = 0;
                    self.token_length = 0;
                    self.token_overflow = false;
                    self.token_hash = protocol.contentHasher();
                },
                .object_begin, .array_begin => {
                    if (self.depth > protocol.max_json_depth) return error.JsonTooDeep;
                    const object = token == .object_begin;
                    const kind = self.childKind(object);
                    self.frames[self.depth] = .{ .kind = kind, .object = object };
                    self.depth += 1;
                },
                .object_end, .array_end => {
                    self.depth -= 1;
                    const frame = &self.frames[self.depth];
                    const value = finishFrame(frame) catch |err| Value{ .shape = if (frame.object) .object else .array, .failure = err };
                    self.accept(value);
                },
                .partial_number => {},
                .number, .true => self.accept(.{ .shape = .other }),
                .false => self.accept(.{ .shape = .false_value }),
                .null => self.accept(.{ .shape = .null_value }),
                .end_of_document => {
                    if (self.result.shape != .object) return error.UnexpectedJsonDelimiter;
                    if (self.result.failure) |err| return err;
                    return true;
                },
                .allocated_string, .allocated_number => unreachable,
            }
        }
        return false;
    }
};

/// Check one selected canonical item against current wire rules, without
/// emitting metadata or retaining a payload. Store owns integrity validation.
/// Test driver for the same bounded cursor used by request preparation.
fn validateReplay(io: std.Io, source: std.Io.File, length: u64) !void {
    const Source = struct {
        io: std.Io,
        file: std.Io.File,
        length: u64,

        pub fn contentLength(self: @This()) u64 {
            return self.length;
        }

        pub fn readContent(self: @This(), offset: u64, destination: []u8) !usize {
            return self.file.readPositionalAll(self.io, destination, offset);
        }
    };
    var cursor: ReplayValidationCursor = .{};
    while (true) {
        var bytes: usize = protocol.content_window_bytes;
        var items: usize = 64;
        if (try cursor.advance(Source{ .io = io, .file = source, .length = length }, &bytes, &items)) return;
    }
}

test "replay compatibility rejects unsupported meaning and preserves open fields" {
    const cases = [_]struct { item: []const u8, supported: bool }{
        .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"future\":{\"nested\":[null,true]}}", .supported = true },
        .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\"}", .supported = false },
        .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":null}", .supported = false },
        .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"summary\":null}", .supported = false },
        .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"opaque\",\"created_by\":\"canonical\"}", .supported = true },
        .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"\"}", .supported = false },
        .{ .item = "{\"type\":\"compaction_v2\",\"id\":\"c\",\"encrypted_content\":\"opaque\"}", .supported = false },
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", .supported = true },
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"future_text\",\"text\":\"ok\"}]}", .supported = false },
        .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"call\",\"arguments\":\"{}\",\"caller\":{\"type\":\"future\"}}", .supported = false },
        .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"call\",\"arguments\":\"{}\",\"async\":17}", .supported = false },
        .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"status\":\"in_progress\",\"encrypted_content\":\"opaque\"}", .supported = false },
        .{ .item = "{\"content\":[{\"text\":\"ok\",\"annotations\":[{\"url\":\"https://example.com\",\"type\":\"url_citation\"}],\"type\":\"output_text\"}],\"role\":\"assistant\",\"phase\":\"final_answer\",\"id\":\"m\",\"type\":\"message\"}", .supported = true },
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"annotations\":[{\"type\":\"file_citation\"}]}]}", .supported = false },
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[]}", .supported = false },
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"user\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", .supported = false },
        .{ .item = "{\"summary\":[{\"annotations\":false,\"text\":\"summary\",\"type\":\"summary_text\"}],\"content\":[{\"text\":\"private\",\"type\":\"reasoning_text\"}],\"encrypted_content\":\"opaque\",\"id\":\"r\",\"type\":\"reasoning\"}", .supported = true },
        .{ .item = "{\"content\":[{\"type\":\"reasoning_text\",\"text\":\"private\",\"annotations\":[],\"annotations\":false}],\"encrypted_content\":\"opaque\",\"id\":\"r\",\"type\":\"reasoning\"}", .supported = true },
        .{ .item = "{\"summary\":[{\"type\":\"summary_text\",\"text\":\"summary\",\"annotations\":[{\"type\":\"future\",\"type\":false}]}],\"encrypted_content\":\"opaque\",\"id\":\"r\",\"type\":\"reasoning\"}", .supported = true },
        .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"text\":null}", .supported = false },
        .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"opaque\",\"internal_chat_message_metadata_passthrough\":{\"cell_id\":null}}", .supported = false },
        .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"opaque\",\"internal_chat_message_metadata_passthrough\":{\"future\":{\"cell_id\":null}}}", .supported = true },
        .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"\",\"caller\":null,\"async\":null,\"namespace\":\"\",\"encrypted_function_args\":null}", .supported = true },
        .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"async\":true}", .supported = false },
        .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"namespace\":\"program\"}", .supported = false },
        .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"encrypted_function_args\":\"opaque\"}", .supported = false },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try testingObject(&tmp, case.item);
        defer source.file.close(std.testing.io);
        if (case.supported) {
            try validateReplay(std.testing.io, source.file, case.item.len);
        } else {
            try std.testing.expectError(error.ContinuationUnavailable, validateReplay(std.testing.io, source.file, case.item.len));
        }
    }
}

test "replay compatibility distinguishes consumed duplicates and syntax from unsupported shapes" {
    const cases = [_]struct { item: []const u8, failure: anyerror }{
        .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"id\":\"s\",\"encrypted_content\":\"opaque\"}", .failure = error.DuplicateJsonField },
        .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"status\":\"future\",\"encrypted_content\":\"a\",\"encrypted_content\":\"b\"}", .failure = error.DuplicateJsonField },
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"text\":\"other\"}]}", .failure = error.DuplicateJsonField },
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"annotations\":[{\"type\":\"url_citation\",\"type\":\"url_citation\"}]}]}", .failure = error.DuplicateJsonField },
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"status\":\"future\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"annotations\":[],\"annotations\":false}]}", .failure = error.DuplicateJsonField },
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"status\":\"future\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"annotations\":[{\"type\":\"future\",\"type\":false}]}]}", .failure = error.DuplicateJsonField },
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"future_text\"},{\"type\":\"output_text\",\"text\":\"a\",\"text\":\"b\"}]}", .failure = error.DuplicateJsonField },
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"a\",\"text\":\"b\"},{\"type\":\"future_text\"}]}", .failure = error.DuplicateJsonField },
        .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"future_text\"},{\"type\":\"reasoning_text\",\"text\":\"a\",\"text\":\"b\"}]}", .failure = error.DuplicateJsonField },
        .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"reasoning_text\",\"text\":\"a\",\"text\":\"b\"},{\"type\":\"future_text\"}]}", .failure = error.DuplicateJsonField },
        .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"future_text\"},{\"type\":\"summary_text\",\"text\":\"a\",\"text\":\"b\"}]}", .failure = error.DuplicateJsonField },
        .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"a\",\"text\":\"b\"},{\"type\":\"future_text\"}]}", .failure = error.DuplicateJsonField },
        .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"output_text\",\"text\":\"a\",\"text\":\"b\"}]}", .failure = error.ContinuationUnavailable },
        .{ .item = "{\"type\":\"future\",\"id\":\"r\",\"open\":[true,]}", .failure = error.SyntaxError },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try testingObject(&tmp, case.item);
        defer source.file.close(std.testing.io);
        try std.testing.expectError(case.failure, validateReplay(std.testing.io, source.file, case.item.len));
    }
}

test "replay compatibility streams opaque windows and preserves syntax failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "replay", .{ .read = true });
    defer file.close(std.testing.io);
    const prefix = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"";
    const suffix = "\",\"future\":[true,null]}";
    const window: [protocol.content_window_bytes]u8 = @splat('x');
    try file.writeStreamingAll(std.testing.io, prefix);
    for (0..3) |_| try file.writeStreamingAll(std.testing.io, &window);
    try file.writeStreamingAll(std.testing.io, suffix);
    try validateReplay(std.testing.io, file, prefix.len + 3 * window.len + suffix.len);

    const invalid = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"future\":\"\xff\"}";
    const source = try testingObject(&tmp, invalid);
    defer source.file.close(std.testing.io);
    try std.testing.expectError(error.InvalidJsonUtf8, validateReplay(std.testing.io, source.file, invalid.len));
}

test "replay compatibility cursor bounds actual sequential reads including open fields" {
    const CountingSource = struct {
        file: std.Io.File,
        length: u64,
        read_bytes: u64 = 0,

        pub fn contentLength(self: *@This()) u64 {
            return self.length;
        }

        pub fn readContent(self: *@This(), offset: u64, destination: []u8) !usize {
            try std.testing.expectEqual(self.read_bytes, offset);
            const count = try self.file.readPositionalAll(std.testing.io, destination, offset);
            self.read_bytes += count;
            return count;
        }
    };
    for ([_]bool{ false, true }) |supported| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const file = try tmp.dir.createFile(std.testing.io, "large-private-item", .{ .read = true });
        defer file.close(std.testing.io);
        // Type follows its content and controls. Duplicate unknown keys remain
        // open; neither a long string nor thousands of fields may hide work.
        try file.writeStreamingAll(std.testing.io, "{\"arguments\":\"");
        const window: [protocol.content_window_bytes]u8 = @splat('x');
        for (0..8) |_| try file.writeStreamingAll(std.testing.io, &window);
        try file.writeStreamingAll(std.testing.io, "\",");
        for (0..2000) |_| try file.writeStreamingAll(std.testing.io, "\"future\":{\"nested\":[null,17,true]},");
        try file.writeStreamingAll(std.testing.io, if (supported)
            "\"caller\":{\"future\":0,\"type\":\"direct\"},\"async\":false,\"namespace\":null,\"name\":\"bash\",\"id\":\"f\",\"call_id\":\"c\",\"type\":\"function_call\"}"
        else
            "\"caller\":{\"type\":\"program\"},\"name\":\"bash\",\"id\":\"f\",\"call_id\":\"c\",\"type\":\"function_call\"}");
        var source = CountingSource{ .file = file, .length = try file.length(std.testing.io) };
        var cursor: ReplayValidationCursor = .{};
        var turns: usize = 0;
        while (true) {
            turns += 1;
            try std.testing.expect(turns < 100000);
            const before = source.read_bytes;
            var bytes: usize = 7;
            var items: usize = 2;
            const finished = cursor.advance(&source, &bytes, &items) catch |err| {
                try std.testing.expect(!supported);
                try std.testing.expectEqual(error.ContinuationUnavailable, err);
                try std.testing.expect(source.read_bytes - before <= 7);
                try std.testing.expectEqual(source.length, source.read_bytes);
                break;
            };
            try std.testing.expect(source.read_bytes - before <= 7);
            try std.testing.expectEqual(@as(u64, 7 - bytes), source.read_bytes - before);
            try std.testing.expect(items <= 2);
            if (finished) {
                try std.testing.expect(supported);
                try std.testing.expectEqual(source.length, source.read_bytes);
                break;
            }
        }
        try std.testing.expect(turns > 10000);
    }
}

test "incremental call authentication binds all four decoded fields with fixed storage" {
    const Source = struct {
        bytes: []const u8,
        pub fn contentLength(source: @This()) u64 {
            return source.bytes.len;
        }
        pub fn readContent(source: @This(), offset: u64, destination: []u8) !usize {
            const count = @min(destination.len, source.bytes.len - offset);
            @memcpy(destination[0..count], source.bytes[@intCast(offset)..][0..count]);
            return count;
        }
    };
    const source = Source{ .bytes = "{\"arguments\":\"a\\u0000\\ud83d\\ude80\",\"future\":{\"id\":\"not the item\"},\"call_id\":\"c\\u0061ll\",\"name\":\"ba\\u0073h\",\"id\":\"\\u0069tem\",\"type\":\"function_call\"}" };
    var expected: @FieldType(protocol.ProposalMetadata, "fields") = undefined;
    for ([_][]const u8{ "item", "bash", "call", "a\x00🚀" }, &expected) |value, *field|
        field.* = .{ .length = value.len, .digest = protocol.contentDigest(value) };
    var cursor: ReplayValidationCursor = .{};
    var turns: usize = 0;
    while (true) {
        var bytes: usize = 1;
        var items: usize = 1;
        turns += 1;
        if (try cursor.advance(source, &bytes, &items)) break;
    }
    try std.testing.expect(turns >= source.bytes.len);
    try cursor.authenticate(expected);
    for (0..4) |i| {
        var corrupt = expected;
        corrupt[i].digest[0] ^= 1;
        try std.testing.expectError(error.CorruptStore, cursor.authenticate(corrupt));
        corrupt = expected;
        corrupt[i].length += 1;
        try std.testing.expectError(error.CorruptStore, cursor.authenticate(corrupt));
    }
    try std.testing.expect(@sizeOf(@TypeOf(cursor.call_fields)) == 160);
}

const Added = struct {
    active: bool = false,
    index: u64 = 0,
    kind: output_format.OutputItemKind = .reasoning,
    id_digest: [32]u8 = @splat(0),
};

fn itemIdentity(io: std.Io, file: std.Io.File, item: Range) !struct {
    kind: output_format.OutputItemKind,
    id_digest: [32]u8,
} {
    const fields = try readFields(io, file, item, &.{ "type", "id" });
    var kind_name: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, try fields.required("type"), &kind_name);
    const kind: output_format.OutputItemKind = if (kind_name.eql("reasoning"))
        .reasoning
    else if (kind_name.eql("message"))
        .message
    else if (kind_name.eql("function_call"))
        .function_call
    else if (kind_name.eql("compaction"))
        .compaction
    else
        return error.UnsupportedItemType;
    return .{
        .kind = kind,
        .id_digest = try stringDigest(io, file, try fields.required("id")),
    };
}

/// Derive the pressure anchor while validating provider bytes, not during
/// Store replay. The raw usage range remains private immutable evidence.
pub fn usagePressure(io: std.Io, file: std.Io.File, start: u64, length: u64) !?u64 {
    var source = try FileSource.init(io, file, .{ .start = start, .length = length });
    var depth: usize = 0;
    var total: ?u64 = null;
    var input: ?u64 = null;
    var output: ?u64 = null;
    var input_seen = false;
    var output_seen = false;
    var duplicate_split = false;
    while (try source.peek() != null) {
        switch (try source.take()) {
            '{', '[' => depth += 1,
            '}', ']' => depth -= 1,
            '"' => {
                var key: [32]u8 = undefined;
                var length_decoded: usize = 0;
                while (try source.peek() != '"') {
                    var scalar: [4]u8 = undefined;
                    const count = try output_format.decodeScalar(&source, &scalar);
                    for (scalar[0..count]) |decoded| {
                        if (length_decoded < key.len) key[length_decoded] = decoded;
                        length_decoded += 1;
                    }
                }
                _ = try source.take();
                if (depth != 1 or length_decoded > key.len) continue;
                try source.space();
                if (try source.peek() != ':') continue;
                _ = try source.take();
                const is_input = std.mem.eql(u8, key[0..length_decoded], "input_tokens");
                const is_output = std.mem.eql(u8, key[0..length_decoded], "output_tokens");
                if (is_input) {
                    duplicate_split = duplicate_split or input_seen;
                    input_seen = true;
                }
                if (is_output) {
                    duplicate_split = duplicate_split or output_seen;
                    output_seen = true;
                }
                try source.space();
                var token_count: u64 = 0;
                var digits: usize = 0;
                const first_digit = try source.peek();
                while (try source.peek()) |next| {
                    if (next < '0' or next > '9') break;
                    _ = try source.take();
                    token_count = token_count *| 10 +| (next - '0');
                    digits += 1;
                }
                if (digits == 0 or (digits > 1 and first_digit == '0') or token_count > std.math.maxInt(i64)) continue;
                try source.space();
                const delimiter = try source.peek();
                if (delimiter != ',' and delimiter != '}') continue;
                if (std.mem.eql(u8, key[0..length_decoded], "total_tokens")) total = token_count;
                if (is_input) input = token_count;
                if (is_output) output = token_count;
            },
            else => {},
        }
    }
    if (total) |value| return value;
    if (duplicate_split) return null;
    return (input orelse return null) +| (output orelse return null);
}

fn validateCompleted(
    io: std.Io,
    file: std.Io.File,
    response: Range,
    metadata: *output_format.OutputMetadataWriter,
    expected_items: u64,
    evidence: *Evidence,
) !void {
    const fields = try readFields(io, file, response, &.{ "status", "id", "model", "output", "usage" });
    var status: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(io, file, try fields.required("status"), &status);
    if (!status.eql("completed")) return error.UnsupportedResponseStatus;
    _ = try readString(io, file, try fields.required("id"), &evidence.response_id);
    if (evidence.response_id.len == 0) return error.EmptyProviderIdentity;
    if (try fields.get("model")) |model| {
        if (!try rangeEquals(io, file, model, "null")) {
            var wide: protocol.Bounded(max_evidence_bytes) = .{};
            _ = try readString(io, file, model, &wide);
            if (wide.len == 0) return error.EmptyProviderIdentity;
            try evidence.served_model.set(wide.slice());
        }
    }
    const output = try fields.required("output");
    var array = try Array.init(io, file, output);
    var reader = try output_format.OutputMetadataReader.init(io, metadata.file, expected_items);
    var index: u64 = 0;
    while (try array.next()) |terminal_item| {
        const identity = try itemIdentity(io, file, terminal_item);
        const content_digest = try contentDigestRange(io, file, terminal_item);
        const record = try reader.nextItem() orelse return error.ContradictoryProviderOutput;
        if (record.ordinal != index or record.kind != identity.kind or
            !std.mem.eql(u8, &record.id_digest, &identity.id_digest) or
            !std.mem.eql(u8, &record.content_digest, &content_digest)) return error.ContradictoryProviderOutput;
        index += 1;
    }
    // The managed stream can omit the repeated items from response.completed.
    // Any nonempty terminal list must still match every streamed done item.
    if (index != 0 and (index != expected_items or try reader.nextItem() != null))
        return error.ContradictoryProviderOutput;
    if (try fields.get("usage")) |usage| {
        if (try rangeEquals(io, file, usage, "null")) return;
        const usage_fields = try readFields(io, file, usage, &.{"total_tokens"});
        _ = try usage_fields.get("total_tokens");
        try metadata.append(.{
            .tag = .usage,
            .start = usage.start,
            .length = usage.length,
            .content_digest = try contentDigestRange(io, file, usage),
            .usage_tokens = try usagePressure(io, file, usage.start, usage.length),
        });
    }
}

fn knownNonterminal(kind: []const u8) bool {
    const values = [_][]const u8{
        "response.created",
        "response.in_progress",
        "response.metadata",
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

const AnswerSelection = struct {
    ordinal: ?u64 = null,
    length: u64 = 0,
    digest: [32]u8,
    phased: bool = false,
    finals: u64 = 0,

    fn accept(self: *AnswerSelection, validation: ItemValidation, ordinal: u64, length: u64, digest: [32]u8) void {
        if (validation.phase != .unphased) self.phased = true;
        if (validation.phase == .final_answer) self.finals += 1;
        if (validation.phase == .final_answer or (!self.phased and validation.phase == .unphased)) {
            self.ordinal = ordinal;
            self.length = if (validation.non_whitespace) length else 0;
            self.digest = if (validation.non_whitespace) digest else protocol.contentDigest("");
        } else if (self.phased and self.finals == 0) {
            // Mixed phased/unphased text is visible, but only an explicit
            // final can terminate a phased response without Tool Calls.
            self.ordinal = null;
            self.length = 0;
            self.digest = protocol.contentDigest("");
        }
    }
};

fn processEvent(
    io: std.Io,
    file: std.Io.File,
    event: Range,
    metadata: *output_format.OutputMetadataWriter,
    added: *Added,
    completed: *bool,
    item_count: *u64,
    call_count: *u64,
    answer: *AnswerSelection,
    evidence: *Evidence,
    operation: output_format.ModelOperationKind,
    compaction_count: *u64,
    rejection: *Rejection,
) !void {
    rejection.* = .{ .stage = .event, .byte_offset = event.start };
    if (completed.*) return error.LateProviderOutput;
    var kind: protocol.Bounded(max_evidence_bytes) = .{};
    const fields = try readFields(io, file, event, &.{ "type", "output_index", "item", "response" });
    _ = try readString(io, file, try fields.required("type"), &kind);
    if (kind.eql("response.output_item.added")) {
        if (added.active) return error.ContradictoryProviderOutput;
        const index = try readIndex(io, file, try fields.required("output_index"));
        rejection.output_index = index;
        if (index != item_count.*) return error.ContradictoryProviderOutput;
        const identity = try itemIdentity(io, file, try fields.required("item"));
        added.* = .{ .active = true, .index = index, .kind = identity.kind, .id_digest = identity.id_digest };
        return;
    }
    if (kind.eql("response.output_item.done")) {
        const index = try readIndex(io, file, try fields.required("output_index"));
        rejection.stage = .item;
        rejection.output_index = index;
        if (index != item_count.*) return error.ContradictoryProviderOutput;
        const item = try fields.required("item");
        var message_hash = protocol.contentHasher();
        const previous_length = metadata.decoded_length;
        const validation = try validateItem(io, file, item, index, metadata, &message_hash, operation);
        if (added.active and (added.index != index or added.kind != validation.kind or
            !std.mem.eql(u8, &added.id_digest, &validation.id_digest))) return error.ContradictoryProviderOutput;
        added.active = false;
        if (validation.kind == .compaction) {
            compaction_count.* += 1;
            if (compaction_count.* > 1) return error.UnsupportedProviderOutput;
        }
        if (validation.kind == .message) {
            answer.accept(validation, index, metadata.decoded_length - previous_length, message_hash.finalResult());
        }
        if (validation.kind == .function_call) {
            call_count.* += 1;
        }
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
        rejection.stage = .response;
        // Each unmet completion requirement keeps its own reason so a saved
        // rejection says which one failed; all share the malformed code.
        if (added.active) return error.UnfinishedProviderOutputItem;
        if (item_count.* == 0) return error.MissingProviderOutputItems;
        if (answer.finals > 1) return error.MultipleFinalAnswers;
        if (operation == .assistant_response and answer.ordinal == null and call_count.* == 0) return error.MissingAssistantAnswer;
        if (operation == .compaction and compaction_count.* != 1) return error.MissingCompactionItem;
        try validateCompleted(io, file, try fields.required("response"), metadata, item_count.*, evidence);
        try metadata.sealForRead();
        completed.* = true;
        return;
    }
    if (kind.eql("error") or kind.eql("response.failed")) return streamError(io, file, event, kind.eql("response.failed"));
    if (kind.eql("response.incomplete")) {
        if (incompleteOverflow(io, file, event) catch |err| try malformedOverflow(err)) return error.ContextOverflow;
        return error.IncompleteProviderOutput;
    }
    if (!knownNonterminal(kind.slice())) return error.UnsupportedEventType;
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
    metadata: *output_format.OutputMetadataWriter,
    operation: output_format.ModelOperationKind,
    rejection: *Rejection,
    faults: Faults,
) !Validated {
    if (faults.metadata) metadata.fail_writes = true;
    var source = try FileSource.init(io, source_file, .{ .start = 0, .length = source_length });
    var data: ?Range = null;
    var data_is_done = false;
    var completed = false;
    var done_marker = false;
    var item_count: u64 = 0;
    var call_count: u64 = 0;
    var compaction_count: u64 = 0;
    var answer: AnswerSelection = .{ .digest = protocol.contentDigest("") };
    var evidence: Evidence = .{};
    var added: Added = .{};
    while (source.offset() < source.end) {
        rejection.* = .{ .byte_offset = source.offset() };
        // Keep what framing needs from the one buffered scan: the line's
        // head and its last two bytes. Event JSON is parsed separately.
        const line_start = source.offset();
        var head: [16]u8 = undefined;
        var tail: [2]u8 = .{ 0, 0 };
        while (try source.peek()) |byte| {
            const index = source.offset() - line_start;
            if (index < head.len) head[@intCast(index)] = byte;
            tail = .{ tail[1], byte };
            _ = try source.take();
            if (byte == '\n') break;
        }
        var line_end = source.offset();
        if (line_end > line_start and tail[1] == '\n') {
            line_end -= 1;
            if (line_end > line_start and tail[0] == '\r') line_end -= 1;
        } else if (line_end > line_start and tail[1] == '\r') line_end -= 1;
        const line = Range{ .start = line_start, .length = line_end - line_start };
        const shown = head[0..@intCast(@min(line.length, head.len))];
        if (line.length == 0) {
            if (data) |payload| {
                if (data_is_done) {
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
                        &call_count,
                        &answer,
                        &evidence,
                        operation,
                        &compaction_count,
                        rejection,
                    );
                }
                data = null;
            }
            continue;
        }
        if (std.mem.startsWith(u8, shown, "data:")) {
            if (data != null) return error.UnsupportedMultilineSseData;
            var skip: usize = "data:".len;
            if (shown.len > skip and shown[skip] == ' ') skip += 1;
            const length = line.length - skip;
            if (length == 0) return error.EmptySseData;
            data = .{ .start = line.start + skip, .length = length };
            data_is_done = length == "[DONE]".len and std.mem.eql(u8, shown[skip..], "[DONE]");
        } else if (!std.mem.startsWith(u8, shown, ":") and
            !std.mem.startsWith(u8, shown, "event:") and
            !std.mem.startsWith(u8, shown, "id:") and
            !std.mem.startsWith(u8, shown, "retry:"))
        {
            return error.MalformedSse;
        }
    }
    if (data != null) return error.IncompleteSseEvent;
    if (!completed) return error.ProviderConnectionClosed;
    return .{
        .item_count = item_count,
        .call_count = call_count,
        .answer_item_ordinal = answer.ordinal,
        .answer_length = answer.length,
        .answer_digest = answer.digest,
        .evidence = evidence,
    };
}

pub fn failureCode(err: anyerror) []const u8 {
    return switch (err) {
        error.ContextOverflow => "provider_context_overflow",
        error.TemporaryProviderFailure => "provider_temporary_error",
        error.PermanentProviderFailure => "provider_permanent_error",
        error.ProviderConnectionClosed => "provider_transport_failure",
        error.UnsupportedProviderOutput,
        error.UnsupportedItemStatus,
        error.UnsupportedAsyncCall,
        error.UnsupportedCallControl,
        error.UnsupportedCaller,
        error.UnsupportedMetadataAuthority,
        error.UnsupportedReasoningText,
        error.UnsupportedReasoningBlock,
        error.UnsupportedAnnotation,
        error.UnsupportedItemType,
        error.UnsupportedMessageRole,
        error.UnsupportedMessagePhase,
        error.UnsupportedContentBlock,
        error.UnsupportedResponseStatus,
        error.UnsupportedEventType,
        => "unsupported_provider_output",
        error.ContinuationUnavailable => "continuation_unavailable",
        error.MetadataScratchExhausted => "response_metadata_exhausted",
        error.InjectedMetadataFailure => "response_metadata_failed",
        else => "malformed_provider_output",
    };
}

fn testingObject(tmp: *std.testing.TmpDir, bytes: []const u8) !FileSource {
    const file = try tmp.dir.createFile(std.testing.io, "object", .{ .read = true });
    errdefer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
    return FileSource.init(std.testing.io, file, .{ .start = 0, .length = bytes.len });
}

const TestingValidation = struct { output: Validated, metadata_bytes: u64, first_item: output_format.OutputMetadataRecord };

fn validateTestingSse(tmp: *std.testing.TmpDir, bytes: []const u8, metadata_limit: u64) !TestingValidation {
    return validateTestingOperation(tmp, bytes, metadata_limit, .assistant_response);
}

fn validateTestingOperation(tmp: *std.testing.TmpDir, bytes: []const u8, metadata_limit: u64, operation: output_format.ModelOperationKind) !TestingValidation {
    var rejection: Rejection = .{};
    return validateTestingRejection(tmp, bytes, metadata_limit, operation, &rejection);
}

fn validateTestingRejection(tmp: *std.testing.TmpDir, bytes: []const u8, metadata_limit: u64, operation: output_format.ModelOperationKind, rejection: *Rejection) !TestingValidation {
    const source = try tmp.dir.createFile(std.testing.io, "provider-sse", .{ .read = true });
    errdefer source.close(std.testing.io);
    try source.writeStreamingAll(std.testing.io, bytes);
    try source.sync(std.testing.io);
    var root: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root);
    var used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var metadata = try output_format.OutputMetadataWriter.init(
        std.testing.io,
        root[0..root_length],
        "provider-test-metadata",
        .{ .used = &used, .limit = metadata_limit },
        false,
        &retained,
    );
    errdefer metadata.deinit();
    const validated = try validate(std.testing.io, source, bytes.len, &metadata, operation, rejection, .{});
    const metadata_bytes = used.load(.acquire);
    var reader = try output_format.OutputMetadataReader.init(std.testing.io, metadata.file, validated.item_count);
    const first_item = (try reader.nextItem()).?;
    metadata.deinit();
    source.close(std.testing.io);
    return .{ .output = validated, .metadata_bytes = metadata_bytes, .first_item = first_item };
}

test "explicit compaction requires one private anchor and rejects Actions" {
    const anchor = "{\"type\":\"compaction\",\"id\":\"c1\",\"encrypted_content\":\"opaque\",\"created_by\":\"retained\",\"future\":null}";
    const sse = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ anchor ++ "}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp\",\"status\":\"completed\",\"output\":[]}}\n\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try validateTestingOperation(&tmp, sse, 4096, .compaction);
    try std.testing.expectEqual(@as(u64, 1), result.output.item_count);
    try std.testing.expectEqual(@as(u64, 0), result.output.call_count);
    try std.testing.expectEqual(output_format.OutputItemKind.compaction, result.first_item.kind);
    try std.testing.expectEqual(protocol.contentDigest(anchor), result.first_item.content_digest);
    const notification = "data: {\"type\":\"response.metadata\",\"metadata\":{}}\n\n";
    const with_metadata = try validateTestingOperation(&tmp, notification ++ sse, 4096, .compaction);
    try std.testing.expectEqual(@as(u64, 1), with_metadata.output.item_count);
    try std.testing.expectEqual(protocol.contentDigest(anchor), with_metadata.first_item.content_digest);
    try std.testing.expectError(error.UnsupportedProviderOutput, validateTestingSse(&tmp, sse, 4096));
    try std.testing.expectEqualStrings("unsupported_provider_output", failureCode(error.UnsupportedProviderOutput));
}

test "compaction validates opaque windows added identity and complete terminal agreement" {
    const encrypted_bytes = &@as([8193]u8, @splat('x'));
    const anchor = try std.testing.allocator.print("{{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"{s}\",\"future\":{{\"nested\":[true,null]}}}}", .{encrypted_bytes});
    defer std.testing.allocator.free(anchor);
    const tail = "{\"type\":\"message\",\"id\":\"tail\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"after anchor\"}]}";
    const sse = try std.testing.allocator.print(
        "data: {{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"\"}}}}\n\n" ++
            "data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n" ++
            "data: {{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{s}}}\n\n" ++
            "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"r\",\"status\":\"completed\",\"output\":[{s},{s}]}}}}\n\n",
        .{ anchor, tail, anchor, tail },
    );
    defer std.testing.allocator.free(sse);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try validateTestingOperation(&tmp, sse, 4096, .compaction);
    try std.testing.expectEqual(@as(u64, 2), result.output.item_count);
    try std.testing.expectEqual(protocol.contentDigest(anchor), result.first_item.content_digest);
    try std.testing.expectEqual(@as(u64, "after anchor".len), result.output.answer_length);
}

test "compaction rejects missing double malformed unknown and Action candidates" {
    const cases = .{
        .{ "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"\"}", error.ContinuationUnavailable },
        .{ "{\"type\":\"compaction\",\"id\":\"c\"}", error.ContinuationUnavailable },
        .{ "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":null}", error.ExpectedJsonString },
        .{ "{\"type\":\"compaction_summary\",\"id\":\"c\",\"encrypted_content\":\"x\"}", error.UnsupportedItemType },
        .{ "{\"type\":\"function_call\",\"id\":\"c\",\"name\":\"bash\",\"call_id\":\"call\",\"arguments\":\"{}\"}", error.UnsupportedProviderOutput },
        .{ "{\"type\":\"message\",\"id\":\"c\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"not an anchor\"}]}", error.MissingCompactionItem },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (cases) |case| {
        const sse = try std.testing.allocator.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\ndata: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}}}\n\n", .{case[0]});
        defer std.testing.allocator.free(sse);
        try std.testing.expectError(case[1], validateTestingOperation(&tmp, sse, 4096, .compaction));
    }
    const anchor = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"x\"}";
    const duplicate = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ anchor ++ "}\n\ndata: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ anchor ++ "}\n\n";
    try std.testing.expectError(error.UnsupportedProviderOutput, validateTestingOperation(&tmp, duplicate, 4096, .compaction));
    const disagreement = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ anchor ++ "}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"different\"}]}}\n\n";
    try std.testing.expectError(error.ContradictoryProviderOutput, validateTestingOperation(&tmp, disagreement, 4096, .compaction));
}

test "SSE line framing accepts CRLF, field lines and DONE, and rejects malformed lines" {
    const item = "{\"type\":\"message\",\"id\":\"a\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}";
    const done = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ item ++ "}";
    const completed = "{\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[" ++ item ++ "]}}";
    const accepted = [_][]const u8{
        "data: " ++ done ++ "\n\ndata: " ++ completed ++ "\n\n",
        "data: " ++ done ++ "\r\n\r\ndata: " ++ completed ++ "\r\n\r\n",
        "data:" ++ done ++ "\n\ndata:" ++ completed ++ "\n\n",
        ": comment\nevent: x\nid: 1\nretry: 5\ndata: " ++ done ++ "\n\ndata: " ++ completed ++ "\n\ndata: [DONE]\n\n",
        "data: " ++ done ++ "\n\ndata: " ++ completed ++ "\r\n\r\ndata:[DONE]\r\n\r\n",
        // A final carriage return without a newline still ends the line.
        "data: " ++ done ++ "\n\ndata: " ++ completed ++ "\n\r",
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (accepted) |stream| {
        const result = try validateTestingSse(&tmp, stream, 4096);
        try std.testing.expectEqual(@as(u64, 2), result.output.answer_length);
    }
    const rejected = [_]struct { anyerror, []const u8 }{
        .{ error.MalformedSse, "bogus: x\ndata: " ++ done ++ "\n\ndata: " ++ completed ++ "\n\n" },
        .{ error.MalformedSse, "dat: " ++ done ++ "\n\n" },
        .{ error.EmptySseData, "data:\n\n" },
        .{ error.EmptySseData, "data: \r\n\r\n" },
        .{ error.UnsupportedMultilineSseData, "data: " ++ done ++ "\ndata: " ++ done ++ "\n\n" },
        .{ error.ContradictoryProviderOutput, "data: " ++ done ++ "\n\ndata: [DONE]\n\n" },
        .{ error.LateProviderOutput, "data: " ++ done ++ "\n\ndata: " ++ completed ++ "\n\ndata: [DONE]\n\ndata: " ++ done ++ "\n\n" },
    };
    for (rejected) |case| try std.testing.expectError(case[0], validateTestingSse(&tmp, case[1], 4096));
}

test "synthetic gpt-6-luna shaped commentary interleaves calls and selects final answer" {
    // Synthetic contract fixture, not a recovered live provider capture.
    const before = "{\"type\":\"message\",\"id\":\"before\",\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"Inspecting files\"}]}";
    const call = "{\"type\":\"function_call\",\"id\":\"call\",\"name\":\"bash\",\"call_id\":\"k\",\"arguments\":\"{}\"}";
    const between = "{\"type\":\"message\",\"id\":\"between\",\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"Checking results\"}]}";
    const final = "{\"type\":\"message\",\"id\":\"final\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"Only this answer\"}]}";
    const stream = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ before ++ "}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ call ++ "}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":2,\"item\":" ++ between ++ "}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":3,\"item\":" ++ final ++ "}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"synthetic-luna\",\"model\":\"gpt-6-luna\",\"status\":\"completed\",\"output\":[" ++ before ++ "," ++ call ++ "," ++ between ++ "," ++ final ++ "]}}\n\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const accepted = try validateTestingSse(&tmp, stream, 64 * 1024);
    try std.testing.expectEqual(@as(u64, 4), accepted.output.item_count);
    try std.testing.expectEqual(@as(u64, 1), accepted.output.call_count);
    try std.testing.expectEqual(@as(u64, "Only this answer".len), accepted.output.answer_length);
    try std.testing.expectEqual(protocol.contentDigest("Only this answer"), accepted.output.answer_digest);
}

test "completed empty assistant answers are valid with or without a final phase" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "", ",\"phase\":\"final_answer\"" }) |phase| {
        for ([_]struct { encoded: []const u8, answer: []const u8 }{
            .{ .encoded = "", .answer = "" },
            .{ .encoded = " \\t\\r\\n", .answer = "" },
            .{ .encoded = "\u{85}\u{a0}\u{1680}\u{2000}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}", .answer = "" },
            .{ .encoded = "\\u00a0\\u2003\\u000b\\u000c", .answer = "" },
            .{ .encoded = " \\té\\n ", .answer = " \té\n " },
            .{ .encoded = "\\u200b", .answer = "\u{200b}" },
            .{ .encoded = "\\u0000", .answer = "\x00" },
        }) |case| {
            const item = try std.testing.allocator.print(
                "{{\"type\":\"message\",\"id\":\"empty\",\"role\":\"assistant\"{s},\"content\":[{{\"type\":\"output_text\",\"text\":\"{s}\"}}]}}",
                .{ phase, case.encoded },
            );
            defer std.testing.allocator.free(item);
            const sse = try std.testing.allocator.print(
                "data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n" ++
                    "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"r\",\"status\":\"completed\",\"output\":[{s}]}}}}\n\n",
                .{ item, item },
            );
            defer std.testing.allocator.free(sse);
            const accepted = try validateTestingSse(&tmp, sse, 4096);
            try std.testing.expectEqual(@as(u64, 1), accepted.output.item_count);
            try std.testing.expectEqual(@as(u64, 0), accepted.output.call_count);
            try std.testing.expectEqual(@as(?u64, 0), accepted.output.answer_item_ordinal);
            try std.testing.expectEqual(@as(u64, case.answer.len), accepted.output.answer_length);
            try std.testing.expectEqual(protocol.contentDigest(case.answer), accepted.output.answer_digest);
        }
    }
}

test "message phases select one answer without dropping or concatenating text" {
    const cases = [_]struct { first: []const u8, second: []const u8, answer: ?[]const u8 = null, failure: ?anyerror = null }{
        .{ .first = "", .second = "", .answer = "second é" },
        .{ .first = ",\"phase\":null", .second = "", .answer = "second é" },
        .{ .first = ",\"phase\":\"commentary\"", .second = ",\"phase\":\"final_answer\"", .answer = "second é" },
        .{ .first = "", .second = ",\"phase\":\"final_answer\"", .answer = "second é" },
        .{ .first = ",\"phase\":\"final_answer\"", .second = ",\"phase\":\"commentary\"", .answer = "first" },
        .{ .first = ",\"phase\":\"final_answer\"", .second = "", .answer = "first" },
        .{ .first = ",\"phase\":\"commentary\"", .second = "", .failure = error.MissingAssistantAnswer },
        .{ .first = "", .second = ",\"phase\":\"commentary\"", .failure = error.MissingAssistantAnswer },
        .{ .first = ",\"phase\":\"final_answer\"", .second = ",\"phase\":\"final_answer\"", .failure = error.MultipleFinalAnswers },
        .{ .first = ",\"phase\":\"analysis\"", .second = "", .failure = error.UnsupportedMessagePhase },
        .{ .first = ",\"phase\":42", .second = "", .failure = error.ExpectedJsonString },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases) |case| {
        const sse = try std.testing.allocator.print(
            "data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{{\"type\":\"message\",\"id\":\"a\",\"role\":\"assistant\"{s},\"content\":[{{\"type\":\"output_text\",\"text\":\"first\"}}]}}}}\n\n" ++
                "data: {{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{{\"type\":\"message\",\"id\":\"b\",\"role\":\"assistant\"{s},\"content\":[{{\"type\":\"output_text\",\"text\":\"second é\"}}]}}}}\n\n" ++
                "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}}}\n\n",
            .{ case.first, case.second },
        );
        defer std.testing.allocator.free(sse);
        if (case.failure) |failure| {
            try std.testing.expectError(failure, validateTestingSse(&tmp, sse, 64 * 1024));
        } else {
            const accepted = try validateTestingSse(&tmp, sse, 64 * 1024);
            try std.testing.expectEqual(@as(u64, 2), accepted.output.item_count);
            try std.testing.expectEqual(@as(u64, case.answer.?.len), accepted.output.answer_length);
            try std.testing.expectEqual(protocol.contentDigest(case.answer.?), accepted.output.answer_digest);
            try std.testing.expectEqual(@as(?u64, if (std.mem.eql(u8, case.answer.?, "first")) 0 else 1), accepted.output.answer_item_ordinal);
        }
    }
}

test "completion gate saves which requirement failed at the completed event" {
    const message = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"a\"}]}";
    const final = "{\"type\":\"message\",\"id\":\"f\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"b\"}]}";
    const reasoning = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"x\",\"summary\":[]}";
    const call = "{\"type\":\"function_call\",\"id\":\"c\",\"name\":\"bash\",\"call_id\":\"k\",\"arguments\":\"{}\"}";
    const done = "data: {\"type\":\"response.output_item.done\",\"output_index\":";
    const completed = "{\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}";
    const cases = [_]struct { anyerror, output_format.ModelOperationKind, []const u8 }{
        .{ error.UnfinishedProviderOutputItem, .assistant_response, done ++ "0,\"item\":" ++ message ++ "}\n\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":" ++ call ++ "}\n\n" },
        .{ error.MissingProviderOutputItems, .assistant_response, ": keepalive\r\n\r\n" },
        .{ error.MultipleFinalAnswers, .assistant_response, done ++ "0,\"item\":" ++ final ++ "}\r\n\r\n" ++ done ++ "1,\"item\":" ++ final ++ "}\r\n\r\n" },
        .{ error.MissingAssistantAnswer, .assistant_response, done ++ "0,\"item\":" ++ reasoning ++ "}\n\n" },
        .{ error.MissingCompactionItem, .compaction, done ++ "0,\"item\":" ++ final ++ "}\n\n" },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases) |case| {
        const sse = try std.testing.allocator.print("{s}data: {s}\n\n", .{ case[2], completed });
        defer std.testing.allocator.free(sse);
        var rejection: Rejection = .{};
        try std.testing.expectError(case[0], validateTestingRejection(&tmp, sse, 4096, case[1], &rejection));
        try std.testing.expectEqual(.response, rejection.stage);
        try std.testing.expectEqual(@as(u64, std.mem.indexOf(u8, sse, completed).?), rejection.byte_offset);
        try std.testing.expectEqual(@as(?u64, null), rejection.output_index);
        try std.testing.expectEqualStrings("malformed_provider_output", failureCode(case[0]));
        var buffer: [512]u8 = undefined;
        var expected: [512]u8 = undefined;
        try std.testing.expectEqualStrings(
            try std.fmt.bufPrint(&expected, "{{\"reason\":\"{s}\",\"stage\":\"response\",\"byte_offset\":\"{d}\",\"output_index\":null}}", .{ @errorName(case[0]), rejection.byte_offset }),
            rejection.format(case[0], &buffer),
        );
    }
}

test "provider completion treats null usage as absent and rejects malformed optional evidence" {
    const done = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}}\n\n";
    const terminal = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[]";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const absent = try validateTestingSse(&tmp, done ++ terminal ++ "}}\n\n", 4096);
    const nullable = try validateTestingSse(&tmp, done ++ terminal ++ ",\"usage\":null}}\n\n", 4096);
    try std.testing.expectEqual(absent.metadata_bytes, nullable.metadata_bytes);
    try std.testing.expectEqual(@as(u64, 2), nullable.output.answer_length);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest("ok"), &nullable.output.answer_digest);
    inline for (.{ ",\"usage\":[]", ",\"usage\":123", ",\"model\":123", ",\"model\":null,\"model\":\"other\"", ",\"usage\":null,\"usage\":{}" }) |suffix| {
        const bytes = done ++ terminal ++ suffix ++ "}}\n\n";
        if (validateTestingSse(&tmp, bytes, 4096)) |_| {
            return error.TestExpectedError;
        } else |err| {
            try std.testing.expectEqualStrings("malformed_provider_output", failureCode(err));
        }
    }
}

test "context overflow requires exact valid provider code over HTTP and SSE" {
    const cases = .{
        .{ "{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"too long\"}}", true },
        .{ "{\"error\":{\"code\":\"context_length_exceeded_extra\"}}", false },
        .{ "{\"error\":{\"message\":\"context_length_exceeded\"}}", false },
        .{ "{\"error\":{\"code\":\"context_length_exceeded\"},\"late\":[1,]}", false },
        .{ "{\"error\":{\"code\":\"context_length_exceeded\",\"code\":\"other\"}}", false },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (cases) |case| {
        const source = try testingObject(&tmp, case[0]);
        defer source.file.close(std.testing.io);
        try std.testing.expectEqual(case[1], try contextOverflow(std.testing.io, source.file, case[0].len, 400));
        try std.testing.expect(!try contextOverflow(std.testing.io, source.file, case[0].len, 200));
    }
    // A missing sealed byte is capture failure, not a malformed remote body.
    const short = try testingObject(&tmp, "{}");
    defer short.file.close(std.testing.io);
    try std.testing.expectError(error.ShortSealedRead, contextOverflow(std.testing.io, short.file, 3, 503));
    const failures = [_][]const u8{
        "{\"type\":\"error\",\"code\":\"context_length_exceeded\"}",
        "{\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"code\":\"context_length_exceeded\"}}}",
        "{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"context_length_exceeded\"}}}",
    };
    for (failures) |failure| {
        const sse = try std.testing.allocator.print("data: {s}\n\n", .{failure});
        defer std.testing.allocator.free(sse);
        try std.testing.expectError(error.ContextOverflow, validateTestingSse(&tmp, sse, 4096));
    }
    const lookalikes = [_]struct { anyerror, []const u8 }{
        .{ error.TemporaryProviderFailure, "{\"type\":\"error\",\"code\":\"context_length_exceeded_extra\"}" },
        .{ error.TemporaryProviderFailure, "{\"type\":\"error\",\"message\":\"context_length_exceeded\"}" },
        .{ error.TemporaryProviderFailure, "{\"type\":\"error\",\"code\":\"other\",\"error\":{\"code\":\"context_length_exceeded\"}}" },
        .{ error.IncompleteProviderOutput, "{\"type\":\"response.failed\",\"response\":{\"status\":\"completed\",\"error\":{\"code\":\"context_length_exceeded\"}}}" },
        .{ error.TemporaryProviderFailure, "{\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"message\":\"context_length_exceeded\"}}}" },
        .{ error.IncompleteProviderOutput, "{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}" },
        .{ error.DuplicateJsonField, "{\"type\":\"error\",\"code\":\"context_length_exceeded\",\"code\":\"other\"}" },
    };
    for (lookalikes) |case| {
        const sse = try std.testing.allocator.print("data: {s}\n\n", .{case[1]});
        defer std.testing.allocator.free(sse);
        try std.testing.expectError(case[0], validateTestingSse(&tmp, sse, 4096));
    }
}

fn testingReasoningSse(reasoning: []const u8, terminal_reasoning: []const u8) ![]u8 {
    const answer = "{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}";
    return std.testing.allocator.print(
        "data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n" ++
            "data: {{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{s}}}\n\n" ++
            "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"response\",\"status\":\"completed\",\"output\":[{s},{s}]}}}}\n\n",
        .{ reasoning, answer, terminal_reasoning, answer },
    );
}

test "provider proposal identity uses decoded content domain" {
    const sse = "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"p-é\\n\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"p-\\u00e9\\n\",\"name\":\"bash\",\"call_id\":\"c1\",\"arguments\":\"{}\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"response\",\"status\":\"completed\",\"output\":[]}}\n\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const accepted = try validateTestingSse(&tmp, sse, 4096);
    try std.testing.expectEqual(@as(u64, 1), accepted.output.call_count);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest("p-é\n"), &accepted.first_item.id_digest);
}

test "provider reasoning strings preserve raw items across evidence and file window boundaries" {
    const values = .{
        &@as([255]u8, @splat('a')),
        &@as([256]u8, @splat('b')),
        &@as([257]u8, @splat('c')),
        @as([8192 * 6]u8, @bitCast(@as([8192][6]u8, @splat("\\u0041".*)))) ++ "\\u00e9\\u4e2d\\uD83D\\uDE42",
    };
    inline for (values) |value| {
        const reasoning = try std.testing.allocator.print(
            "{{\"type\":\"reasoning\",\"id\":\"r1\",\"encrypted_content\":\"{s}\",\"summary\":[{{\"type\":\"summary_text\",\"text\":\"{s}\"}}]," ++
                "\"content\":[{{\"type\":\"reasoning_text\",\"text\":\"{s}\"}}],\"created_by\":\"kept\",\"future\":{{\"raw\":null}}}}",
            .{ value, value, value },
        );
        defer std.testing.allocator.free(reasoning);
        const sse = try testingReasoningSse(reasoning, reasoning);
        defer std.testing.allocator.free(sse);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const accepted = try validateTestingSse(&tmp, sse, 64 * 1024);
        try std.testing.expectEqual(@as(u64, 2), accepted.output.item_count);
        try std.testing.expectEqual(@as(u64, 0), accepted.output.call_count);
        try std.testing.expectEqual(@as(u64, 2), accepted.output.answer_length);
        try std.testing.expectEqualSlices(u8, &protocol.contentDigest("ok"), &accepted.output.answer_digest);
        const item = accepted.first_item;
        try std.testing.expectEqual(output_format.OutputItemKind.reasoning, item.kind);
        try std.testing.expectEqual(@as(u64, 0), item.ordinal);
        try std.testing.expectEqual(reasoning.len, item.length);
        try std.testing.expectEqualStrings(reasoning, sse[@intCast(item.start)..][0..@intCast(item.length)]);
        // Expected complete raw bytes include response-only and unknown fields,
        // not a decoded or normalized spelling of the reasoning strings.
        try std.testing.expectEqualSlices(u8, &protocol.contentDigest(reasoning), &item.content_digest);
    }
}

test "provider reasoning validation rejects wrong types duplicates and malformed suffixes" {
    const prefix = &@as([257]u8, @splat('a'));
    const cases = .{
        .{ "\"summary\":[]", error.ContinuationUnavailable },
        .{ "\"encrypted_content\":\"\"", error.ContinuationUnavailable },
        .{ "\"encrypted_content\":null", error.ExpectedJsonString },
        .{ "\"encrypted_content\":17", error.ExpectedJsonString },
        .{ "\"encrypted_content\":{}", error.ExpectedJsonString },
        .{ "\"encrypted_content\":\"opaque\",\"text\":null", error.UnsupportedReasoningText },
        .{ "\"encrypted_content\":\"opaque\",\"status\":\"in_progress\"", error.UnsupportedItemStatus },
        .{ "\"encrypted_content\":\"opaque\",\"encr\\u0079pted_content\":\"second\"", error.DuplicateJsonField },
        .{ "\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"summary_text\",\"text\":null}]", error.ExpectedJsonString },
        .{ "\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"reasoning_text\",\"text\":{}}]", error.ExpectedJsonString },
        .{ "\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"reasoning_text\",\"text\":\"x\"}]", error.UnsupportedReasoningBlock },
        .{ "\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"summary_text\",\"text\":\"x\"}]", error.UnsupportedReasoningBlock },
        .{ "\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"summary_text\"}]", error.MissingProviderField },
        .{ "\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"reasoning_text\",\"text\":\"a\",\"te\\u0078t\":\"b\"}]", error.DuplicateJsonField },
        .{ "\"encrypted_content\":\"" ++ prefix ++ "\\q\"", error.InvalidJsonEscape },
        .{ "\"encrypted_content\":\"" ++ prefix ++ "\xff\"", error.InvalidJsonUtf8 },
        .{ "\"encrypted_content\":\"" ++ prefix ++ "\xe2\"", error.InvalidJsonUtf8 },
        .{ "\"encrypted_content\":\"" ++ prefix ++ "\\uD800x\"", error.InvalidJsonSurrogate },
        .{ "\"encrypted_content\":\"" ++ prefix ++ "\\uDC00\"", error.InvalidJsonSurrogate },
        .{ "\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"" ++ prefix ++ "\\uD800\\u0041\"}]", error.InvalidJsonSurrogate },
        .{ "\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"reasoning_text\",\"text\":\"" ++ prefix ++ "\\q\"}]", error.InvalidJsonEscape },
        .{ "\"encrypted_content\":\"opaque\",\"future\":[1,]", error.InvalidJsonValue },
    };
    inline for (cases) |case| {
        const reasoning = try std.testing.allocator.print("{{\"type\":\"reasoning\",\"id\":\"r1\",{s}}}", .{case[0]});
        defer std.testing.allocator.free(reasoning);
        const sse = try testingReasoningSse(reasoning, reasoning);
        defer std.testing.allocator.free(sse);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try std.testing.expectError(case[1], validateTestingSse(&tmp, sse, 64 * 1024));
    }

    // Nonempty means decoded bytes, not visible characters; summary/content
    // text may be empty and escaped consequential keys keep their meaning.
    const valid = "{\"type\":\"reasoning\",\"id\":\"r1\",\"encr\\u0079pted_content\":\"\\u0000\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"\"}],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"\"}]}";
    const sse = try testingReasoningSse(valid, valid);
    defer std.testing.allocator.free(sse);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(@as(u64, 2), (try validateTestingSse(&tmp, sse, 64 * 1024)).output.item_count);
}

test "provider added identity permits incomplete content but terminal agreement requires exact bytes" {
    const done = "{\"type\":\"reasoning\",\"id\":\"r1\",\"status\":\"completed\",\"encrypted_content\":\"opaque\",\"future\":\"one\"}";
    const added_items = .{
        .{ "{\"type\":\"reasoning\",\"id\":\"r1\",\"status\":\"in_progress\",\"encrypted_content\":\"\"}", false },
        .{ "{\"type\":\"reasoning\",\"id\":\"other\"}", true },
        .{ "{\"type\":\"message\",\"id\":\"r1\"}", true },
    };
    const tail = try testingReasoningSse(done, done);
    defer std.testing.allocator.free(tail);
    inline for (added_items) |case| {
        const sse = try std.testing.allocator.print(
            "data: {{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{s}}}\n\n{s}",
            .{ case[0], tail },
        );
        defer std.testing.allocator.free(sse);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        if (case[1]) {
            try std.testing.expectError(error.ContradictoryProviderOutput, validateTestingSse(&tmp, sse, 64 * 1024));
        } else {
            const accepted = try validateTestingSse(&tmp, sse, 64 * 1024);
            try std.testing.expectEqual(@as(u64, 2), accepted.output.item_count);
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest(done), &accepted.first_item.content_digest);
        }
    }

    const changed_terminal = .{
        "{\"type\":\"reasoning\",\"id\":\"r1\",\"status\":\"completed\",\"encrypted_content\":\"different\",\"future\":\"one\"}",
        "{\"type\":\"reasoning\",\"id\":\"r1\",\"status\":\"completed\",\"encrypted_content\":\"o\\u0070aque\",\"future\":\"one\"}",
        "{\"type\":\"reasoning\",\"id\":\"r1\",\"status\":\"completed\",\"encrypted_content\":\"opaque\",\"future\":\"two\"}",
    };
    inline for (changed_terminal) |terminal| {
        const sse = try testingReasoningSse(done, terminal);
        defer std.testing.allocator.free(sse);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try std.testing.expectError(error.ContradictoryProviderOutput, validateTestingSse(&tmp, sse, 64 * 1024));
    }
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
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ message ++ "}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"late\",\"status\":\"completed\",\"output\":[]}}\n\n";
    var order_tmp = std.testing.tmpDir(.{});
    defer order_tmp.cleanup();
    const late = try validateTestingSse(&order_tmp, late_message, 64 * 1024);
    try std.testing.expectEqual(protocol.contentDigest("late"), late.output.answer_digest);
}

test "empty terminal output uses complete streamed items but partial terminal output contradicts them" {
    const first = "{\"type\":\"function_call\",\"id\":\"item-1\",\"name\":\"bash\",\"call_id\":\"call-1\",\"arguments\":\"{}\"}";
    const second = "{\"type\":\"function_call\",\"id\":\"item-2\",\"name\":\"bash\",\"call_id\":\"call-2\",\"arguments\":\"{}\"}";
    const items = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ first ++ "}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ second ++ "}\n\n";
    const terminal = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"response-1\",\"status\":\"completed\",\"output\":";
    var empty_tmp = std.testing.tmpDir(.{});
    defer empty_tmp.cleanup();
    const accepted = try validateTestingSse(&empty_tmp, items ++ terminal ++ "[]}}\n\n", 64 * 1024);
    try std.testing.expectEqual(@as(u64, 2), accepted.output.item_count);
    try std.testing.expectEqual(@as(u64, 2), accepted.output.call_count);

    var partial_tmp = std.testing.tmpDir(.{});
    defer partial_tmp.cleanup();
    try std.testing.expectError(error.ContradictoryProviderOutput, validateTestingSse(&partial_tmp, items ++ terminal ++ "[" ++ first ++ "]}}\n\n", 64 * 1024));

    var missing_tmp = std.testing.tmpDir(.{});
    defer missing_tmp.cleanup();
    try std.testing.expectError(error.MissingProviderOutputItems, validateTestingSse(&missing_tmp, terminal ++ "[]}}\n\n", 64 * 1024));
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
        const sse = try std.testing.allocator.print(
            "data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n" ++
                "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"response-1\",\"status\":\"completed\",\"output\":[{s}]}}}}\n\n",
            .{ case[0], case[0] },
        );
        defer std.testing.allocator.free(sse);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        if (case[1]) {
            if (validateTestingSse(&tmp, sse, 64 * 1024)) |_| {
                return error.ExpectedRejection;
            } else |err| {
                try std.testing.expectEqualStrings("unsupported_provider_output", failureCode(err));
            }
        } else {
            const accepted = try validateTestingSse(&tmp, sse, 64 * 1024);
            try std.testing.expectEqual(@as(u64, 1), accepted.output.call_count);
        }
    }
}

test "metadata notification is not output or completion authority" {
    // Minimized from the authorized 2026-10-17 Codex probe. Metadata arrived
    // before the completed message; only the done item supplied its answer.
    const notification = "data: {\"type\":\"response.metadata\",\"sequence_number\":5,\"response_id\":\"synthetic\",\"metadata\":{\"openai_chatgpt_moderation_metadata\":{\"prompt\":{},\"generation\":{},\"tool_call\":{},\"tool_response\":{}}}}\n\n";
    const item = "{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"OK\",\"annotations\":[]}],\"phase\":\"final_answer\"}";
    const done = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ item ++ "}\n\n";
    const terminal = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"response\",\"status\":\"completed\",\"output\":[" ++ item ++ "]}}\n\n";
    for ([_][]const u8{ notification ++ done ++ terminal, done ++ notification ++ terminal }) |sse| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const accepted = try validateTestingSse(&tmp, sse, 4096);
        try std.testing.expectEqual(@as(u64, 1), accepted.output.item_count);
        try std.testing.expectEqual(@as(u64, 0), accepted.output.call_count);
        try std.testing.expectEqual(@as(u64, 2), accepted.output.answer_length);
        try std.testing.expectEqualSlices(u8, &protocol.contentDigest("OK"), &accepted.output.answer_digest);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.ProviderConnectionClosed, validateTestingSse(&tmp, notification, 4096));
    try std.testing.expectError(error.MissingProviderOutputItems, validateTestingSse(&tmp, notification ++ terminal, 4096));
    try std.testing.expectError(error.LateProviderOutput, validateTestingSse(&tmp, done ++ terminal ++ notification, 4096));
    try std.testing.expectError(error.UnsupportedEventType, validateTestingSse(&tmp, "data: {\"type\":\"response.metadata.future\"}\n\n" ++ done ++ terminal, 4096));
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
    const input = "{\"unknown\":\"" ++ @as([protocol.content_window_bytes * 4]u8, @splat('x')) ++
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
        .{ "{\"type\":1,\"unknown\":" ++ @as([protocol.max_json_depth + 1]u8, @splat('[')) ++ "0" ++ @as([protocol.max_json_depth + 1]u8, @splat(']')) ++ "}", error.JsonTooDeep },
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
    try std.testing.expectError(error.UnsupportedMetadataAuthority, validateMetadataAuthority(
        std.testing.io,
        source.file,
        .{ .start = 0, .length = source.end },
    ));
}

test "provider authority metadata rejects every supported item on acceptance and replay" {
    const prefixes = .{
        "{\"type\":\"function_call\",\"id\":\"c\",\"name\":\"bash\",\"call_id\":\"call\",\"arguments\":\"{}\"",
        "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]",
        "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\"",
        "{\"type\":\"compaction\",\"id\":\"b\",\"encrypted_content\":\"opaque\"",
    };
    inline for (prefixes, 0..) |prefix, index| {
        inline for (.{ "cell_id", "cell_\\u0069d", "executed_tool_calls", "executed_tool_\\u0063alls", "tool_calls_complete", "tool_calls_\\u0063omplete", "future" }) |key| {
            const item = try std.testing.allocator.print("{s},\"internal_chat_message_metadata_passthrough\":{{\"{s}\":null}}}}", .{ prefix, key });
            defer std.testing.allocator.free(item);
            const sse = if (index == 2) try testingReasoningSse(item, item) else try std.testing.allocator.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n" ++
                "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"response\",\"status\":\"completed\",\"output\":[{s}]}}}}\n\n", .{ item, item });
            defer std.testing.allocator.free(sse);
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const purpose: output_format.ModelOperationKind = if (index == 3) .compaction else .assistant_response;
            var source = try testingObject(&tmp, item);
            defer source.file.close(std.testing.io);
            if (comptime std.mem.eql(u8, key, "future")) {
                _ = try validateTestingOperation(&tmp, sse, 4096, purpose);
                try validateReplay(std.testing.io, source.file, item.len);
            } else {
                try std.testing.expectError(error.UnsupportedMetadataAuthority, validateTestingOperation(&tmp, sse, 4096, purpose));
                try std.testing.expectError(error.ContinuationUnavailable, validateReplay(std.testing.io, source.file, item.len));
            }
        }
    }
}

test "fuzz provider decoded answers and rejection across file windows" {
    try std.testing.fuzz({}, fuzzAnswer, .{ .corpus = &.{
        "\xfd\x0f\x00\x00\x00\x00\x00\x00",
        "\xfe\x0f\x00\x00\x00\x00\x00\x00",
        "\xff\x0f\x00\x00\x00\x00\x00\x00",
        "\x00\x10\x00\x00\x00\x00\x00\x00",
        "\xff\x1f\x00\x00\x00\x00\x00\x00",
    } });
}

fn fuzzAnswer(_: void, smith: *std.testing.Smith) !void {
    var text_buffer: [2 * protocol.content_window_bytes + 128]u8 = undefined;
    var text = std.Io.Writer.fixed(&text_buffer);
    const padding = smith.valueRangeAtMost(u16, 0, 2 * protocol.content_window_bytes);
    try text.splatByteAll('p', padding);
    // Always exercise controls, multibyte UTF-8 and surrogate-pair escaping;
    // generated scalars vary their positions around the file-window boundary.
    try text.writeAll("\x00\"\n\\€𐀀");
    const count = smith.valueRangeAtMost(u8, 0, 16);
    for (0..count) |_| {
        var scalar = smith.valueRangeAtMost(u21, 0, 0x10f7ff);
        if (scalar >= 0xd800) scalar += 0x800;
        var encoded: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(scalar, &encoded);
        try text.writeAll(encoded[0..length]);
    }
    const expected_digest = protocol.contentDigest(text.buffered());
    inline for (.{ false, true }) |escape_unicode| {
        var item_buffer: [2 * protocol.content_window_bytes + 512]u8 = undefined;
        var item = std.Io.Writer.fixed(&item_buffer);
        try item.writeAll("{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
        try std.json.Stringify.value(text.buffered(), .{ .escape_unicode = escape_unicode }, &item);
        try item.writeAll("}]}");

        var stream_buffer: [2 * (2 * protocol.content_window_bytes + 512) + 512]u8 = undefined;
        var stream = std.Io.Writer.fixed(&stream_buffer);
        try stream.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n" ++
            "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"response\",\"status\":\"completed\",\"output\":[{s}]}}}}\n\n", .{ item.buffered(), item.buffered() });
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const accepted = try validateTestingSse(&tmp, stream.buffered(), 4096);
        try std.testing.expectEqual(@as(u64, 1), accepted.output.item_count);
        try std.testing.expectEqual(@as(u64, 0), accepted.output.call_count);
        try std.testing.expectEqual(@as(u64, text.buffered().len), accepted.output.answer_length);
        try std.testing.expectEqualSlices(u8, &expected_digest, &accepted.output.answer_digest);
        // Syntax errors after valid content cannot become accepted prefixes.
        try std.testing.expectError(error.IncompleteSseEvent, validateTestingSse(&tmp, stream.buffered()[0 .. stream.buffered().len - 2], 4096));
        stream = .fixed(&stream_buffer);
        try stream.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s},\"late\":\"\xff\"}}\n\n", .{item.buffered()});
        try std.testing.expectError(error.InvalidJsonUtf8, validateTestingSse(&tmp, stream.buffered(), 4096));
    }
}
