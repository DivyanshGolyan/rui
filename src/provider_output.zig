const std = @import("std");
const named_scratch = @import("named_scratch.zig");
const protocol = @import("protocol.zig");
const output_format = @import("output_format.zig");
const transport_policy = @import("transport_policy.zig");
const output_decode = @import("output_decode.zig");
const codec_abi = @import("codec_abi.zig");

pub const Faults = struct {
    metadata: bool = false,
};

pub const max_evidence_bytes = output_decode.max_evidence_bytes;
pub const Evidence = output_decode.Evidence;
pub const Rejection = output_decode.Rejection;
pub const Validated = output_decode.Validated;
pub const EventData = output_decode.EventData;

const Range = struct { start: u64, length: u64 };

const Window = output_decode.Window;

const FileSource = struct {
    window: *Window,
    start: u64,
    end: u64,
    position: u64,

    fn init(window: *Window, range: Range) !FileSource {
        const end = try std.math.add(u64, range.start, range.length);
        return .{ .window = window, .start = range.start, .end = end, .position = range.start };
    }

    fn offset(self: *const FileSource) u64 {
        return self.position;
    }

    fn peek(self: *FileSource) !?u8 {
        if (self.position == self.end) return null;
        // Parsing asks for every byte, so the common case stays this check.
        const window = self.window;
        const index = self.position -% window.start;
        if (index < window.length) return window.bytes[@intCast(index)];
        return (try window.bytesAt(self.position, self.end))[0];
    }

    pub fn take(self: *FileSource) !u8 {
        const byte = try self.peek() orelse return error.UnexpectedJsonEnd;
        self.position += 1;
        return byte;
    }

    /// Borrowed bytes ahead, empty only at the end; valid until the next read.
    pub fn buffered(self: *FileSource) ![]const u8 {
        if (self.position == self.end) return &.{};
        return self.window.bytesAt(self.position, self.end);
    }

    /// Consume `count` bytes that `buffered` returned.
    fn skip(self: *FileSource, count: usize) void {
        std.debug.assert(count <= self.end - self.position);
        self.position += count;
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

comptime {
    // parseString finds the plain-run path through @hasDecl, which cannot see
    // a private `buffered`; without this the path would silently disappear.
    std.debug.assert(@hasDecl(FileSource, "buffered"));
}

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

    /// Feed a run of bytes, eight ASCII bytes at a time between sequences.
    fn feedSlice(self: *Utf8Validator, bytes: []const u8) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            if (self.used == 0) {
                while (index + 8 <= bytes.len and std.mem.readInt(u64, bytes[index..][0..8], .little) & 0x8080808080808080 == 0) index += 8;
                if (index == bytes.len) return;
            }
            try self.feed(bytes[index]);
            index += 1;
        }
    }

    fn finish(self: *const Utf8Validator) !void {
        if (self.used != 0) return error.InvalidJsonUtf8;
    }
};

const Decoded = struct {
    bounded: ?*protocol.Bounded(max_evidence_bytes) = null,
    hash: ?*std.crypto.hash.sha2.Sha256 = null,
    /// A second digest the same bytes extend: a message's whole answer.
    also: ?*std.crypto.hash.sha2.Sha256 = null,
    length: u64 = 0,
    overflow: bool = false,

    fn emit(self: *Decoded, bytes: []const u8) !void {
        self.length = try std.math.add(u64, self.length, bytes.len);
        if (self.hash) |hash| hash.update(bytes);
        if (self.also) |hash| hash.update(bytes);
        if (self.bounded) |destination| {
            if (self.overflow) return;
            // Keep the prefix that fits, however the bytes arrive.
            const kept = @min(bytes.len, destination.bytes.len - destination.len);
            @memcpy(destination.bytes[destination.len..][0..kept], bytes[0..kept]);
            destination.len += kept;
            self.overflow = kept < bytes.len;
        }
    }
};

const ParsedString = struct {
    encoded: Range,
    decoded_length: u64,
    non_whitespace: bool,
};

const isWhitespace = output_decode.isWhitespace;

/// Length of the leading bytes that need no escape, UTF-8 or end check.
fn plainStringLength(bytes: []const u8) usize {
    for (bytes, 0..) |byte, index| {
        if (byte == '"' or byte == '\\' or byte < 0x20 or byte >= 0x80) return index;
    }
    return bytes.len;
}

fn parseString(source: anytype, decoded: ?*Decoded) !ParsedString {
    try source.space();
    if (try source.take() != '"') return error.ExpectedJsonString;
    const start = source.offset();
    var validator: Utf8Validator = .{};
    var decoded_length: u64 = 0;
    var non_whitespace = false;
    while (true) {
        // A source holding its bytes in memory hands over plain ASCII runs
        // whole, so they are hashed and copied together, not byte by byte.
        if (comptime @hasDecl(@TypeOf(source.*), "buffered")) {
            if (validator.used == 0) {
                const bytes = try source.buffered();
                const plain = bytes[0..plainStringLength(bytes)];
                if (plain.len != 0) {
                    if (!non_whitespace) for (plain) |byte| {
                        if (!isWhitespace(byte)) {
                            non_whitespace = true;
                            break;
                        }
                    };
                    if (decoded) |consumer| try consumer.emit(plain);
                    decoded_length = try std.math.add(u64, decoded_length, plain.len);
                    source.skip(plain.len);
                    continue;
                }
            }
        }
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

fn readFields(window: *Window, object: Range, comptime names: []const []const u8) !Fields(names) {
    var source = try FileSource.init(window, object);
    return collectFields(&source, names);
}

fn exactOverflowCode(window: *Window, value: ?Range) !bool {
    const range = value orelse return false;
    var code: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(window, range, &code);
    return code.eql("context_length_exceeded");
}

fn errorOverflow(window: *Window, range: Range) !bool {
    const fields = try readFields(window, range, &.{"code"});
    return exactOverflowCode(window, try fields.get("code"));
}

fn malformedEnvelope(err: anyerror) !bool {
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

const ProviderFailure = output_decode.ProviderFailure;

/// The fields a report reads, from an error object or the envelope around
/// it, which may hold the `error` object itself.
const report_fields: []const []const u8 = &.{ "code", "type", "message", "detail", "error" };

/// Whether an error object's `type` may stand in for its missing code. An
/// event's own `type` is only the event's name.
const Typed = enum { typed, untyped };

/// Writes `code` (else, when typed, the object's `type`) and its `message`
/// (else a bare `detail`) into `report`. Best effort: a field that is
/// absent, null or malformed is left out, and nothing here fails.
fn writeReport(window: *Window, fields: Fields(report_fields), code: *const output_decode.ReportPart, typed: Typed, report: *output_decode.Report) void {
    var kind: output_decode.ReportPart = .{ .text = .{ .len = 0 }, .shortened = false };
    const name = if (code.text.len == 0 and typed == .typed) name: {
        readPart(&kind, window, fields.get("type") catch null);
        break :name &kind;
    } else code;
    var message: output_decode.ReportPart = .{ .text = .{ .len = 0 }, .shortened = false };
    readPart(&message, window, (fields.get("message") catch null) orelse (fields.get("detail") catch null));
    output_decode.writeReport(report, name, &message);
}

/// A string value's report part, into the empty `part`. Any other value, or
/// a failed read, leaves it empty.
fn readPart(part: *output_decode.ReportPart, window: *Window, value: ?Range) void {
    const range = value orelse return;
    // A field's value is valid JSON, so a string is its contents in quotes.
    const first = window.bytesAt(range.start, range.start + 1) catch return;
    if (first[0] != '"') return;
    output_decode.readPart(window, range.start + 1, range.length - 2, .json_string_v1, part) catch {
        part.text.len = 0;
        part.shortened = false;
    };
}

fn streamError(window: *Window, event: Range, failed_response: bool, provider_failure: *ProviderFailure) !void {
    var failure = event;
    if (failed_response) {
        const fields = try readFields(window, event, &.{"response"});
        const response = try readFields(window, try fields.required("response"), &.{ "status", "error" });
        var status: protocol.Bounded(max_evidence_bytes) = .{};
        _ = try readString(window, try response.required("status"), &status);
        if (!status.eql("failed")) return error.IncompleteProviderOutput;
        failure = try response.get("error") orelse return error.TemporaryProviderFailure;
    } else {
        const fields = try readFields(window, event, &.{ "code", "error" });
        // Preserve the top-level Responses error code when supplied. Some
        // error events instead carry the provider error in a nested object.
        if (try fields.get("code") == null) {
            if (try fields.get("error")) |nested| failure = nested;
        }
    }
    if (try rangeEquals(window, failure, "null")) return error.TemporaryProviderFailure;
    const fields = try readFields(window, failure, report_fields);
    var code: output_decode.ReportPart = .{ .text = .{ .len = 0 }, .shortened = false };
    if (try fields.get("code")) |value| {
        if (!try rangeEquals(window, value, "null")) _ = try readString(window, value, &code.text);
    }
    writeReport(window, fields, &code, if (failure.start == event.start) .untyped else .typed, &provider_failure.report);
    if (code.text.eql("context_length_exceeded")) return error.ContextOverflow;
    // Known terminal quota/request/policy codes do not become retryable
    // unknown failures.
    provider_failure.refusal = .ofProviderCode(code.text.slice());
    return if (provider_failure.refusal != null) error.PermanentProviderFailure else error.TemporaryProviderFailure;
}

fn incompleteOverflow(window: *Window, event: Range) !bool {
    const fields = try readFields(window, event, &.{"response"});
    const response = try readFields(window, try fields.required("response"), &.{ "status", "error", "incomplete_details" });
    var status: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(window, try response.required("status"), &status);
    if (!status.eql("incomplete")) return false;
    if (try response.get("error")) |failure| {
        if (!try rangeEquals(window, failure, "null") and try errorOverflow(window, failure)) return true;
    }
    if (try response.get("incomplete_details")) |details| {
        const reason = try readFields(window, details, &.{"reason"});
        return exactOverflowCode(window, try reason.get("reason"));
    }
    return false;
}

fn readString(window: *Window, value: Range, destination: *protocol.Bounded(max_evidence_bytes)) !ParsedString {
    destination.len = 0;
    var decoded = Decoded{ .bounded = destination };
    var source = try FileSource.init(window, value);
    const parsed = try parseString(&source, &decoded);
    try source.expectEnd();
    if (decoded.overflow) return error.ProviderValueTooLong;
    return parsed;
}

fn stringDigest(window: *Window, value: Range) ![32]u8 {
    var hash = protocol.contentHasher();
    var decoded = Decoded{ .hash = &hash };
    var source = try FileSource.init(window, value);
    const parsed = try parseString(&source, &decoded);
    try source.expectEnd();
    if (parsed.decoded_length == 0) return error.EmptyProviderIdentity;
    return hash.finalResult();
}

fn readIndex(window: *Window, value: Range) !u64 {
    var source = try FileSource.init(window, value);
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

    fn init(window: *Window, range: Range) !Array {
        var source = try FileSource.init(window, range);
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

const ItemValidation = struct {
    kind: output_format.OutputItemKind,
    id_digest: [32]u8,
    omit_reasoning_text: bool = false,
    non_whitespace: bool = false,
    /// A message's text: its text parts back to back.
    text_length: u64 = 0,
    text_digest: [32]u8 = @splat(0),
    phase: codec_abi.Phase = .unphased,
    /// The phase Rui's form holds: only an exact `commentary` or
    /// `final_answer` literal.
    neutral_phase: output_format.NeutralPhase = .unphased,
};

/// One output item's bytes inside an event, read the way replay reads a
/// saved item, so import and replay apply one grammar to the same bytes.
const ItemSource = struct {
    window: *Window,
    range: Range,

    pub fn contentLength(self: *const ItemSource) u64 {
        return self.range.length;
    }

    pub fn readContent(self: *const ItemSource, offset: u64, destination: []u8) !usize {
        const end = self.range.start + offset + destination.len;
        var filled: usize = 0;
        while (filled < destination.len) {
            const bytes = try self.window.bytesAt(self.range.start + offset + filled, end);
            @memcpy(destination[filled..][0..bytes.len], bytes);
            filled += bytes.len;
        }
        return filled;
    }
};

fn validateItem(response: *Response, window: *Window, item: Range, ordinal: u64) !ItemValidation {
    const item_check = response.item_check;
    item_check.reset(response.operation);
    var bytes: usize = std.math.maxInt(usize);
    var items: usize = std.math.maxInt(usize);
    // Unbounded allowances finish the item in one call.
    const omit_reasoning_text = switch ((try item_check.advance(&ItemSource{ .window = window, .range = item }, &bytes, &items)).?) {
        .compatible => |compatible| compatible.omit_reasoning_text,
        .incompatible => |reason| return reason,
    };
    const kind = item_check.item_kind.?;
    const id_digest = item_check.idDigest();
    var text_hash = protocol.contentHasher();
    const text_start = response.metadata.decoded_length;
    const neutral = try splitNeutral(response, window, item, ordinal, kind, &text_hash);
    // The grammar accepted the item and located the values that metadata
    // records address, so no second pass reads the whole item.
    switch (kind) {
        .reasoning, .compaction => return .{ .kind = kind, .id_digest = id_digest, .omit_reasoning_text = omit_reasoning_text },
        .function_call => {
            const tags = .{ output_format.OutputRecordTag.name, .call_id, .arguments };
            // Index 0 is the provider item id, kept in the item bag.
            comptime std.debug.assert(std.mem.eql(u8, OutputItemCheck.decoded_names[0], "id"));
            inline for (tags, item_check.decoded_fields[1..], item_check.encoded_spans[1..]) |tag, decoded, span| {
                const encoded = try stringContents(window, item, span);
                try response.metadata.append(.{
                    .tag = tag,
                    .kind = .function_call,
                    .ordinal = ordinal,
                    .start = encoded.start,
                    .length = encoded.length,
                    .decoded_length = decoded.length,
                    .content_digest = decoded.digest,
                });
            }
            return .{ .kind = .function_call, .id_digest = id_digest };
        },
        .message => {
            const text_length = response.metadata.decoded_length - text_start;
            const text_digest = text_hash.finalResult();
            try response.metadata.append(.{ .tag = .text, .kind = .message, .ordinal = ordinal, .start = 0, .length = 0, .decoded_length = text_length, .content_digest = text_digest });
            return .{
                .kind = .message,
                .id_digest = id_digest,
                .non_whitespace = neutral.non_whitespace,
                .text_length = text_length,
                .text_digest = text_digest,
                .phase = item_check.messagePhase(),
                .neutral_phase = neutral.phase,
            };
        },
    }
}

/// The encoded contents of a top-level string value inside `item`, between
/// the quotes after its key's colon and its closing quote.
fn stringContents(window: *Window, item: Range, span: OutputItemCheck.Span) !Range {
    var source = try FileSource.init(window, .{ .start = item.start + span.after_key, .length = span.end - span.after_key });
    try source.expect(':');
    try source.expect('"');
    std.debug.assert(try rangeEquals(window, .{ .start = item.start + span.end, .length = 1 }, "\""));
    return .{ .start = source.offset(), .length = item.start + span.end - source.offset() };
}

/// One object's members in order, each with its raw `"key":value` bytes.
const Members = struct {
    source: FileSource,
    done: bool = false,
    first: bool = true,

    const Member = struct { whole: Range, value: Range };

    fn init(window: *Window, object: Range) !Members {
        var source = try FileSource.init(window, object);
        try source.expect('{');
        return .{ .source = source };
    }

    /// The next member, its decoded key in `key` (empty when it does not
    /// fit, which no neutral name does).
    fn next(self: *Members, key: *protocol.Bounded(max_evidence_bytes)) !?Member {
        if (self.done) return null;
        try self.source.space();
        if (self.first and try self.source.peek() == '}') {
            _ = try self.source.take();
            try self.source.expectEnd();
            self.done = true;
            return null;
        }
        self.first = false;
        try self.source.space();
        const start = self.source.offset();
        try keyName(&self.source, key);
        try self.source.expect(':');
        try self.source.space();
        const value_start = self.source.offset();
        try skipValue(&self.source, 1);
        const end = self.source.offset();
        try self.source.space();
        switch (try self.source.take()) {
            '}' => {
                try self.source.expectEnd();
                self.done = true;
            },
            ',' => {},
            else => return error.UnexpectedJsonDelimiter,
        }
        return .{ .whole = .{ .start = start, .length = end - start }, .value = .{ .start = value_start, .length = end - value_start } };
    }
};

/// Accumulates one provider bag: its members' raw bytes joined by commas,
/// `m1,m2,...`, so a writer splices it into the object it rebuilds. Hashed
/// as the members are recorded.
const Bag = struct {
    scope: output_format.BagScope,
    hash: @TypeOf(protocol.contentHasher()) = protocol.contentHasher(),
    length: u64 = 0,
    members: u64 = 0,

    fn add(self: *Bag, response: *Response, window: *Window, ordinal: u64, kind: output_format.OutputItemKind, member: Range) !void {
        if (self.members != 0) {
            self.hash.update(",");
            self.length += 1;
        }
        var offset = member.start;
        const end = member.start + member.length;
        while (offset < end) {
            const bytes = try window.bytesAt(offset, end);
            self.hash.update(bytes);
            offset += bytes.len;
        }
        self.length = try std.math.add(u64, self.length, member.length);
        self.members += 1;
        try response.metadata.append(.{ .tag = .member, .kind = kind, .ordinal = ordinal, .start = member.start, .length = member.length, .scope = self.scope });
    }

    /// Records the trailer, even for an empty bag: every item and part has
    /// one, so a missing bag is damage rather than an absence.
    fn close(self: *Bag, response: *Response, ordinal: u64, kind: output_format.OutputItemKind) !void {
        try response.metadata.append(.{
            .tag = .extras,
            .kind = kind,
            .ordinal = ordinal,
            .start = 0,
            .length = 0,
            .decoded_length = self.length,
            .content_digest = self.hash.finalResult(),
            .scope = self.scope,
        });
    }
};

fn isNonemptyArray(window: *Window, value: Range) !bool {
    var array = try Array.init(window, value);
    return try array.next() != null;
}

fn stringIs(window: *Window, value: Range, expected: []const u8) !bool {
    var source = try FileSource.init(window, value);
    if (try source.peek() != '"') return false;
    var text: protocol.Bounded(max_evidence_bytes) = .{};
    _ = readString(window, value, &text) catch |err| switch (err) {
        // Longer than any expected word, so not equal to it.
        error.ProviderValueTooLong => return false,
        else => return err,
    };
    return text.eql(expected);
}

/// Splits an accepted item into Rui's own form and the provider bags: every
/// part of a recognised array becomes a `part` record (decoded text plus
/// its block's other members as the part bag), and every top-level member
/// Rui's form does not hold goes, as received, into the item bag. A member
/// becomes neutral only in exactly the expected shape, so the bags keep
/// everything else the model saw. `created_by` is dropped, as replay drops
/// it.
fn splitNeutral(response: *Response, window: *Window, item: Range, ordinal: u64, kind: output_format.OutputItemKind, text_hash: *std.crypto.hash.sha2.Sha256) !NeutralItem {
    var result: NeutralItem = .{};
    var answer: Answer = .{ .hash = text_hash };
    var bag: Bag = .{ .scope = .item };
    var members = try Members.init(window, item);
    var key: protocol.Bounded(max_evidence_bytes) = .{};
    while (try members.next(&key)) |member| {
        const neutral = if (key.eql("type") or key.eql("created_by"))
            true
        else switch (kind) {
            .message => if (key.eql("role"))
                try stringIs(window, member.value, "assistant")
            else if (key.eql("phase")) phase: {
                if (try stringIs(window, member.value, "commentary")) {
                    result.phase = .commentary;
                    break :phase true;
                }
                if (try stringIs(window, member.value, "final_answer")) {
                    result.phase = .final_answer;
                    break :phase true;
                }
                break :phase false;
            } else if (key.eql("content"))
                try splitParts(response, window, member.value, ordinal, kind, .content, &answer)
            else
                false,
            .reasoning => if (key.eql("summary"))
                try splitParts(response, window, member.value, ordinal, kind, .summary, null)
            else if (key.eql("content"))
                try splitParts(response, window, member.value, ordinal, kind, .content, null)
            else
                false,
            .function_call => key.eql("name") or key.eql("call_id") or key.eql("arguments"),
            .compaction => false,
        };
        if (!neutral) try bag.add(response, window, ordinal, kind, member.whole);
    }
    try bag.close(response, ordinal, kind);
    result.non_whitespace = answer.non_whitespace;
    return result;
}

const NeutralItem = struct {
    phase: output_format.NeutralPhase = .unphased,
    /// A message: whether its answer has any non-whitespace text.
    non_whitespace: bool = false,
};

/// A message's answer: its text parts back to back.
const Answer = struct {
    hash: *std.crypto.hash.sha2.Sha256,
    non_whitespace: bool = false,
};

/// Records each block of a nonempty array as a part, or returns false (the
/// whole array stays in the item bag) for any other value.
fn splitParts(response: *Response, window: *Window, value: Range, ordinal: u64, kind: output_format.OutputItemKind, array_kind: output_format.PartArray, answer: ?*Answer) !bool {
    var source = try FileSource.init(window, value);
    if (try source.peek() != '[' or !try isNonemptyArray(window, value)) return false;
    var array = try Array.init(window, value);
    while (try array.next()) |block| {
        var block_source = try FileSource.init(window, block);
        const block_fields = if (try block_source.peek() == '{') try readFields(window, block, &.{ "type", "text", "refusal" }) else null;
        var part_kind: output_format.PartKind = .opaque_block;
        var text_key: []const u8 = "";
        var text_value: Range = undefined;
        // A block whose type or text is missing, duplicated or not a string
        // is not Rui's: it stays whole as an opaque part. `get` fails only on
        // a duplicate.
        if (block_fields) |fields| known: {
            const type_value = (fields.get("type") catch break :known) orelse break :known;
            const candidates: []const struct { []const u8, output_format.PartKind, []const u8 } = switch (array_kind) {
                .summary => &.{.{ "summary_text", .summary_text, "text" }},
                .content => if (kind == .message)
                    &.{ .{ "output_text", .output_text, "text" }, .{ "refusal", .refusal, "refusal" } }
                else
                    &.{.{ "reasoning_text", .reasoning_text, "text" }},
                .none => unreachable,
            };
            for (candidates) |candidate| if (try stringIs(window, type_value, candidate[0])) {
                const text = (if (std.mem.eql(u8, candidate[2], "text")) fields.get("text") else fields.get("refusal")) catch break :known;
                text_value = text orelse break :known;
                var probe = try FileSource.init(window, text_value);
                if (try probe.peek() != '"') break :known;
                part_kind = candidate[1];
                text_key = candidate[2];
            };
        }
        var part_bag: Bag = .{ .scope = .part };
        if (part_kind == .opaque_block) {
            try response.metadata.append(.{ .tag = .part, .kind = kind, .ordinal = ordinal, .start = block.start, .length = 0, .part_kind = .opaque_block, .part_array = array_kind });
        } else {
            var hash = protocol.contentHasher();
            var decoded = Decoded{ .hash = &hash, .also = if (answer) |whole| whole.hash else null };
            var text_source = try FileSource.init(window, text_value);
            const text = try parseString(&text_source, &decoded);
            if (answer) |whole| whole.non_whitespace = whole.non_whitespace or text.non_whitespace;
            try response.metadata.append(.{
                .tag = .part,
                .kind = kind,
                .ordinal = ordinal,
                .start = text.encoded.start,
                .length = text.encoded.length,
                .decoded_length = text.decoded_length,
                .content_digest = hash.finalResult(),
                .part_kind = part_kind,
                .part_array = array_kind,
            });
        }
        var members = try Members.init(window, block);
        var key: protocol.Bounded(max_evidence_bytes) = .{};
        while (try members.next(&key)) |member| {
            if (part_kind != .opaque_block and (key.eql("type") or key.eql(text_key))) continue;
            try part_bag.add(response, window, ordinal, kind, member.whole);
        }
        try part_bag.close(response, ordinal, kind);
    }
    return true;
}

/// The one output item grammar: acceptance stores an item only when this
/// pass does, with the replay rule it judged. Replay applies that rule
/// without judging again, so a change to what this grammar accepts or omits
/// changes the Store format (`store.schema_version`). Partial string/number
/// tokens never own payload storage. Frames
/// retain only consequential field facts; errors in meaning are deferred
/// until syntax and the complete source have validated.
/// Initialize/use in final storage (the scanner borrows its nesting buffer).
pub const OutputItemCheck = struct {
    /// The Operation the item arrives under, which decides whether a
    /// compaction or a call may appear at all.
    operation: output_format.ModelOperationKind = undefined,
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
    /// The item's decoded top-level `id`, `name`, `call_id` and `arguments`
    /// strings. Every kind has an `id`; only a call has the other three,
    /// which are its certificate in ProposalMetadata order.
    decoded_fields: [decoded_names.len]DecodedField = undefined,
    decoded_fields_seen: u4 = 0,
    /// The kind the item declares, once its type names a known kind.
    item_kind: ?output_format.OutputItemKind = null,
    /// The scanner's item offset, through its public diagnostics.
    diagnostics: std.json.Scanner.Diagnostics = .{},
    /// Item offsets of the end of the latest top-level key, and of each
    /// decoded field's encoded value.
    key_end: u64 = 0,
    encoded_spans: [decoded_names.len]Span = undefined,

    /// From the end of a value's key to its closing quote.
    pub const Span = struct { after_key: u64, end: u64 };
    pub const DecodedField = protocol.ProposalFieldReference;

    /// How the grammar judged one complete item.
    pub const Verdict = union(enum) {
        /// Today's rules accept the item. `omit_reasoning_text`: it is a
        /// reasoning item whose nonempty `content` holds only reasoning_text
        /// blocks, private evidence that replay leaves out.
        compatible: struct { omit_reasoning_text: bool },
        /// The first rule the item breaks, named as import reports it.
        incompatible: Incompatibility,
    };

    /// Every rule the grammar can find broken in a syntactically valid item.
    pub const Incompatibility = error{
        DuplicateJsonField,
        MissingProviderField,
        ExpectedJsonString,
        ProviderValueTooLong,
        EmptyProviderIdentity,
        UnsupportedItemStatus,
        ContinuationUnavailable,
        UnexpectedJsonDelimiter,
        UnsupportedContentBlock,
        UnsupportedReasoningBlock,
        UnsupportedItemType,
        UnsupportedReasoningText,
        UnsupportedProviderOutput,
        UnsupportedAsyncCall,
        InvalidJsonLiteral,
        UnsupportedCallControl,
        UnsupportedMessageRole,
        UnsupportedMessagePhase,
        MalformedProviderOutput,
        UnsupportedAnnotation,
        UnsupportedCaller,
        UnsupportedMetadataAuthority,
    };

    /// Readies the check for one item under `operation`. The runtime
    /// literal writes the header fields only: the input window, frames and
    /// decode scratch keep their `undefined` defaults, unwritten until the
    /// grammar fills them. An all-comptime `.{}` would copy the whole
    /// 66 KB default instead.
    pub fn reset(self: *OutputItemCheck, operation: output_format.ModelOperationKind) void {
        self.* = .{ .operation = operation };
    }

    /// After a compatible item validates, the digest of its decoded `id`.
    pub fn idDigest(self: *const OutputItemCheck) [32]u8 {
        std.debug.assert(self.decoded_fields_seen & 1 != 0);
        return self.decoded_fields[0].digest;
    }

    // Other kinds leave `content` open, duplicates included.
    fn replaysReasoningText(self: *const OutputItemCheck) bool {
        if (self.item_kind != .reasoning) return false;
        const content = self.frames[0].get("content") catch unreachable;
        return content.shape == .array and content.length != 0;
    }

    /// After a compatible message validates, the phase it declares.
    fn messagePhase(self: *const OutputItemCheck) @FieldType(ItemValidation, "phase") {
        const phase = self.frames[0].get("phase") catch unreachable;
        if (phase.is("commentary") or phase.is("partial_answer")) return .commentary;
        if (phase.is("final_answer")) return .final_answer;
        return .unphased;
    }

    const names = [_][]const u8{ "type", "id", "status", "role", "phase", "internal_chat_message_metadata_passthrough", "content", "text", "encrypted_content", "summary", "name", "call_id", "arguments", "caller", "async", "namespace", "encrypted_function_args", "refusal", "annotations", "cell_id", "executed_tool_calls", "tool_calls_complete" };
    const decoded_names = [_][]const u8{ "id", "name", "call_id", "arguments" };
    const words = [_][]const u8{ "reasoning", "compaction", "function_call", "message", "completed", "assistant", "commentary", "partial_answer", "final_answer", "direct", "output_text", "refusal", "reasoning_text", "summary_text", "url_citation" };
    const Shape = enum { absent, string, object, array, null_value, false_value, true_value, other };
    /// How a parent reads a block or annotation. A block's meaning depends on
    /// its item's type, which can arrive after the block, so each block keeps
    /// one result per reading and the item consults the one it needs.
    const Reading = enum { output, reasoning, summary };
    const readings = .{ Reading.output, .reasoning, .summary };
    const Readings = struct { all: bool = false, output: bool = false, reasoning: bool = false, summary: bool = false };
    const Value = struct {
        shape: Shape = .absent,
        word: ?usize = null,
        length: u64 = 0,
        duplicate: bool = false,
        // The first rule broken, in rule order: under every reading, then
        // under each one.
        failure: ?Incompatibility = null,
        output_failure: ?Incompatibility = null,
        reasoning_failure: ?Incompatibility = null,
        summary_failure: ?Incompatibility = null,
        /// Whether a field this value's meaning consumes is a duplicate,
        /// under every reading or under each one. Replay reports such
        /// canonical ambiguity before any other failure.
        ambiguous: Readings = .{},

        fn is(self: Value, word: []const u8) bool {
            return self.shape == .string and self.word != null and std.mem.eql(u8, words[self.word.?], word);
        }

        fn failureAs(self: Value, comptime reading: Reading) ?Incompatibility {
            return self.failure orelse @field(self, @tagName(reading) ++ "_failure");
        }

        fn ambiguousAs(self: Value, comptime reading: Reading) bool {
            return self.ambiguous.all or @field(self.ambiguous, @tagName(reading));
        }

        fn itemKind(self: Value) ?output_format.OutputItemKind {
            inline for (@typeInfo(output_format.OutputItemKind).@"enum".field_names) |name| {
                if (self.is(name)) return @field(output_format.OutputItemKind, name);
            }
            return null;
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

        fn get(self: *const Frame, comptime name: []const u8) Incompatibility!Value {
            const value = self.fields[comptime index(name).?];
            if (value.duplicate) return error.DuplicateJsonField;
            return value;
        }

        fn string(self: *const Frame, comptime name: []const u8) Incompatibility!Value {
            const value = try self.get(name);
            return switch (value.shape) {
                .string => value,
                .absent => error.MissingProviderField,
                else => error.ExpectedJsonString,
            };
        }

        /// A string compared with known words, readable only when short.
        fn word(self: *const Frame, comptime name: []const u8) Incompatibility!Value {
            const value = try self.string(name);
            if (value.length > max_evidence_bytes) return error.ProviderValueTooLong;
            return value;
        }

        fn identity(self: *const Frame, comptime name: []const u8) Incompatibility!void {
            if ((try self.string(name)).length == 0) return error.EmptyProviderIdentity;
        }

        fn completed(self: *const Frame) Incompatibility!void {
            if ((try self.get("status")).shape == .absent) return;
            if (!(try self.word("status")).is("completed")) return error.UnsupportedItemStatus;
        }

        fn encrypted(self: *const Frame) Incompatibility!void {
            const value = try self.get("encrypted_content");
            switch (value.shape) {
                .absent => return error.ContinuationUnavailable,
                .string => if (value.length == 0) return error.ContinuationUnavailable,
                else => return error.ExpectedJsonString,
            }
        }

        /// A nested array the reading consumes: when present, an array whose
        /// elements all satisfy that reading.
        fn blocks(self: *const Frame, comptime name: []const u8, comptime reading: Reading) Incompatibility!void {
            const value = try self.get(name);
            if (value.shape == .absent) return;
            if (value.shape != .array) return error.UnexpectedJsonDelimiter;
            if (value.failureAs(reading)) |err| return err;
        }

        /// Whether any named field the reading consumes, or anything its
        /// value consumes, is a duplicate.
        fn consumesDuplicate(self: *const Frame, comptime field_names: []const []const u8, comptime reading: ?Reading) bool {
            inline for (field_names) |name| {
                const value = self.fields[comptime index(name).?];
                if (value.duplicate) return true;
                if (if (reading) |consumed| value.ambiguousAs(consumed) else value.ambiguous.all) return true;
            }
            return false;
        }
    };

    /// The fields one object's rules consume: plain fields, and nested arrays
    /// read under one reading. `judge` looks up only these, enforced at
    /// compile time, and `ambiguity` finds a consumed duplicate among them.
    const Consumed = struct {
        plain: []const []const u8 = &.{},
        nested: []const struct { []const u8, Reading } = &.{},

        fn join(comptime a: Consumed, comptime b: Consumed) Consumed {
            return .{ .plain = a.plain ++ b.plain, .nested = a.nested ++ b.nested };
        }

        fn reads(comptime self: Consumed, comptime name: []const u8, comptime reading: ?Reading) bool {
            if (reading == null) for (self.plain) |field| if (std.mem.eql(u8, field, name)) return true;
            for (self.nested) |field| if (std.mem.eql(u8, field[0], name) and (reading == null or field[1] == reading.?)) return true;
            return false;
        }

        fn duplicateIn(comptime self: Consumed, frame: *const Frame) bool {
            if (frame.consumesDuplicate(self.plain, null)) return true;
            inline for (self.nested) |field| if (frame.consumesDuplicate(&.{field[0]}, field[1])) return true;
            return false;
        }
    };

    const item_fields: Consumed = .{ .plain = &.{ "type", "id", "status", "internal_chat_message_metadata_passthrough" } };
    fn kindFields(comptime kind: output_format.OutputItemKind) Consumed {
        return item_fields.join(switch (kind) {
            .reasoning => .{ .plain = &.{ "text", "encrypted_content" }, .nested = &.{ .{ "summary", .summary }, .{ "content", .reasoning } } },
            .compaction => .{ .plain = &.{"encrypted_content"} },
            .function_call => .{ .plain = &.{ "name", "call_id", "arguments", "caller", "async", "namespace", "encrypted_function_args" } },
            .message => .{ .plain = &.{ "role", "phase" }, .nested = &.{.{ "content", .output }} },
        });
    }
    const type_fields: Consumed = .{ .plain = &.{"type"} };
    const refusal_fields: Consumed = .{ .plain = &.{"refusal"} };
    const output_text_fields: Consumed = .{ .plain = &.{"text"}, .nested = &.{.{ "annotations", .output }} };
    const text_fields: Consumed = .{ .plain = &.{"text"} };
    const metadata_fields: Consumed = .{ .plain = &.{ "cell_id", "executed_tool_calls", "tool_calls_complete" } };

    /// A frame's lookups, limited to the fields `consumed` names.
    fn Rules(comptime consumed: Consumed) type {
        return struct {
            frame: *const Frame,
            const Self = @This();

            fn require(comptime name: []const u8, comptime reading: ?Reading) void {
                if (!comptime consumed.reads(name, reading)) @compileError("a rule reads " ++ name ++ ", which its fields table does not list");
            }
            fn get(self: Self, comptime name: []const u8) Incompatibility!Value {
                require(name, null);
                return self.frame.get(name);
            }
            fn string(self: Self, comptime name: []const u8) Incompatibility!Value {
                require(name, null);
                return self.frame.string(name);
            }
            fn word(self: Self, comptime name: []const u8) Incompatibility!Value {
                require(name, null);
                return self.frame.word(name);
            }
            fn identity(self: Self, comptime name: []const u8) Incompatibility!void {
                require(name, null);
                return self.frame.identity(name);
            }
            fn completed(self: Self) Incompatibility!void {
                require("status", null);
                return self.frame.completed();
            }
            fn encrypted(self: Self) Incompatibility!void {
                require("encrypted_content", null);
                return self.frame.encrypted();
            }
            fn blocks(self: Self, comptime name: []const u8, comptime reading: Reading) Incompatibility!void {
                require(name, reading);
                return self.frame.blocks(name, reading);
            }
        };
    }

    fn index(name: []const u8) ?usize {
        for (names, 0..) |candidate, i| if (std.mem.eql(u8, candidate, name)) return i;
        return null;
    }

    /// Which decoded field the string being read is, if any: only the item's
    /// own top-level strings are hashed.
    fn decodedField(self: *const OutputItemCheck) ?usize {
        if (self.depth != 1 or self.frames[0].wants_key) return null;
        const key = self.frames[0].key orelse return null;
        inline for (decoded_names, 0..) |name, i| if (key == comptime index(name).?) return i;
        return null;
    }

    fn appendText(self: *OutputItemCheck, bytes: []const u8) !void {
        if (self.decodedField() != null) self.token_hash.update(bytes);
        self.token_length = try std.math.add(u64, self.token_length, bytes.len);
        if (self.token_overflow or self.token_text.len + bytes.len > max_evidence_bytes) {
            self.token_overflow = true;
        } else {
            @memcpy(self.token_text.bytes[self.token_text.len..][0..bytes.len], bytes);
            self.token_text.len += bytes.len;
        }
    }

    fn accept(self: *OutputItemCheck, value: Value) void {
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
            // Elements are judged in order: the first failure stands.
            frame.aggregate.length += 1;
            inline for (readings) |reading| {
                const prior = &@field(frame.aggregate, @tagName(reading) ++ "_failure");
                if (prior.* == null) prior.* = if (value.shape != .object) error.UnexpectedJsonDelimiter else value.failureAs(reading);
                if (value.ambiguousAs(reading)) @field(frame.aggregate.ambiguous, @tagName(reading)) = true;
            }
        }
    }

    fn childKind(self: *OutputItemCheck, object: bool) Kind {
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

    fn finishFrame(self: *OutputItemCheck, frame: *const Frame) Value {
        if (!frame.object) return frame.aggregate;
        var result = Value{ .shape = .object, .ambiguous = ambiguity(frame) };
        self.judge(frame, &result) catch |err| {
            result.failure = err;
        };
        return result;
    }

    // A consumed duplicate, wherever it stands among the rules.
    fn ambiguity(frame: *const Frame) Readings {
        const declared = frame.fields[comptime index("type").?];
        return switch (frame.kind) {
            .item => .{ .all = item_fields.duplicateIn(frame) or if (declared.itemKind()) |kind| switch (kind) {
                inline else => |known| (comptime kindFields(known)).duplicateIn(frame),
            } else false },
            .block => .{
                .all = type_fields.duplicateIn(frame),
                .output = if (declared.is("refusal"))
                    refusal_fields.duplicateIn(frame)
                else
                    declared.is("output_text") and output_text_fields.duplicateIn(frame),
                .reasoning = declared.is("reasoning_text") and text_fields.duplicateIn(frame),
                .summary = declared.is("summary_text") and text_fields.duplicateIn(frame),
            },
            .annotation, .caller => .{ .all = type_fields.duplicateIn(frame) },
            .metadata => .{ .all = metadata_fields.duplicateIn(frame) },
            else => .{},
        };
    }

    // Each object's rules run in a fixed order; the first one broken is its
    // failure.
    fn judge(self: *OutputItemCheck, frame: *const Frame, result: *Value) Incompatibility!void {
        switch (frame.kind) {
            .item => {
                const item = Rules(item_fields){ .frame = frame };
                _ = try item.word("type");
                try item.identity("id");
                const metadata = try item.get("internal_chat_message_metadata_passthrough");
                if (metadata.shape != .absent) {
                    if (metadata.shape != .object) return error.UnexpectedJsonDelimiter;
                    if (metadata.failure) |err| return err;
                }
                const kind = (try item.get("type")).itemKind() orelse return error.UnsupportedItemType;
                self.item_kind = kind;
                switch (kind) {
                    .reasoning => {
                        const rules = Rules(kindFields(.reasoning)){ .frame = frame };
                        try rules.completed();
                        if ((try rules.get("text")).shape != .absent) return error.UnsupportedReasoningText;
                        try rules.encrypted();
                        try rules.blocks("summary", .summary);
                        try rules.blocks("content", .reasoning);
                    },
                    .compaction => {
                        const rules = Rules(kindFields(.compaction)){ .frame = frame };
                        if (self.operation != .compaction) return error.UnsupportedProviderOutput;
                        try rules.completed();
                        try rules.encrypted();
                    },
                    .function_call => {
                        const rules = Rules(kindFields(.function_call)){ .frame = frame };
                        if (self.operation == .compaction) return error.UnsupportedProviderOutput;
                        try rules.completed();
                        const caller = try rules.get("caller");
                        switch (caller.shape) {
                            .absent, .null_value => {},
                            .object => if (caller.failure) |err| return err,
                            else => return error.UnexpectedJsonDelimiter,
                        }
                        switch ((try rules.get("async")).shape) {
                            .absent, .null_value, .false_value => {},
                            .true_value => return error.UnsupportedAsyncCall,
                            else => return error.InvalidJsonLiteral,
                        }
                        inline for (.{ "namespace", "encrypted_function_args" }) |name| {
                            const value = try rules.get(name);
                            switch (value.shape) {
                                .absent, .null_value => {},
                                .string => if (value.length != 0) return error.UnsupportedCallControl,
                                else => return error.ExpectedJsonString,
                            }
                        }
                        inline for (.{ "name", "call_id" }) |name| try rules.identity(name);
                        _ = try rules.string("arguments");
                    },
                    .message => {
                        const rules = Rules(kindFields(.message)){ .frame = frame };
                        try rules.completed();
                        if (!(try rules.word("role")).is("assistant")) return error.UnsupportedMessageRole;
                        const phase = try rules.get("phase");
                        if (phase.shape != .absent and phase.shape != .null_value) {
                            _ = try rules.word("phase");
                            if (!phase.is("commentary") and !phase.is("partial_answer") and !phase.is("final_answer")) return error.UnsupportedMessagePhase;
                        }
                        const content = try rules.get("content");
                        if (content.shape == .absent) return error.MissingProviderField;
                        try rules.blocks("content", .output);
                        if (content.length == 0) return error.MalformedProviderOutput;
                    },
                }
            },
            .block => {
                const kind = try (Rules(type_fields){ .frame = frame }).word("type");
                outputBlock(frame, kind) catch |err| {
                    result.output_failure = err;
                };
                textBlock(frame, kind, "reasoning_text") catch |err| {
                    result.reasoning_failure = err;
                };
                textBlock(frame, kind, "summary_text") catch |err| {
                    result.summary_failure = err;
                };
            },
            .annotation => {
                if (!(try (Rules(type_fields){ .frame = frame }).word("type")).is("url_citation")) result.output_failure = error.UnsupportedAnnotation;
            },
            .caller => {
                const rules = Rules(type_fields){ .frame = frame };
                if ((try rules.get("type")).shape == .absent) return error.UnsupportedCaller;
                if (!(try rules.word("type")).is("direct")) return error.UnsupportedCaller;
            },
            .metadata => {
                const rules = Rules(metadata_fields){ .frame = frame };
                inline for (metadata_fields.plain) |name| {
                    if ((try rules.get(name)).shape != .absent) return error.UnsupportedMetadataAuthority;
                }
            },
            else => {},
        }
    }

    fn outputBlock(frame: *const Frame, kind: Value) Incompatibility!void {
        if (kind.is("refusal")) {
            _ = try (Rules(refusal_fields){ .frame = frame }).string("refusal");
            return;
        }
        if (!kind.is("output_text")) return error.UnsupportedContentBlock;
        const rules = Rules(output_text_fields){ .frame = frame };
        try rules.blocks("annotations", .output);
        _ = try rules.string("text");
    }

    // Reasoning and summary blocks retain annotations without interpreting
    // them.
    fn textBlock(frame: *const Frame, kind: Value, comptime expected: []const u8) Incompatibility!void {
        if (!kind.is(expected)) return error.UnsupportedReasoningBlock;
        _ = try (Rules(text_fields){ .frame = frame }).string("text");
    }

    /// Source implements contentLength/readContent. Each refill is charged at
    /// its actual size, including ignored bytes. Each scanner token (including
    /// partial tokens and open fields) consumes one item of the caller's turn.
    /// Null until the whole item is read. Syntax errors, and at replay a
    /// duplicate field the item's meaning consumes, are errors: canonical
    /// bytes cannot have them.
    pub fn advance(self: *OutputItemCheck, source: anytype, bytes_left: *usize, items_left: *usize) !?Verdict {
        if (self.scanner == null) {
            self.allocator = .init(&self.nesting);
            self.scanner = std.json.Scanner.initStreaming(self.allocator.allocator());
            self.scanner.?.enableDiagnostics(&self.diagnostics);
            // Avoid ArrayList's cache-line-sized growth policy. These 128 bits
            // cover the depth guard plus the one opening token it observes.
            try self.scanner.?.stack.bytes.ensureTotalCapacityPrecise(self.nesting.len);
        }
        const scanner = &self.scanner.?;
        while (items_left.* != 0) {
            const token = scanner.next() catch |err| switch (err) {
                error.BufferUnderrun => {
                    if (bytes_left.* == 0) return null;
                    const wanted: usize = @intCast(@min(@min(source.contentLength() - self.position, self.input.len), bytes_left.*));
                    if (wanted == 0) {
                        scanner.endInput();
                        continue;
                    }
                    const count = try source.readContent(self.position, self.input[0..wanted]);
                    if (count != wanted) return error.ShortSealedRead;
                    self.position += count;
                    bytes_left.* -= count;
                    try self.utf8.feedSlice(self.input[0..count]);
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
                        if (self.depth == 1) self.key_end = self.diagnostics.getByteOffset();
                    } else {
                        var value = Value{ .shape = .string, .length = self.token_length };
                        if (self.decodedField()) |i| {
                            self.decoded_fields[i] = .{ .length = self.token_length, .digest = self.token_hash.finalResult() };
                            self.encoded_spans[i] = .{ .after_key = self.key_end, .end = self.diagnostics.getByteOffset() - 1 };
                            self.decoded_fields_seen |= @as(u4, 1) << @intCast(i);
                            self.token_hash = protocol.contentHasher();
                        }
                        if (!self.token_overflow) for (words, 0..) |word, i| {
                            if (self.token_text.eql(word)) value.word = i;
                        };
                        self.accept(value);
                    }
                    self.token_text.len = 0;
                    self.token_length = 0;
                    self.token_overflow = false;
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
                    self.accept(self.finishFrame(&self.frames[self.depth]));
                },
                .partial_number => {},
                .number => self.accept(.{ .shape = .other }),
                .true => self.accept(.{ .shape = .true_value }),
                .false => self.accept(.{ .shape = .false_value }),
                .null => self.accept(.{ .shape = .null_value }),
                .end_of_document => {
                    if (self.result.shape != .object) return error.UnexpectedJsonDelimiter;
                    // A consumed duplicate is a lookup the grammar makes, so
                    // it always fails the item too.
                    const reason = self.result.failure orelse {
                        std.debug.assert(!self.result.ambiguous.all);
                        return .{ .compatible = .{ .omit_reasoning_text = self.replaysReasoningText() } };
                    };
                    return .{ .incompatible = reason };
                },
                .allocated_string, .allocated_number => unreachable,
            }
        }
        return null;
    }
};

/// Judge one item from a file under `operation`, without emitting metadata
/// or retaining a payload: the grammar import runs, driven over windows.
fn judgeFile(io: std.Io, source: std.Io.File, length: u64, operation: output_format.ModelOperationKind) !OutputItemCheck.Verdict {
    const item_check = testingItemCheck();
    item_check.reset(operation);
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
    while (true) {
        var bytes: usize = protocol.content_window_bytes;
        var items: usize = 64;
        if (try item_check.advance(Source{ .io = io, .file = source, .length = length }, &bytes, &items)) |verdict| return verdict;
    }
}

fn expectDecodedFields(item_check: *const OutputItemCheck, expected: anytype) !void {
    try std.testing.expectEqual(@as(u4, 15), item_check.decoded_fields_seen);
    for (item_check.decoded_fields, expected) |actual, field| {
        try std.testing.expectEqual(field.length, actual.length);
        try std.testing.expectEqualSlices(u8, &field.digest, &actual.digest);
    }
}

fn expectCompatible(verdict: OutputItemCheck.Verdict) !void {
    try std.testing.expect(verdict == .compatible);
}

fn expectIncompatible(reason: anyerror, verdict: OutputItemCheck.Verdict) !void {
    try std.testing.expect(verdict == .incompatible);
    try std.testing.expectEqual(reason, @as(anyerror, verdict.incompatible));
}

const replay_cases = [_]struct { item: []const u8, supported: bool, operation: output_format.ModelOperationKind = .assistant_response, omits_reasoning_text: bool = false }{
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"future\":{\"nested\":[null,true]}}", .supported = true },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\"}", .supported = false },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":null}", .supported = false },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"summary\":null}", .supported = false },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"not reasoning\"}]}", .supported = false },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"refusal\",\"refusal\":\"not a summary\"}]}", .supported = false },
    .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"opaque\",\"created_by\":\"canonical\"}", .supported = true, .operation = .compaction },
    .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"\"}", .supported = false, .operation = .compaction },
    .{ .item = "{\"type\":\"compaction_v2\",\"id\":\"c\",\"encrypted_content\":\"opaque\"}", .supported = false },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", .supported = true },
    .{ .item = "{\"id\":\"msg_partial\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"First result.\"}],\"phase\":\"partial_answer\"}", .supported = true },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"phase\":\"partial_answers\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", .supported = false },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"future_text\",\"text\":\"ok\"}]}", .supported = false },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"call\",\"arguments\":\"{}\",\"caller\":{\"type\":\"future\"}}", .supported = false },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"call\",\"arguments\":\"{}\",\"async\":17}", .supported = false },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"status\":\"in_progress\",\"encrypted_content\":\"opaque\"}", .supported = false },
    .{ .item = "{\"content\":[{\"text\":\"ok\",\"annotations\":[{\"url\":\"https://example.com\",\"type\":\"url_citation\"}],\"type\":\"output_text\"}],\"role\":\"assistant\",\"phase\":\"final_answer\",\"id\":\"m\",\"type\":\"message\"}", .supported = true },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"annotations\":[{\"type\":\"file_citation\"}]}]}", .supported = false },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[]}", .supported = false },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"user\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", .supported = false },
    .{ .item = "{\"summary\":[{\"annotations\":false,\"text\":\"summary\",\"type\":\"summary_text\"}],\"content\":[{\"text\":\"private\",\"type\":\"reasoning_text\"}],\"encrypted_content\":\"opaque\",\"id\":\"r\",\"type\":\"reasoning\"}", .supported = true, .omits_reasoning_text = true },
    .{ .item = "{\"content\":[{\"type\":\"reasoning_text\",\"text\":\"private\",\"annotations\":[],\"annotations\":false}],\"encrypted_content\":\"opaque\",\"id\":\"r\",\"type\":\"reasoning\"}", .supported = true, .omits_reasoning_text = true },
    .{ .item = "{\"summary\":[{\"type\":\"summary_text\",\"text\":\"summary\",\"annotations\":[{\"type\":\"future\",\"type\":false}]}],\"encrypted_content\":\"opaque\",\"id\":\"r\",\"type\":\"reasoning\"}", .supported = true },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"text\":null}", .supported = false },
    .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"opaque\",\"internal_chat_message_metadata_passthrough\":{\"cell_id\":null}}", .supported = false, .operation = .compaction },
    .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"opaque\",\"internal_chat_message_metadata_passthrough\":{\"future\":{\"cell_id\":null}}}", .supported = true, .operation = .compaction },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"\",\"caller\":null,\"async\":null,\"namespace\":\"\",\"encrypted_function_args\":null}", .supported = true },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"async\":true}", .supported = false },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"namespace\":\"program\"}", .supported = false },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"encrypted_function_args\":\"opaque\"}", .supported = false },
    // A duplicate the summary reading never consumes stays open.
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"summary\":[{\"type\":\"output_text\",\"text\":\"a\",\"text\":\"b\"}]}", .supported = false },
};

test "the item grammar rejects unsupported meaning and preserves open fields" {
    for (replay_cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try testingObject(&tmp, case.item);
        defer source.file.close(std.testing.io);
        const verdict = try judgeFile(std.testing.io, source.file, case.item.len, case.operation);
        try std.testing.expectEqual(case.supported, verdict == .compatible);
        // Validation, and the interpreter beside it, judges it alike.
        const imported = if (importTestingItem(&tmp, case.item, case.operation)) |_| true else |_| false;
        try std.testing.expectEqual(case.supported, imported);
    }
}

const replay_failure_cases = [_]struct { item: []const u8, failure: anyerror, operation: output_format.ModelOperationKind = .assistant_response }{
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"id\":\"s\",\"encrypted_content\":\"opaque\"}", .failure = error.DuplicateJsonField },
    .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"status\":\"future\",\"encrypted_content\":\"a\",\"encrypted_content\":\"b\"}", .failure = error.DuplicateJsonField, .operation = .compaction },
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
    .{ .item = "{\"type\":\"future\",\"id\":\"r\",\"open\":[true,]}", .failure = error.SyntaxError },
};

test "the item grammar refuses consumed duplicates and syntax" {
    for (replay_failure_cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try testingObject(&tmp, case.item);
        defer source.file.close(std.testing.io);
        const verdict = judgeFile(std.testing.io, source.file, case.item.len, case.operation) catch |err| {
            try std.testing.expectEqual(error.SyntaxError, err);
            try std.testing.expectEqual(case.failure, err);
            if (importTestingItem(&tmp, case.item, case.operation)) |_| return error.TestExpectedError else |_| {}
            continue;
        };
        // A consumed duplicate fails the item; an earlier broken rule may
        // be the one named.
        try std.testing.expectEqual(error.DuplicateJsonField, case.failure);
        try std.testing.expect(verdict == .incompatible);
        try std.testing.expectError(verdict.incompatible, importTestingItem(&tmp, case.item, case.operation));
    }
}

/// Import one item inside a response that is otherwise acceptable: under
/// compaction the item stands alone, and under assistant_response a trailing
/// call means no answer rule applies.
fn importTestingItem(tmp: *std.testing.TmpDir, item: []const u8, operation: output_format.ModelOperationKind) !void {
    const trailer = "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"t\",\"name\":\"bash\",\"call_id\":\"t\",\"arguments\":\"{}\"}}\n\n";
    const sse = try std.testing.allocator.print(
        "data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n{s}" ++
            "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}}}\n\n",
        .{ item, if (operation == .compaction) "" else trailer },
    );
    defer std.testing.allocator.free(sse);
    _ = try validateTestingOperation(tmp, sse, 64 * 1024, operation);
}

const long_type_item = "{\"type\":\"" ++ @as([max_evidence_bytes + 1]u8, @splat('m')) ++ "\",\"id\":\"m\"}";

/// Shapes the replay tables leave out, each judged by both entry points.
const agreement_cases = [_]struct { item: []const u8, compatible: bool, operation: output_format.ModelOperationKind = .assistant_response, omits_reasoning_text: bool = false }{
    // Another kind leaves `content` open, even duplicated.
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"content\":1,\"content\":2}", .compatible = true },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"reasoning_text\",\"text\":\"private\"}]}", .compatible = true, .omits_reasoning_text = true },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"caller\":\"direct\"}", .compatible = false },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"caller\":{}}", .compatible = false },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"caller\":{\"type\":7}}", .compatible = false },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"async\":\"false\"}", .compatible = false },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"namespace\":17}", .compatible = false },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"\",\"call_id\":\"c\",\"arguments\":\"{}\"}", .compatible = false },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"arguments\":\"{}\"}", .compatible = false },
    .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":null}", .compatible = false },
    .{ .item = "{\"type\":\"message\",\"id\":\"\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", .compatible = false },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"status\":null,\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", .compatible = false },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"phase\":42,\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", .compatible = false },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":{}}", .compatible = false },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\"}", .compatible = false },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[\"ok\"]}", .compatible = false },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"annotations\":{}}]}", .compatible = false },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"annotations\":[{}]}]}", .compatible = false },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\"}]}", .compatible = false },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"refusal\",\"refusal\":null}]}", .compatible = false },
    .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"no\",\"text\":1,\"text\":2}]}", .compatible = true },
    .{ .item = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"summary\":[{\"text\":\"untyped\"}]}", .compatible = false },
    .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"opaque\",\"internal_chat_message_metadata_passthrough\":[]}", .compatible = false, .operation = .compaction },
    .{ .item = long_type_item, .compatible = false },
};

test "import accepts exactly the items replay accepts and names the same broken rule" {
    const Case = struct { item: []const u8, operation: output_format.ModelOperationKind, compatible: ?bool, failure: ?anyerror = null, omits_reasoning_text: bool = false };
    var cases: [replay_cases.len + replay_failure_cases.len + agreement_cases.len]Case = undefined;
    for (replay_cases, 0..) |case, i| cases[i] = .{ .item = case.item, .operation = case.operation, .compatible = case.supported, .omits_reasoning_text = case.omits_reasoning_text };
    for (replay_failure_cases, 0..) |case, i| cases[replay_cases.len + i] = .{ .item = case.item, .operation = case.operation, .compatible = null, .failure = case.failure };
    for (agreement_cases, 0..) |case, i| cases[replay_cases.len + replay_failure_cases.len + i] = .{ .item = case.item, .operation = case.operation, .compatible = case.compatible, .omits_reasoning_text = case.omits_reasoning_text };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases) |case| {
        const imported: ?anyerror = if (importTestingItem(&tmp, case.item, case.operation)) |_| null else |err| err;
        const source = try testingObject(&tmp, case.item);
        defer source.file.close(std.testing.io);
        const verdict = judgeFile(std.testing.io, source.file, case.item.len, case.operation) catch |err| {
            try std.testing.expectEqual(case.failure orelse return error.TestUnexpectedError, err);
            try std.testing.expectEqual(error.SyntaxError, err);
            try std.testing.expect(imported != null);
            continue;
        };
        if (case.failure) |failure| if (failure == error.DuplicateJsonField) {
            try std.testing.expect(verdict == .incompatible and imported != null);
            continue;
        };
        try std.testing.expectEqual(case.compatible, verdict == .compatible);
        switch (verdict) {
            .compatible => |compatible| {
                try std.testing.expectEqual(@as(?anyerror, null), imported);
                try std.testing.expectEqual(case.omits_reasoning_text, compatible.omit_reasoning_text);
            },
            .incompatible => |reason| try std.testing.expectEqual(@as(?anyerror, reason), imported),
        }
    }
}

test "import names the first rule broken in lookup order" {
    const cases = [_]struct {
        item: []const u8,
        operation: output_format.ModelOperationKind,
        import: anyerror,
    }{
        // Status is looked up before content blocks.
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"status\":\"future\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"text\":\"other\"}]}", .operation = .assistant_response, .import = error.UnsupportedItemStatus },
        .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"status\":\"future\",\"encrypted_content\":\"a\",\"encrypted_content\":\"b\"}", .operation = .compaction, .import = error.UnsupportedItemStatus },
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"status\":\"future\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"annotations\":[],\"annotations\":false}]}", .operation = .assistant_response, .import = error.UnsupportedItemStatus },
        // Blocks are judged in order.
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"future_text\"},{\"type\":\"output_text\",\"text\":\"a\",\"text\":\"b\"}]}", .operation = .assistant_response, .import = error.UnsupportedContentBlock },
        .{ .item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"a\",\"text\":\"b\"},{\"type\":\"future_text\"}]}", .operation = .assistant_response, .import = error.DuplicateJsonField },
        // Type, ID and metadata come before every other rule.
        .{ .item = "{\"type\":\"message\",\"type\":\"message\",\"id\":\"m\",\"status\":\"future\"}", .operation = .assistant_response, .import = error.DuplicateJsonField },
        // The Operation is checked after type, ID and metadata, before the
        // kind's own rules.
        .{ .item = "{\"type\":\"compaction\",\"id\":\"c\"}", .operation = .assistant_response, .import = error.UnsupportedProviderOutput },
        .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"\",\"arguments\":\"{}\"}", .operation = .compaction, .import = error.UnsupportedProviderOutput },
        .{ .item = "{\"type\":\"function_call\",\"id\":\"f\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\",\"caller\":{\"type\":null}}", .operation = .compaction, .import = error.UnsupportedProviderOutput },
        .{ .item = "{\"type\":\"compaction\",\"id\":\"c\",\"internal_chat_message_metadata_passthrough\":{\"cell_id\":1}}", .operation = .assistant_response, .import = error.UnsupportedMetadataAuthority },
        .{ .item = "{\"type\":\"function_call\",\"id\":\"\",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\"}", .operation = .compaction, .import = error.EmptyProviderIdentity },
        .{ .item = "{\"type\":\"reasoning\",\"id\":\"\",\"status\":\"future\",\"encrypted_content\":\"opaque\"}", .operation = .assistant_response, .import = error.EmptyProviderIdentity },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases) |case| {
        try std.testing.expectError(case.import, importTestingItem(&tmp, case.item, case.operation));
        const source = try testingObject(&tmp, case.item);
        defer source.file.close(std.testing.io);
        try expectIncompatible(case.import, try judgeFile(std.testing.io, source.file, case.item.len, case.operation));
    }
}

test "the item grammar streams opaque windows and preserves syntax failures" {
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
    try expectCompatible(try judgeFile(std.testing.io, file, prefix.len + 3 * window.len + suffix.len, .assistant_response));
    const item = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, &window, &window, &window, suffix });
    defer std.testing.allocator.free(item);
    try importTestingItem(&tmp, item, .assistant_response);

    const invalid = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"future\":\"\xff\"}";
    const source = try testingObject(&tmp, invalid);
    defer source.file.close(std.testing.io);
    try std.testing.expectError(error.InvalidJsonUtf8, judgeFile(std.testing.io, source.file, invalid.len, .assistant_response));
    try std.testing.expectError(error.InvalidJsonUtf8, importTestingItem(&tmp, invalid, .assistant_response));
}

test "every item of the grammar tables is interpreted beside its validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const before = Oracle.accepted + Oracle.rejected;
    var items: u64 = 0;
    inline for (.{ replay_cases, replay_failure_cases, agreement_cases }) |cases| for (cases) |case| {
        importTestingItem(&tmp, case.item, case.operation) catch {};
        items += 1;
    };
    try std.testing.expectEqual(before + items, Oracle.accepted + Oracle.rejected);
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
        var item_check: OutputItemCheck = .{ .operation = .assistant_response };
        var turns: usize = 0;
        while (true) {
            turns += 1;
            try std.testing.expect(turns < 100000);
            const before = source.read_bytes;
            var bytes: usize = 7;
            var items: usize = 2;
            const finished = try item_check.advance(&source, &bytes, &items);
            try std.testing.expect(source.read_bytes - before <= 7);
            try std.testing.expectEqual(@as(u64, 7 - bytes), source.read_bytes - before);
            try std.testing.expect(items <= 2);
            if (finished) |verdict| {
                if (supported) try expectCompatible(verdict) else try expectIncompatible(error.UnsupportedCaller, verdict);
                try std.testing.expectEqual(source.length, source.read_bytes);
                break;
            }
        }
        try std.testing.expect(turns > 10000);
    }
}

test "a call's four decoded fields stream with fixed storage" {
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
    var expected: [4]OutputItemCheck.DecodedField = undefined;
    for ([_][]const u8{ "item", "bash", "call", "a\x00🚀" }, &expected) |value, *field|
        field.* = .{ .length = value.len, .digest = protocol.contentDigest(value) };
    var item_check: OutputItemCheck = .{ .operation = .assistant_response };
    var turns: usize = 0;
    while (true) {
        var bytes: usize = 1;
        var items: usize = 1;
        turns += 1;
        if (try item_check.advance(source, &bytes, &items)) |verdict| {
            try expectCompatible(verdict);
            break;
        }
    }
    try std.testing.expect(turns >= source.bytes.len);
    try expectDecodedFields(&item_check, expected);
    try std.testing.expect(@sizeOf(@TypeOf(item_check.decoded_fields)) == 160);
}

test "long strings decode and locate exactly across read windows" {
    const Source = struct {
        bytes: []const u8,
        pub fn contentLength(source: @This()) u64 {
            return source.bytes.len;
        }
        pub fn readContent(source: @This(), offset: u64, destination: []u8) !usize {
            @memcpy(destination, source.bytes[@intCast(offset)..][0..destination.len]);
            return destination.len;
        }
    };
    // Long plain runs broken by escapes, an escaped quote and multibyte text,
    // in a key, in the call's own strings and in an open field.
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    var decoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer decoded.deinit();
    for (0..40) |i| {
        const run: [100]u8 = @splat(@intCast('a' + i % 26));
        try encoded.writer.writeAll(run[0 .. 60 + i]);
        try decoded.writer.writeAll(run[0 .. 60 + i]);
        switch (i % 4) {
            0 => {
                try encoded.writer.writeAll("\\\"");
                try decoded.writer.writeAll("\"");
            },
            1 => {
                try encoded.writer.writeAll("\\u00e9\\n");
                try decoded.writer.writeAll("\u{e9}\n");
            },
            2 => {
                try encoded.writer.writeAll("\u{1f680}");
                try decoded.writer.writeAll("\u{1f680}");
            },
            else => {},
        }
    }
    const text = encoded.written();
    const item = try std.testing.allocator.print(
        "{{\"future_{s}\":\"{s}\",\"arguments\" : \"{s}\",\"call_id\":\"{s}\",\"name\":\"bash\",\"id\":\"{s}\",\"type\":\"function_call\"}}",
        .{ text[0..200], text, text, text, text },
    );
    defer std.testing.allocator.free(item);
    var expected: [4]OutputItemCheck.DecodedField = undefined;
    for ([_][]const u8{ decoded.written(), "bash", decoded.written(), decoded.written() }, &expected) |value, *field|
        field.* = .{ .length = value.len, .digest = protocol.contentDigest(value) };
    for ([_]usize{ 1, 7, protocol.content_window_bytes - 1, protocol.content_window_bytes, protocol.content_window_bytes + 1 }) |allowance| {
        var item_check: OutputItemCheck = .{ .operation = .assistant_response };
        while (true) {
            var bytes = allowance;
            var items: usize = 1;
            if (try item_check.advance(Source{ .bytes = item }, &bytes, &items)) |verdict| {
                try expectCompatible(verdict);
                break;
            }
        }
        try expectDecodedFields(&item_check, expected);
        // Each located value is exactly the encoded text after its key.
        for ([_]usize{ 0, 2, 3 }) |field| {
            const span = item_check.encoded_spans[field];
            const start = std.mem.indexOfScalarPos(u8, item, @intCast(span.after_key), '"').? + 1;
            try std.testing.expectEqualStrings(text, item[start..@intCast(span.end)]);
        }
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try importTestingItem(&tmp, item, .assistant_response);
}

const Added = struct {
    active: bool = false,
    index: u64 = 0,
    kind: output_format.OutputItemKind = .reasoning,
    id_digest: [32]u8 = @splat(0),
};

fn itemIdentity(window: *Window, item: Range) !struct {
    kind: output_format.OutputItemKind,
    id_digest: [32]u8,
} {
    const fields = try readFields(window, item, &.{ "type", "id" });
    var kind_name: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(window, try fields.required("type"), &kind_name);
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
        .id_digest = try stringDigest(window, try fields.required("id")),
    };
}

/// Read the usage counts while validating provider bytes, not during Store
/// replay. The raw usage range remains private immutable evidence.
pub fn readUsage(io: std.Io, file: std.Io.File, start: u64, length: u64) !?output_format.Usage {
    var window: Window = .{ .io = io, .file = file };
    return responsesUsage(&window, .{ .start = start, .length = length });
}

/// Maps a Responses usage report onto Rui's four counts. `input_tokens`
/// includes the cached ones, and Responses bills no cache writes. A report
/// with a count missing, repeated or outside a whole SQLite integer is not
/// usable; pressure then falls back to the Store's estimate.
fn responsesUsage(window: *Window, usage: Range) !?output_format.Usage {
    const fields = try readFields(window, usage, &.{ "input_tokens", "output_tokens", "input_tokens_details" });
    const input = try tokenCount(window, fields.get("input_tokens") catch return null) orelse return null;
    const output = try tokenCount(window, fields.get("output_tokens") catch return null) orelse return null;
    var cached: u64 = 0;
    const details = fields.get("input_tokens_details") catch return null;
    if (details) |range| if (!try rangeEquals(window, range, "null")) {
        const detail = readFields(window, range, &.{"cached_tokens"}) catch |err| switch (err) {
            error.UnexpectedJsonDelimiter => return null,
            else => return err,
        };
        if (detail.get("cached_tokens") catch return null) |count|
            cached = try tokenCount(window, count) orelse return null;
    };
    if (cached > input) return null;
    return .{ .uncached = input - cached, .cache_read = cached, .cache_write = 0, .output = output };
}

fn tokenCount(window: *Window, value: ?Range) !?u64 {
    const range = value orelse return null;
    const count = readIndex(window, range) catch |err| switch (err) {
        error.InvalidProviderIndex, error.TrailingJson, error.Overflow => return null,
        else => return err,
    };
    return if (count > std.math.maxInt(i64)) null else count;
}

fn validateCompleted(
    window: *Window,
    response: Range,
    metadata: *output_format.OutputMetadataWriter,
    expected_items: u64,
    evidence: *Evidence,
) !void {
    const fields = try readFields(window, response, &.{ "status", "id", "model", "output", "usage" });
    var status: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(window, try fields.required("status"), &status);
    if (!status.eql("completed")) return error.UnsupportedResponseStatus;
    _ = try readString(window, try fields.required("id"), &evidence.response_id);
    if (evidence.response_id.len == 0) return error.EmptyProviderIdentity;
    if (try fields.get("model")) |model| {
        if (!try rangeEquals(window, model, "null")) {
            var wide: protocol.Bounded(max_evidence_bytes) = .{};
            _ = try readString(window, model, &wide);
            if (wide.len == 0) return error.EmptyProviderIdentity;
            try evidence.served_model.set(wide.slice());
        }
    }
    const output = try fields.required("output");
    var array = try Array.init(window, output);
    var reader = try output_format.OutputMetadataReader.init(window.io, metadata.file, expected_items);
    var index: u64 = 0;
    while (try array.next()) |terminal_item| {
        const identity = try itemIdentity(window, terminal_item);
        const content_digest = try contentDigestRange(window, terminal_item);
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
        if (try rangeEquals(window, usage, "null")) return;
        try metadata.append(.{
            .tag = .usage,
            .start = usage.start,
            .length = usage.length,
            .content_digest = try contentDigestRange(window, usage),
            .usage = try responsesUsage(window, usage),
        });
    }
}

const AnswerSelection = output_decode.AnswerSelection;

/// Tests' item grammar storage, off their stacks like the Host's. Tests run
/// one at a time and each use finishes before the next starts.
var testing_item_check: OutputItemCheck = undefined;

pub fn testingItemCheck() *OutputItemCheck {
    comptime std.debug.assert(@import("builtin").is_test);
    return &testing_item_check;
}

/// Judge one complete item in memory the way acceptance does, for tests that
/// save output without a provider stream.
pub fn judgeForTesting(item: []const u8, operation: output_format.ModelOperationKind) !OutputItemCheck.Verdict {
    const item_check = testingItemCheck();
    item_check.reset(operation);
    const Source = struct {
        bytes: []const u8,

        pub fn contentLength(self: @This()) u64 {
            return self.bytes.len;
        }

        pub fn readContent(self: @This(), offset: u64, destination: []u8) !usize {
            @memcpy(destination, self.bytes[@intCast(offset)..][0..destination.len]);
            return destination.len;
        }
    };
    var bytes: usize = std.math.maxInt(usize);
    var items: usize = std.math.maxInt(usize);
    return (try item_check.advance(Source{ .bytes = item }, &bytes, &items)).?;
}

/// Record one complete item already in `source` at `start` the way
/// acceptance records it: its call fields, Rui's form, its bags and then
/// the item record. Tests that save output without a provider stream use
/// it so their metadata is what acceptance would write.
/// The record that closes an accepted item's metadata.
fn itemRecord(window: *Window, item: Range, ordinal: u64, validation: ItemValidation) !output_format.OutputMetadataRecord {
    return .{
        .tag = .item,
        .kind = validation.kind,
        .ordinal = ordinal,
        .start = item.start,
        .length = item.length,
        .id_digest = validation.id_digest,
        .content_digest = try contentDigestRange(window, item),
        .omit_reasoning_text = validation.omit_reasoning_text,
        .phase = validation.neutral_phase,
    };
}

pub fn recordItemForTesting(metadata: *output_format.OutputMetadataWriter, source: std.Io.File, start: u64, length: u64, ordinal: u64, operation: output_format.ModelOperationKind) !output_format.OutputMetadataRecord {
    var window: Window = .{ .io = metadata.io, .file = source };
    var rejection: Rejection = .{};
    var response: Response = .{
        .metadata = metadata,
        .operation = operation,
        .rejection = &rejection,
        .provider_failure = testingProviderFailure(),
        .answer = .{ .digest = protocol.contentDigest("") },
        .item_check = testingItemCheck(),
    };
    const item: Range = .{ .start = start, .length = length };
    const validation = try validateItem(&response, &window, item, ordinal);
    const record = try itemRecord(&window, item, ordinal, validation);
    try metadata.append(record);
    return record;
}

/// Tests' provider failure, the last validation's.
var testing_provider_failure: ProviderFailure = undefined;

pub fn testingProviderFailure() *ProviderFailure {
    comptime std.debug.assert(@import("builtin").is_test);
    return &testing_provider_failure;
}

/// One response's validation, from its first event to its last.
const Response = struct {
    metadata: *output_format.OutputMetadataWriter,
    operation: output_format.ModelOperationKind,
    rejection: *Rejection,
    provider_failure: *ProviderFailure,
    added: Added = .{},
    completed: bool = false,
    item_count: u64 = 0,
    call_count: u64 = 0,
    compaction_count: u64 = 0,
    answer: AnswerSelection,
    evidence: Evidence = .{},
    /// The item grammar's fixed storage, reused for every item.
    item_check: *OutputItemCheck,
};

fn processEvent(response: *Response, window: *Window, event: Range, raw_start: u64) !void {
    const metadata = response.metadata;
    const rejection = response.rejection;
    const added = &response.added;
    rejection.* = .{ .stage = .event, .byte_offset = raw_start };
    if (response.completed) return error.LateProviderOutput;
    var kind: protocol.Bounded(max_evidence_bytes) = .{};
    const fields = try readFields(window, event, &.{ "type", "output_index", "item", "response" });
    _ = try readString(window, try fields.required("type"), &kind);
    if (kind.eql("response.output_item.added")) {
        if (added.active) return error.ContradictoryProviderOutput;
        const index = try readIndex(window, try fields.required("output_index"));
        rejection.output_index = index;
        if (index != response.item_count) return error.ContradictoryProviderOutput;
        const identity = try itemIdentity(window, try fields.required("item"));
        added.* = .{ .active = true, .index = index, .kind = identity.kind, .id_digest = identity.id_digest };
        return;
    }
    if (kind.eql("response.output_item.done")) {
        const index = try readIndex(window, try fields.required("output_index"));
        rejection.stage = .item;
        rejection.output_index = index;
        if (index != response.item_count) return error.ContradictoryProviderOutput;
        const item = try fields.required("item");
        const validation = try validateItem(response, window, item, index);
        if (added.active and (added.index != index or added.kind != validation.kind or
            !std.mem.eql(u8, &added.id_digest, &validation.id_digest))) return error.ContradictoryProviderOutput;
        added.active = false;
        switch (validation.kind) {
            .compaction => {
                response.compaction_count += 1;
                if (response.compaction_count > 1) return error.UnsupportedProviderOutput;
            },
            .message => response.answer.accept(&.{ .ordinal = index, .phase = validation.phase, .length = validation.text_length, .digest = validation.text_digest, .non_whitespace = validation.non_whitespace }),
            .function_call => response.call_count += 1,
            .reasoning => {},
        }
        try metadata.append(try itemRecord(window, item, index, validation));
        response.item_count += 1;
        return;
    }
    if (kind.eql("response.completed")) {
        rejection.stage = .response;
        // Each unmet completion requirement keeps its own reason so a saved
        // rejection says which one failed; all share the malformed code.
        if (added.active) return error.UnfinishedProviderOutputItem;
        if (response.item_count == 0) return error.MissingProviderOutputItems;
        if (response.answer.finals > 1) return error.MultipleFinalAnswers;
        if (response.operation == .assistant_response and response.answer.ordinal == null and response.call_count == 0) return error.MissingAssistantAnswer;
        if (response.operation == .compaction and response.compaction_count != 1) return error.MissingCompactionItem;
        try validateCompleted(window, try fields.required("response"), metadata, response.item_count, &response.evidence);
        try metadata.sealForRead();
        response.completed = true;
        return;
    }
    if (kind.eql("error") or kind.eql("response.failed")) return streamError(window, event, kind.eql("response.failed"), response.provider_failure);
    if (kind.eql("response.incomplete")) {
        if (incompleteOverflow(window, event) catch |err| try malformedEnvelope(err)) return error.ContextOverflow;
        return error.IncompleteProviderOutput;
    }
    if (std.mem.startsWith(u8, kind.slice(), "response.output_item.")) return error.UnsupportedEventType;
}

fn rangeEquals(window: *Window, range: Range, expected: []const u8) !bool {
    if (range.length != expected.len) return false;
    var source = try FileSource.init(window, range);
    var equal = true;
    for (expected) |byte| equal = try source.take() == byte and equal;
    return equal;
}

fn contentDigestRange(window: *Window, range: Range) ![32]u8 {
    var hash = protocol.contentHasher();
    var offset = range.start;
    const end = try std.math.add(u64, range.start, range.length);
    while (offset < end) {
        const bytes = try window.bytesAt(offset, end);
        hash.update(bytes);
        offset += bytes.len;
    }
    return hash.finalResult();
}

pub fn validate(
    io: std.Io,
    source_file: std.Io.File,
    source_length: u64,
    metadata: *output_format.OutputMetadataWriter,
    event_data: *EventData,
    operation: output_format.ModelOperationKind,
    rejection: *Rejection,
    /// What a provider error event said, when validation fails on one.
    provider_failure: *ProviderFailure,
    /// The item grammar's storage, larger than most frames. A caller keeps
    /// it off the stack: a frame that holds it makes all of its pages
    /// resident, while one item touches only a few.
    item_check: *OutputItemCheck,
    faults: Faults,
) !Validated {
    if (comptime @import("builtin").is_test) {
        const before: Oracle.Before = .of(metadata, event_data, faults);
        const result: anyerror!Validated = validateStream(io, source_file, source_length, metadata, event_data, operation, rejection, provider_failure, item_check, faults);
        Oracle.check(&before, io, source_file, source_length, metadata, event_data, operation, &result, rejection, provider_failure);
        return result;
    } else return validateStream(io, source_file, source_length, metadata, event_data, operation, rejection, provider_failure, item_check, faults);
}

/// In tests, every stream validated here is interpreted again by the
/// codec's interpreter under several window cuts, and both must agree:
/// the same acceptance, event data and metadata, or the same rejection
/// detail, which names the error and its coordinates, with the same
/// provider report.
const Oracle = struct {
    // Tests validate one at a time on the test thread: no unit test runs a
    // Host's execution thread, so one interpretation's storage serves all.
    var storage: output_decode.Interpret = undefined;
    var events: EventData = undefined;
    /// The streams compared, by today's verdict on them.
    var accepted: u64 = 0;
    var rejected: u64 = 0;
    const cuts = [_]usize{ 1, 3, 64, protocol.content_window_bytes };

    /// The budgets and faults validation began with.
    const Before = struct {
        metadata_used: u64,
        event_used: u64,
        shared: bool,
        fail_writes: bool,
        metadata_records: u64,
        event_length: u64,

        fn of(metadata: *const output_format.OutputMetadataWriter, event_data: *const EventData, faults: Faults) Before {
            return .{
                .metadata_used = metadata.budget.used.load(.acquire),
                .event_used = event_data.budget.used.load(.acquire),
                .shared = metadata.budget.used == event_data.budget.used,
                .fail_writes = metadata.fail_writes or faults.metadata,
                .metadata_records = metadata.records,
                .event_length = event_data.length,
            };
        }
    };

    fn check(
        before: *const Before,
        io: std.Io,
        source_file: std.Io.File,
        source_length: u64,
        metadata: *output_format.OutputMetadataWriter,
        event_data: *EventData,
        operation: output_format.ModelOperationKind,
        today: *const anyerror!Validated,
        today_rejection: *const Rejection,
        today_failure: *const ProviderFailure,
    ) void {
        // Only a fresh validation's offsets compare.
        if (before.metadata_records != 0 or before.event_length != 0) return;
        if (today.*) |_| {
            accepted += 1;
        } else |_| rejected += 1;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        for (cuts) |most| {
            // Byte-at-a-time windows over a large capture repeat what the
            // other cuts show at a cost the suite does not need.
            if (most == 1 and source_length > 256 * 1024) continue;
            checkCut(before, &tmp, most, io, source_file, source_length, metadata, event_data, operation, today, today_rejection, today_failure) catch |err|
                std.debug.panic("interpret oracle, cut {d}: {t}", .{ most, err });
        }
    }

    fn checkCut(
        before: *const Before,
        tmp: *std.testing.TmpDir,
        most: usize,
        io: std.Io,
        source_file: std.Io.File,
        source_length: u64,
        metadata: *output_format.OutputMetadataWriter,
        event_data: *EventData,
        operation: output_format.ModelOperationKind,
        today: *const anyerror!Validated,
        today_rejection: *const Rejection,
        today_failure: *const ProviderFailure,
    ) !void {
        var metadata_used: std.atomic.Value(u64) = .init(before.metadata_used);
        var event_used: std.atomic.Value(u64) = .init(before.event_used);
        const event_file = try tmp.dir.createFile(io, "oracle-events", .{ .read = true, .truncate = true });
        events.window.io = io;
        events.window.file = event_file;
        events.window.start = 0;
        events.window.length = 0;
        events.budget = .{ .used = if (before.shared) &metadata_used else &event_used, .limit = event_data.budget.limit };
        events.length = 0;
        events.charged = 0;
        defer event_file.close(io);
        const metadata_file = try tmp.dir.createFile(io, "oracle-metadata", .{ .read = true, .truncate = true });
        defer metadata_file.close(io);
        var writer: output_format.OutputMetadataWriter = .{ .io = io, .file = metadata_file, .budget = .{ .used = &metadata_used, .limit = metadata.budget.limit }, .fail_writes = before.fail_writes };
        var rejection: Rejection = .{};
        var failure: ProviderFailure = undefined;
        const interpreter = @import("codecs.zig").interpreter(.@"openai-responses/1");
        var interpreted: Validated = undefined;
        const result = output_decode.interpret(&storage, interpreter, io, source_file, source_length, &writer, &events, operation, &rejection, &failure, .{ .most = most }, &interpreted);
        if (today.*) |*expected| {
            result catch |err| return disagree(most, "today accepts; the interpreter rejects with {t} at {any}", .{ err, rejection });
            inline for (.{ "source_length", "item_count", "call_count", "answer_item_ordinal", "answer_length" }) |name| {
                if (@field(expected, name) != @field(interpreted, name)) return disagree(most, name ++ ": today {any}, interpreted {any}", .{ @field(expected, name), @field(interpreted, name) });
            }
            if (!std.mem.eql(u8, &expected.answer_digest, &interpreted.answer_digest)) return disagree(most, "answer digests differ", .{});
            if (!expected.evidence.response_id.eql(interpreted.evidence.response_id.slice()) or
                !expected.evidence.served_model.eql(interpreted.evidence.served_model.slice())) return disagree(most, "evidence differs", .{});
            try sameFile(most, "event data", io, event_data.window.file, event_file);
            try sameFile(most, "metadata", io, metadata.file, metadata_file);
        } else |today_error| {
            const err = if (result) |_| return disagree(most, "today rejects with {t} at {any}; the interpreter accepts", .{ today_error, today_rejection.* }) else |err| err;
            // The saved detail names the error and its coordinates, and the
            // error decides the saved code and kind.
            var today_buffer: [512]u8 = undefined;
            var interpreted_buffer: [512]u8 = undefined;
            const today_detail = today_rejection.format(today_error, &today_buffer);
            const interpreted_detail = rejection.format(err, &interpreted_buffer);
            if (!std.mem.eql(u8, today_detail, interpreted_detail)) return disagree(most, "today rejects with {s}, the interpreter with {s}", .{ today_detail, interpreted_detail });
            if (today_failure.refusal != failure.refusal or !std.mem.eql(u8, today_failure.report.slice(), failure.report.slice()))
                return disagree(most, "{t}: provider failures differ: today {?t} \"{s}\", interpreted {?t} \"{s}\"", .{ err, today_failure.refusal, today_failure.report.slice(), failure.refusal, failure.report.slice() });
        }
    }

    fn disagree(most: usize, comptime format: []const u8, arguments: anytype) error{OracleDisagreement} {
        std.debug.print("interpret oracle, cut {d}: " ++ format ++ "\n", .{most} ++ arguments);
        return error.OracleDisagreement;
    }

    fn sameFile(most: usize, comptime what: []const u8, io: std.Io, expected: std.Io.File, actual: std.Io.File) !void {
        const length = try expected.length(io);
        if (length != try actual.length(io)) return disagree(most, what ++ " lengths differ: today {d}, interpreted {d}", .{ length, try actual.length(io) });
        var left: [4096]u8 = undefined;
        var right: [4096]u8 = undefined;
        var offset: u64 = 0;
        while (offset < length) {
            const count: usize = @intCast(@min(left.len, length - offset));
            _ = try expected.readPositionalAll(io, left[0..count], offset);
            _ = try actual.readPositionalAll(io, right[0..count], offset);
            if (!std.mem.eql(u8, left[0..count], right[0..count])) {
                const index = std.mem.indexOfDiff(u8, left[0..count], right[0..count]).?;
                return disagree(most, what ++ " differs at byte {d}", .{offset + index});
            }
            offset += count;
        }
    }
};

fn validateStream(
    io: std.Io,
    source_file: std.Io.File,
    source_length: u64,
    metadata: *output_format.OutputMetadataWriter,
    event_data: *EventData,
    operation: output_format.ModelOperationKind,
    rejection: *Rejection,
    /// What a provider error event said, when validation fails on one.
    provider_failure: *ProviderFailure,
    /// The item grammar's storage, larger than most frames. A caller keeps
    /// it off the stack: a frame that holds it makes all of its pages
    /// resident, while one item touches only a few.
    item_check: *OutputItemCheck,
    faults: Faults,
) !Validated {
    if (faults.metadata) metadata.fail_writes = true;
    var capture: Window = .{ .io = io, .file = source_file };
    var source = try FileSource.init(&capture, .{ .start = 0, .length = source_length });
    var data: ?Range = null;
    var raw_start: u64 = 0;
    var done_marker = false;
    provider_failure.clear();
    var response: Response = .{ .metadata = metadata, .operation = operation, .rejection = rejection, .provider_failure = provider_failure, .item_check = item_check, .answer = .{ .digest = protocol.contentDigest("") } };
    if (source_length >= 3 and try rangeEquals(&capture, .{ .start = 0, .length = 3 }, "\xef\xbb\xbf")) source.position = 3;
    while (source.offset() < source.end) {
        rejection.* = .{ .byte_offset = source.offset() };
        // SSE has three line endings. Retain only the field prefix; payload
        // reads and decoded data writes use fixed windows, never line buffers.
        const line_start = source.offset();
        var head: [16]u8 = undefined;
        while (true) {
            const bytes = try source.buffered();
            const length = std.mem.indexOfAny(u8, bytes, "\r\n") orelse bytes.len;
            const index = source.offset() - line_start;
            if (index < head.len) {
                const kept = @min(length, head.len - @as(usize, @intCast(index)));
                @memcpy(head[@intCast(index)..][0..kept], bytes[0..kept]);
            }
            source.skip(length);
            if (length < bytes.len or bytes.len == 0) break;
        }
        const line_end = source.offset();
        const ending = try source.peek();
        if (ending) |byte| {
            _ = try source.take();
            if (byte == '\r' and try source.peek() == '\n') _ = try source.take();
        }
        const line = Range{ .start = line_start, .length = line_end - line_start };
        const shown = head[0..@intCast(@min(line.length, head.len))];
        if (line.length == 0) {
            if (data) |payload| {
                if (payload.length == 0) return error.EmptySseData;
                if (try rangeEquals(&event_data.window, payload, "[DONE]")) {
                    if (!response.completed or done_marker) return error.ContradictoryProviderOutput;
                    done_marker = true;
                } else {
                    if (done_marker) return error.LateProviderOutput;
                    try processEvent(&response, &event_data.window, payload, raw_start);
                }
                data = null;
            }
            continue;
        }
        if (std.mem.eql(u8, shown, "data") or std.mem.startsWith(u8, shown, "data:")) {
            var skip: usize = @min(line.length, "data:".len);
            if (shown.len > skip and shown[skip] == ' ') skip += 1;
            if (data == null) {
                data = .{ .start = event_data.length, .length = 0 };
                raw_start = line.start + skip;
            } else try event_data.append("\n");
            try event_data.copy(&capture, line.start + skip, line.length - skip);
            data.?.length = event_data.length - data.?.start;
        }
        // Comments and every other field, including colonless fields, carry
        // no provider output authority. Field names are case-sensitive.
    }
    if (data != null) return error.IncompleteSseEvent;
    if (!response.completed) return error.ProviderConnectionClosed;
    try event_data.seal();
    return .{
        .source = event_data.window.file,
        .source_length = event_data.length,
        .item_count = response.item_count,
        .call_count = response.call_count,
        .answer_item_ordinal = response.answer.ordinal,
        .answer_length = response.answer.length,
        .answer_digest = response.answer.digest,
        .evidence = response.evidence,
    };
}

pub fn failureCode(err: anyerror) []const u8 {
    return switch (err) {
        error.ContextOverflow => "provider_context_overflow",
        error.TemporaryProviderFailure => "provider_temporary_error",
        error.ProviderConnectionClosed => "provider_transport_failure",
        error.EventDataScratchExhausted => "response_data_exhausted",
        error.EventDataWriteFailed, error.EventDataSealFailed => "response_data_failed",
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

fn testingObject(tmp: *std.testing.TmpDir, bytes: []const u8) !Window {
    const file = try tmp.dir.createFile(std.testing.io, "object", .{ .read = true });
    errdefer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
    return .{ .io = std.testing.io, .file = file };
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
    // These existing cases vary metadata's ceiling independently of payload.
    // Shared overlap and disposal are exercised with one budget below.
    var data_used: std.atomic.Value(u64) = .init(0);
    var event_data: EventData = undefined;
    try event_data.init(std.testing.io, root[0..root_length], "provider-test-data", .{ .used = &data_used, .limit = bytes.len }, false, &retained);
    defer event_data.deinit();
    const validated = try validate(std.testing.io, source, bytes.len, &metadata, &event_data, operation, rejection, testingProviderFailure(), testingItemCheck(), .{});
    const metadata_bytes = used.load(.acquire);
    var reader = try output_format.OutputMetadataReader.init(std.testing.io, metadata.file, validated.item_count);
    const first_item = (try reader.nextItem()).?;
    metadata.deinit();
    source.close(std.testing.io);
    return .{ .output = validated, .metadata_bytes = metadata_bytes, .first_item = first_item };
}

fn repeat(comptime text: []const u8, comptime count: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (0..count) |_| out = out ++ text;
    return out;
}

test "a provider error event keeps its refusal and the provider's own words" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const long = comptime repeat("é", 200);
    const cases = [_]struct { event: []const u8, err: anyerror, refusal: ?transport_policy.Refusal, report: []const u8 }{
        // The refusal that ended the bug-swarm Sessions, as a stream event.
        .{ .event = "{\"type\":\"error\",\"code\":\"cyber_policy\",\"message\":\"This request has been flagged for potentially high-risk cyber activity.\",\"param\":null}", .err = error.PermanentProviderFailure, .refusal = .cyber_policy, .report = "cyber_policy: This request has been flagged for potentially high-risk cyber activity." },
        .{ .event = "{\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"code\":\"model_not_found\",\"message\":\"No such model.\"}}}", .err = error.PermanentProviderFailure, .refusal = .model_not_found, .report = "model_not_found: No such model." },
        // A retryable failure keeps its words too; an object's type stands in
        // for a missing code, and line breaks read as spaces.
        .{ .event = "{\"type\":\"error\",\"error\":{\"type\":\"server_error\",\"message\":\"Overloaded,\\ntry\\tlater.\"}}", .err = error.TemporaryProviderFailure, .refusal = null, .report = "server_error: Overloaded, try later." },
        // An event's own type is only its name.
        .{ .event = "{\"type\":\"error\",\"code\":null,\"message\":\"Something failed.\"}", .err = error.TemporaryProviderFailure, .refusal = null, .report = "Something failed." },
        // A malformed message is left out; the code still decides.
        .{ .event = "{\"type\":\"error\",\"code\":\"insufficient_quota\",\"message\":7}", .err = error.PermanentProviderFailure, .refusal = .insufficient_quota, .report = "insufficient_quota" },
        // A long message keeps its first 256 bytes, cut at a whole scalar.
        .{ .event = "{\"type\":\"error\",\"code\":\"bio_policy\",\"message\":\"" ++ long ++ "\"}", .err = error.PermanentProviderFailure, .refusal = .bio_policy, .report = "bio_policy: " ++ comptime repeat("é", 128) ++ "…" },
        .{ .event = "{\"type\":\"error\",\"code\":\"bio_policy\",\"message\":\"x" ++ long ++ "\"}", .err = error.PermanentProviderFailure, .refusal = .bio_policy, .report = "bio_policy: x" ++ comptime repeat("é", 127) ++ "…" },
        .{ .event = "{\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":null}}", .err = error.TemporaryProviderFailure, .refusal = null, .report = "" },
        // An overflow keeps its words too; DEL reads as a space.
        .{ .event = "{\"type\":\"error\",\"code\":\"context_length_exceeded\",\"message\":\"Too\\u007flong.\"}", .err = error.ContextOverflow, .refusal = null, .report = "context_length_exceeded: Too long." },
    };
    for (cases) |case| {
        const sse = try std.mem.concat(std.testing.allocator, u8, &.{ "data: ", case.event, "\n\n" });
        defer std.testing.allocator.free(sse);
        try std.testing.expectError(case.err, validateTestingSse(&tmp, sse, 4096));
        try std.testing.expectEqual(case.refusal, testingProviderFailure().refusal);
        try std.testing.expectEqualStrings(case.report, testingProviderFailure().report.slice());
        try std.testing.expect(testingProviderFailure().report.len <= protocol.max_report_bytes);
    }
}

test "provider refusal preserves text and rejects malformed or incomplete candidates" {
    const refusal = "{\"type\":\"message\",\"id\":\"refused\",\"role\":\"assistant\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"Cannot help. é\\n\",\"text\":\"not the refusal\",\"annotations\":false,\"future\":true}]}";
    const done = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ refusal ++ "}\n\n";
    const completed = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}\n\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try validateTestingSse(&tmp, done ++ completed, 4096);
    try std.testing.expectEqual(@as(u64, "Cannot help. é\n".len), result.output.answer_length);
    try std.testing.expectEqual(protocol.contentDigest("Cannot help. é\n"), result.output.answer_digest);
    try std.testing.expectEqual(protocol.contentDigest(refusal), result.first_item.content_digest);
    const source = try testingObject(&tmp, refusal);
    defer source.file.close(std.testing.io);
    try expectCompatible(try judgeFile(std.testing.io, source.file, refusal.len, .assistant_response));
    try std.testing.expectError(error.ProviderConnectionClosed, validateTestingSse(&tmp, done, 4096));
    try std.testing.expectError(error.IncompleteProviderOutput, validateTestingSse(&tmp, done ++ "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\"}}\n\n", 4096));
    const delta = "data: {\"type\":\"response.refusal.delta\",\"delta\":\"not an answer\"}\n\n";
    try std.testing.expectError(error.MissingProviderOutputItems, validateTestingSse(&tmp, delta ++ completed, 4096));
    const future = try validateTestingSse(&tmp, "data: {\"type\":\"response.refusal.future\",\"refusal\":\"not an answer\"}\n\n" ++ done ++ completed, 4096);
    try std.testing.expectEqual(protocol.contentDigest("Cannot help. é\n"), future.output.answer_digest);
    try std.testing.expectEqual(protocol.contentDigest(refusal), future.first_item.content_digest);
    const malformed = [_]struct { block: []const u8, failure: anyerror }{
        .{ .block = "{\"type\":\"refusal\"}", .failure = error.MissingProviderField },
        .{ .block = "{\"type\":\"refusal\",\"refusal\":null}", .failure = error.ExpectedJsonString },
        .{ .block = "{\"type\":\"refusal\",\"refusal\":\"a\",\"refusal\":\"b\"}", .failure = error.DuplicateJsonField },
        .{ .block = "{\"type\":\"future_refusal\",\"refusal\":\"no\"}", .failure = error.UnsupportedContentBlock },
    };
    for (malformed) |case| {
        const item = try std.testing.allocator.print("{{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{s}]}}", .{case.block});
        defer std.testing.allocator.free(item);
        const stream = try std.testing.allocator.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{s}}}\n\n{s}", .{ item, completed });
        defer std.testing.allocator.free(stream);
        try std.testing.expectError(case.failure, validateTestingSse(&tmp, stream, 4096));
        const invalid = try testingObject(&tmp, item);
        defer invalid.file.close(std.testing.io);
        try expectIncompatible(case.failure, try judgeFile(std.testing.io, invalid.file, item.len, .assistant_response));
    }
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

test "SSE line framing accepts spec fields and line endings without losing validation" {
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
        "data: " ++ done ++ "\r\rdata: " ++ completed ++ "\r\r",
        "\xef\xbb\xbfdata: " ++ done ++ "\n\ndata: " ++ completed ++ "\n\n",
        "bogus: x\nfield-without-colon\ndatax: ignored\nevent\nid\nretry\ndata: " ++ done ++ "\n\ndata: " ++ completed ++ "\n\n",
        "data\ndata: " ++ done ++ "\ndata:\n\ndata: " ++ completed ++ "\n\n",
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (accepted) |stream| {
        const result = try validateTestingSse(&tmp, stream, 4096);
        try std.testing.expectEqual(@as(u64, 2), result.output.answer_length);
        try std.testing.expectEqual(protocol.contentDigest("hi"), result.output.answer_digest);
        try std.testing.expectEqual(protocol.contentDigest(item), result.first_item.content_digest);
    }
    const rejected = [_]struct { anyerror, []const u8 }{
        .{ error.ProviderConnectionClosed, "dat: " ++ done ++ "\n\n" },
        .{ error.EmptySseData, "data:\n\n" },
        .{ error.EmptySseData, "data: \r\n\r\n" },
        .{ error.TrailingJson, "data: " ++ done ++ "\ndata: " ++ done ++ "\n\n" },
        .{ error.IncompleteSseEvent, "data: " ++ done ++ "\n\ndata: " ++ completed ++ "\n" },
        .{ error.IncompleteSseEvent, "data: " ++ done ++ "\n\ndata: " ++ completed },
        .{ error.ContradictoryProviderOutput, "data: " ++ done ++ "\n\ndata: [DONE]\n\n" },
        .{ error.LateProviderOutput, "data: " ++ done ++ "\n\ndata: " ++ completed ++ "\n\ndata: [DONE]\n\ndata: " ++ done ++ "\n\n" },
    };
    for (rejected) |case| try std.testing.expectError(case[0], validateTestingSse(&tmp, case[1], 4096));
}

test "SSE multiline data inserts exact newlines into retained items" {
    const fields = "\"type\":\"message\",\"id\":\"a\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi é\"}]}";
    const item = "{\n" ++ fields;
    const stream = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\r\n" ++
        ": keepalive\r\nfuture: ignored\r\ndata: " ++ fields ++ "}\r\n\r\n" ++
        "data: {\"type\":\"response.completed\",\rdata: \"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}\r\r";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const accepted = try validateTestingSse(&tmp, stream, 4096);
    try std.testing.expectEqual(@as(u64, "hi é".len), accepted.output.answer_length);
    try std.testing.expectEqual(protocol.contentDigest("hi é"), accepted.output.answer_digest);
    try std.testing.expectEqual(protocol.contentDigest(item), accepted.first_item.content_digest);
    try std.testing.expectError(error.InvalidJsonString, validateTestingSse(&tmp, "data: {\"type\":\"future.\ndata: notice\"}\n\n", 4096));
    try std.testing.expectError(error.UnexpectedJsonDelimiter, validateTestingSse(&tmp, "data: [DO\ndata: NE]\n\n", 4096));
    const prefix = ": raw-only prefix\nfuture: ignored\ndata: {\"type\":\"notice\"}\n\n";
    var rejection: Rejection = .{};
    try std.testing.expectError(error.MissingProviderField, validateTestingRejection(&tmp, prefix ++ "data: {\"type\":\"response.output_item.done\",\ndata: \"output_index\":0}\n\n", 4096, .assistant_response, &rejection));
    try std.testing.expectEqual(prefix.len + "data: ".len, rejection.byte_offset);
    try std.testing.expectEqual(.item, rejection.stage);
}

test "SSE decoded data shares scratch charges and retains failed unlink ownership" {
    const done = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}}";
    const terminal = "{\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}";
    const raw = "data: " ++ done ++ "\n\ndata: " ++ terminal ++ "\n\n";
    const decoded = done ++ terminal;
    for ([_]u64{ 0, 1 }) |shortfall| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try tmp.dir.createFile(std.testing.io, "raw", .{ .read = true });
        defer source.close(std.testing.io);
        try source.writeStreamingAll(std.testing.io, raw);
        var root_buffer: [protocol.max_store_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        var used: std.atomic.Value(u64) = .init(raw.len);
        const budget = protocol.ScratchBudget{ .used = &used, .limit = raw.len + decoded.len + 6 * output_format.output_metadata_record_bytes - shortfall };
        var retained: ?named_scratch.Owner = null;
        const descriptors = @import("os/descriptor_limit.zig");
        const baseline = (try descriptors.observe(std.testing.io)).open_descriptors;
        var metadata = try output_format.OutputMetadataWriter.init(std.testing.io, root, "metadata", budget, false, &retained);
        var data: EventData = undefined;
        try data.init(std.testing.io, root, "response-9-1.tmp", budget, false, &retained);
        try std.testing.expectEqual(baseline + 2, (try descriptors.observe(std.testing.io)).open_descriptors);
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "response-9-1.tmp", .{}));
        var rejection: Rejection = .{};
        if (shortfall == 0) {
            const result = try validate(std.testing.io, source, raw.len, &metadata, &data, .assistant_response, &rejection, testingProviderFailure(), testingItemCheck(), .{});
            var buffer: [raw.len]u8 = undefined;
            try std.testing.expectEqual(decoded.len, try result.source.readPositionalAll(std.testing.io, buffer[0..decoded.len], 0));
            try std.testing.expectEqualStrings(decoded, buffer[0..decoded.len]);
            try std.testing.expectEqual(budget.limit, used.load(.acquire));
        } else {
            try std.testing.expectError(error.EventDataScratchExhausted, validate(std.testing.io, source, raw.len, &metadata, &data, .assistant_response, &rejection, testingProviderFailure(), testingItemCheck(), .{}));
            try std.testing.expectEqual(raw.len + done.len + 6 * output_format.output_metadata_record_bytes, used.load(.acquire));
        }
        var buffer: [raw.len]u8 = undefined;
        try std.testing.expectEqual(raw.len, try source.readPositionalAll(std.testing.io, &buffer, 0));
        try std.testing.expectEqualStrings(raw, &buffer);
        metadata.deinit();
        data.deinit();
        try std.testing.expectEqual(baseline, (try descriptors.observe(std.testing.io)).open_descriptors);
        try std.testing.expectEqual(@as(u64, raw.len), used.load(.acquire));
        try std.testing.expectError(error.InjectedEventDataUnlinkFailure, data.init(std.testing.io, root, "response-9-1.tmp", budget, true, &retained));
        try std.testing.expect(named_scratch.isOwned("response-9-1.tmp"));
        try std.testing.expectError(error.InjectedScratchRemovalFailure, retained.?.reclaim(root));
        try std.testing.expectEqual(baseline + 1, (try descriptors.observe(std.testing.io)).open_descriptors);
        retained.?.resources.?.removal = .native;
        try std.testing.expectEqual(named_scratch.Reclamation.removed, try retained.?.reclaim(root));
        try std.testing.expectEqual(baseline, (try descriptors.observe(std.testing.io)).open_descriptors);
        try std.testing.expectEqual(@as(u64, raw.len), used.load(.acquire));
        budget.release(raw.len);
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    }
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

test "partial answer fixture selects only the final answer" {
    // Synthetic first-party fixture, not a live capture or executed upstream test:
    // openai/codex 970111f6cb62cc02fe36a82ea7d71b37a2889c97,
    // codex-rs/codex-api/src/sse/responses.rs:759-798.
    // Keep its added/done message shape; Rui requires output_index and a
    // completed envelope. No end_turn:false sampling behavior is inferred.
    const partial = "{\"id\":\"msg_partial\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"First result.\"}],\"phase\":\"partial_answer\"}";
    const final = "{\"id\":\"msg_final\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Final result.\"}],\"phase\":\"final_answer\"}";
    const stream = "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"msg_partial\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"phase\":\"partial_answer\"}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"First result.\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ partial ++ "}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ final ++ "}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp1\",\"status\":\"completed\",\"output\":[" ++ partial ++ "," ++ final ++ "]}}\n\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const accepted = try validateTestingSse(&tmp, stream, 4096);
    try std.testing.expectEqual(@as(u64, 2), accepted.output.item_count);
    try std.testing.expectEqual(@as(?u64, 1), accepted.output.answer_item_ordinal);
    try std.testing.expectEqual(@as(u64, "Final result.".len), accepted.output.answer_length);
    try std.testing.expectEqual(protocol.contentDigest("Final result."), accepted.output.answer_digest);
}

test "message phases select one answer without dropping or concatenating text" {
    const cases = [_]struct { first: []const u8, second: []const u8, answer: ?[]const u8 = null, failure: ?anyerror = null }{
        .{ .first = "", .second = "", .answer = "second é" },
        .{ .first = ",\"phase\":null", .second = "", .answer = "second é" },
        .{ .first = ",\"phase\":\"commentary\"", .second = ",\"phase\":\"final_answer\"", .answer = "second é" },
        .{ .first = ",\"phase\":\"partial_answer\"", .second = ",\"phase\":\"final_answer\"", .answer = "second é" },
        .{ .first = ",\"phase\":\"final_answer\"", .second = ",\"phase\":\"partial_answer\"", .answer = "first" },
        .{ .first = ",\"phase\":\"partial_answer\"", .second = "", .failure = error.MissingAssistantAnswer },
        .{ .first = "", .second = ",\"phase\":\"partial_answer\"", .failure = error.MissingAssistantAnswer },
        .{ .first = ",\"phase\":\"partial_answer\"", .second = ",\"phase\":\"commentary\"", .failure = error.MissingAssistantAnswer },
        .{ .first = ",\"phase\":\"partial_answer\"", .second = ",\"phase\":\"partial_answer\"", .failure = error.MissingAssistantAnswer },
        .{ .first = "", .second = ",\"phase\":\"final_answer\"", .answer = "second é" },
        .{ .first = ",\"phase\":\"final_answer\"", .second = ",\"phase\":\"commentary\"", .answer = "first" },
        .{ .first = ",\"phase\":\"final_answer\"", .second = "", .answer = "first" },
        .{ .first = ",\"phase\":\"commentary\"", .second = "", .failure = error.MissingAssistantAnswer },
        .{ .first = "", .second = ",\"phase\":\"commentary\"", .failure = error.MissingAssistantAnswer },
        .{ .first = ",\"phase\":\"final_answer\"", .second = ",\"phase\":\"final_answer\"", .failure = error.MultipleFinalAnswers },
        .{ .first = ",\"phase\":\"analysis\"", .second = "", .failure = error.UnsupportedMessagePhase },
        .{ .first = ",\"phase\":\"partial_answers\"", .second = ",\"phase\":\"final_answer\"", .failure = error.UnsupportedMessagePhase },
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

test "responses usage maps onto Rui's four counts" {
    const Usage = output_format.Usage;
    const cases = [_]struct { []const u8, ?Usage }{
        .{ "{\"input_tokens\":7,\"output_tokens\":11,\"total_tokens\":18}", .{ .uncached = 7, .cache_read = 0, .cache_write = 0, .output = 11 } },
        .{ "{\"input_tokens\":100,\"input_tokens_details\":{\"cached_tokens\":64},\"output_tokens\":5}", .{ .uncached = 36, .cache_read = 64, .cache_write = 0, .output = 5 } },
        .{ "{\"input_tokens\":9,\"input_tokens_details\":null,\"output_tokens\":0}", .{ .uncached = 9, .cache_read = 0, .cache_write = 0, .output = 0 } },
        .{ "{\"input_tokens\":9,\"input_tokens_details\":{},\"output_tokens\":1}", .{ .uncached = 9, .cache_read = 0, .cache_write = 0, .output = 1 } },
        .{ "{\"input_tokens\":9,\"input_tokens_details\":{\"cached_tokens\":9},\"output_tokens\":1}", .{ .uncached = 0, .cache_read = 9, .cache_write = 0, .output = 1 } },
        .{ "{\"total_tokens\":18}", null },
        .{ "{\"input_tokens\":7}", null },
        .{ "{\"input_tokens\":7,\"output_tokens\":1.5}", null },
        .{ "{\"input_tokens\":-7,\"output_tokens\":1}", null },
        .{ "{\"input_tokens\":9223372036854775808,\"output_tokens\":1}", null },
        .{ "{\"input_tokens\":1,\"input_tokens\":2,\"output_tokens\":0}", null },
        .{ "{\"input_tokens\":9,\"input_tokens_details\":{\"cached_tokens\":10},\"output_tokens\":1}", null },
        .{ "{\"input_tokens\":9,\"input_tokens_details\":[],\"output_tokens\":1}", null },
        .{ "{\"input_tokens\":9,\"input_tokens_details\":{\"cached_tokens\":null},\"output_tokens\":1}", null },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases) |case| {
        const file = try tmp.dir.createFile(std.testing.io, "usage", .{ .read = true, .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, case[0]);
        try std.testing.expectEqual(case[1], try readUsage(std.testing.io, file, 0, case[0].len));
    }
}

test "context overflow requires exact valid provider code over SSE" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
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
        const source = try testingObject(&tmp, sse);
        defer source.file.close(std.testing.io);
        var root: [protocol.max_store_bytes]u8 = undefined;
        const path = root[0..try tmp.dir.realPath(std.testing.io, &root)];
        var used: std.atomic.Value(u64) = .init(0);
        var retained: ?named_scratch.Owner = null;
        const budget = protocol.ScratchBudget{ .used = &used, .limit = sse.len + 64 * 1024 };
        var metadata = try output_format.OutputMetadataWriter.init(std.testing.io, path, "metadata", budget, false, &retained);
        defer metadata.deinit();
        var data: EventData = undefined;
        try data.init(std.testing.io, path, "data", budget, false, &retained);
        defer data.deinit();
        var rejection: Rejection = .{};
        const accepted = try validate(std.testing.io, source.file, sse.len, &metadata, &data, .assistant_response, &rejection, testingProviderFailure(), testingItemCheck(), .{});
        try std.testing.expectEqual(@as(u64, 2), accepted.item_count);
        try std.testing.expectEqual(@as(u64, 0), accepted.call_count);
        try std.testing.expectEqual(@as(u64, 2), accepted.answer_length);
        try std.testing.expectEqualSlices(u8, &protocol.contentDigest("ok"), &accepted.answer_digest);
        var reader = try output_format.OutputMetadataReader.init(std.testing.io, metadata.file, accepted.item_count);
        const item = (try reader.nextItem()).?;
        try std.testing.expectEqual(output_format.OutputItemKind.reasoning, item.kind);
        try std.testing.expectEqual(@as(u64, 0), item.ordinal);
        try std.testing.expectEqual(reasoning.len, item.length);
        const retained_bytes = try std.testing.allocator.alloc(u8, reasoning.len);
        defer std.testing.allocator.free(retained_bytes);
        try std.testing.expectEqual(reasoning.len, try accepted.source.readPositionalAll(std.testing.io, retained_bytes, item.start));
        try std.testing.expectEqualStrings(reasoning, retained_bytes);
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
    // Per call: the item, three call fields, and an item bag of `id` and
    // `status` with its trailer.
    try std.testing.expectEqual(@as(u64, 2 * 7 * 104), accepted.metadata_bytes);

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
    try std.testing.expectEqual(@as(u64, 7 * 104), accepted.metadata_bytes);

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
    for ([_][]const u8{
        "{\"type\":\"response.metadata.future\",\"item\":null,\"output_index\":\"unused\"}",
        "{\"type\":\"codex.response.metadata\",\"response\":{\"status\":\"failed\"}}",
        "{\"type\":\"future.notice\",\"future\":[null,true,{}]}",
        "{\"type\":\"response.output_item_future\"}",
    }) |event| {
        const unknown = try std.testing.allocator.print("data: {s}\n\n", .{event});
        defer std.testing.allocator.free(unknown);
        const sse = try std.testing.allocator.print("{s}{s}{s}", .{ done, unknown, terminal });
        defer std.testing.allocator.free(sse);
        const accepted = try validateTestingSse(&tmp, sse, 4096);
        try std.testing.expectEqual(@as(u64, 1), accepted.output.item_count);
        try std.testing.expectEqual(@as(u64, 0), accepted.output.call_count);
        try std.testing.expectEqual(protocol.contentDigest("OK"), accepted.output.answer_digest);
        try std.testing.expectError(error.ProviderConnectionClosed, validateTestingSse(&tmp, unknown, 4096));
    }
    try std.testing.expectError(error.UnsupportedEventType, validateTestingSse(&tmp, "data: {\"type\":\"response.output_item.future\"}\n\n" ++ done ++ terminal, 4096));
    try std.testing.expectError(error.MissingProviderField, validateTestingSse(&tmp, "data: {\"type\":\"response.output_item.done\",\"output_index\":0}\n\n" ++ terminal, 4096));
    try std.testing.expectError(error.DuplicateJsonField, validateTestingSse(&tmp, "data: {\"type\":\"future.notice\",\"type\":\"response.completed\"}\n\n" ++ done ++ terminal, 4096));
    try std.testing.expectError(error.InvalidJsonValue, validateTestingSse(&tmp, "data: {\"type\":\"future.notice\",\"future\":!}\n\n" ++ done ++ terminal, 4096));
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
        action_count * 7 * 104,
    );
    try std.testing.expectEqual(@as(u64, action_count), validated.output.call_count);
    try std.testing.expectEqual(@as(u64, action_count * 7 * 104), validated.metadata_bytes);
    try std.testing.expect(@sizeOf(Validated) < protocol.content_window_bytes);
}

test "provider field collection traverses large open values once for all lookups" {
    const input = "{\"unknown\":\"" ++ @as([protocol.content_window_bytes * 4]u8, @splat('x')) ++
        "\",\"type\":\"message\",\"id\":\"m1\",\"status\":\"completed\",\"role\":\"assistant\"," ++
        "\"phase\":\"final_answer\",\"content\":[],\"internal_chat_message_metadata_passthrough\":{}}";
    const names = &.{ "type", "id", "status", "role", "phase", "content", "internal_chat_message_metadata_passthrough" };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var object = try testingObject(&tmp, input);
    defer object.file.close(std.testing.io);
    var source = try FileSource.init(&object, .{ .start = 0, .length = input.len });
    const fields = try collectFields(&source, names);
    inline for (names) |name| _ = try fields.required(name);
    try std.testing.expectEqual(input.len, source.position);
    // The former per-field lookup restarted at byte zero for each of these
    // seven names. The collector consumes exactly one object, with no rereads
    // on lookup, including an unknown value larger than the file window.
    const kind = try fields.required("type");
    try std.testing.expectEqualStrings("\"message\"", input[@intCast(kind.start)..][0..@intCast(kind.length)]);
}

test "plain runs stop at the first byte that needs a string check, at any position" {
    var bytes: [70]u8 = @splat('a');
    try std.testing.expectEqual(bytes.len, plainStringLength(&bytes));
    for (0..bytes.len) |position| {
        for ([_]u8{ '"', '\\', 0x00, 0x1f, 0x80, 0xc3, 0xff }) |special| {
            bytes[position] = special;
            try std.testing.expectEqual(position, plainStringLength(&bytes));
            try std.testing.expectEqual(position, plainStringLength(bytes[0 .. position + 1]));
            bytes[position] = 'a';
        }
    }
    try std.testing.expectEqual(@as(usize, 0), plainStringLength(""));
}

test "plain runs parse exactly like byte-at-a-time parsing" {
    // Lacks `buffered`, so parseString takes every byte through peek/take.
    const ByteSource = struct {
        bytes: []const u8,
        position: u64 = 0,
        fn offset(self: *const @This()) u64 {
            return self.position;
        }
        fn peek(self: *@This()) !?u8 {
            return if (self.position == self.bytes.len) null else self.bytes[@intCast(self.position)];
        }
        pub fn take(self: *@This()) !u8 {
            const byte = try self.peek() orelse return error.UnexpectedJsonEnd;
            self.position += 1;
            return byte;
        }
        fn space(self: *@This()) !void {
            while (try self.peek()) |byte| switch (byte) {
                ' ', '\t', '\r', '\n' => _ = try self.take(),
                else => return,
            };
        }
    };
    const cases = [_][]const u8{
        "\"\"",
        "\"   \"",
        "\" \\n tok\"",
        "\"plain ascii text\"",
        "\"caf\xc3\xa9 \\u00e9 \\ud83d\\ude00 end\"",
        "\"\xe2\x80\x83 \xe3\x80\x80x\"",
        "\"" ++ @as([5000]u8, @splat('a')) ++ "\\\"b\"",
        "\"" ++ @as([300]u8, @splat('k')) ++ "\"",
        "\"" ++ @as([250]u8, @splat('k')) ++ "\xc3\xa9 \\n" ++ @as([10]u8, @splat('k')) ++ "\"",
        "\"bad \xff\"",
        "\"control \x01\"",
        "\"open",
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases) |case| {
        var object = try testingObject(&tmp, case);
        defer object.file.close(std.testing.io);
        var runs = try FileSource.init(&object, .{ .start = 0, .length = case.len });
        var runs_hash = protocol.contentHasher();
        var runs_prefix: protocol.Bounded(max_evidence_bytes) = .{};
        var runs_decoded = Decoded{ .hash = &runs_hash, .bounded = &runs_prefix };
        const by_runs = parseString(&runs, &runs_decoded);
        var bytes = ByteSource{ .bytes = case };
        var bytes_hash = protocol.contentHasher();
        var bytes_prefix: protocol.Bounded(max_evidence_bytes) = .{};
        var bytes_decoded = Decoded{ .hash = &bytes_hash, .bounded = &bytes_prefix };
        const by_bytes = parseString(&bytes, &bytes_decoded);
        if (by_bytes) |expected| {
            const actual = try by_runs;
            try std.testing.expectEqual(expected, actual);
            try std.testing.expectEqual(bytes_hash.finalResult(), runs_hash.finalResult());
            try std.testing.expectEqualStrings(bytes_prefix.slice(), runs_prefix.slice());
            try std.testing.expectEqual(bytes_decoded.overflow, runs_decoded.overflow);
        } else |err| try std.testing.expectError(err, by_runs);
    }
}

test "a decoded event is parsed from the bytes just written, never read back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [protocol.max_store_bytes]u8 = undefined;
    const path = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    var used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var data: EventData = undefined;
    try data.init(std.testing.io, path, "event-data", .{ .used = &used, .limit = 64 * 1024 }, false, &retained);
    defer data.deinit();
    // Reads through a write-only handle fail, so any read back is an error.
    const unreadable = try tmp.dir.createFile(std.testing.io, "unreadable", .{});
    defer unreadable.close(std.testing.io);

    const event = "{\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}";
    const line = "data: " ++ event;
    var capture = try testingObject(&tmp, line);
    defer capture.file.close(std.testing.io);
    // The SSE line scan already loaded this line; copying it reuses those bytes.
    _ = try capture.bytesAt(0, line.len);
    const capture_file = capture.file;
    capture.file = unreadable;
    // A nearly full window starts again at the event, so the event stays whole.
    try data.append(&@as([protocol.content_window_bytes - 8]u8, @splat(' ')));
    const start = data.length;
    try data.copy(&capture, "data: ".len, event.len);
    capture.file = capture_file;

    const data_file = data.window.file;
    data.window.file = unreadable;
    const range = Range{ .start = start, .length = event.len };
    const fields = try readFields(&data.window, range, &.{ "type", "delta" });
    var kind: protocol.Bounded(max_evidence_bytes) = .{};
    _ = try readString(&data.window, try fields.required("type"), &kind);
    try std.testing.expect(kind.eql("response.output_text.delta"));
    try std.testing.expectEqual(protocol.contentDigest(event), try contentDigestRange(&data.window, range));
    data.window.file = data_file;

    var written: [event.len]u8 = undefined;
    try std.testing.expectEqual(event.len, try data.window.file.readPositionalAll(std.testing.io, &written, start));
    try std.testing.expectEqualStrings(event, &written);
    // An event larger than the window is read back from the file instead.
    const large_start = data.length;
    try data.append("{\"delta\":\"");
    try data.append(&@as([2 * protocol.content_window_bytes]u8, @splat('x')));
    try data.append("\"}");
    const large = try readFields(&data.window, .{ .start = large_start, .length = data.length - large_start }, &.{"delta"});
    try std.testing.expectEqual(2 * protocol.content_window_bytes + 2, (try large.required("delta")).length);
}

test "provider field collection preserves escaped keys duplicates and missing fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const unused = "{\"ty\\u0070e\":\"message\",\"unused\":1,\"unused\":2}";
    var object = try testingObject(&tmp, unused);
    defer object.file.close(std.testing.io);
    var source = try FileSource.init(&object, .{ .start = 0, .length = unused.len });
    const fields = try collectFields(&source, &.{ "type", "id", "unused" });
    _ = try fields.required("type");
    try std.testing.expectEqual(null, try fields.get("id"));
    try std.testing.expectError(error.MissingProviderField, fields.required("id"));
    try std.testing.expectError(error.DuplicateJsonField, fields.get("unused"));
    const repeated_key = "{\"type\":1,\"ty\\u0070e\":2,\"type\":3}";
    var repeated_object = try testingObject(&tmp, repeated_key);
    defer repeated_object.file.close(std.testing.io);
    var duplicate = try FileSource.init(&repeated_object, .{ .start = 0, .length = repeated_key.len });
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
        var object = try testingObject(&tmp, case[0]);
        defer object.file.close(std.testing.io);
        var source = try FileSource.init(&object, .{ .start = 0, .length = case[0].len });
        try std.testing.expectError(case[1], collectFields(&source, &.{"type"}));
    }
}

test "provider field collection cannot grant authority through escaped metadata keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const item = "{\"type\":\"compaction\",\"id\":\"c\",\"encrypted_content\":\"opaque\",\"internal_chat_message_metadata_passthrough\":{\"cell_\\u0069d\":null,\"unknown\":{\"nested\":[1,true]}}}";
    var object = try testingObject(&tmp, item);
    defer object.file.close(std.testing.io);
    try expectIncompatible(error.UnsupportedMetadataAuthority, try judgeFile(std.testing.io, object.file, item.len, .compaction));
}

test "provider authority metadata rejects every supported item" {
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
                try expectCompatible(try judgeFile(std.testing.io, source.file, item.len, purpose));
            } else {
                try std.testing.expectError(error.UnsupportedMetadataAuthority, validateTestingOperation(&tmp, sse, 4096, purpose));
                try expectIncompatible(error.UnsupportedMetadataAuthority, try judgeFile(std.testing.io, source.file, item.len, purpose));
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

/// The codec's JSON reader and validation's own parser name the same error
/// for `document`, however the reader is fed.
fn expectSyntaxAgrees(tmp: *std.testing.TmpDir, document: []const u8) !void {
    const json = @import("codecs/json.zig");
    var window = try testingObject(tmp, document);
    defer window.file.close(std.testing.io);
    const expected: ?anyerror = if (readFields(&window, .{ .start = 0, .length = document.len }, &.{"type"})) |_| null else |err| err;
    const Ignored = struct {
        pub fn key(_: *@This(), _: *const json.Reader, _: u8) void {}
        pub fn begin(_: *@This(), _: *const json.Reader, _: json.Kind, _: u8) void {}
        pub fn end(_: *@This(), _: *const json.Reader, _: json.Kind, _: u8) void {}
    };
    var ignored: Ignored = .{};
    for ([_]usize{ 1, 3, document.len + 1 }) |cut| {
        var reader: json.Reader = undefined;
        reader.init();
        var offset: usize = 0;
        const actual: ?anyerror = while (offset < document.len) {
            const end = @min(document.len, offset + cut);
            reader.feed(document[offset..end], &ignored) catch |err| break err;
            offset = end;
        } else if (reader.complete()) null else reader.unfinished();
        if (expected != actual) {
            std.debug.print("\"{s}\": validation {?t}, reader {?t}\n", .{ document, expected, actual });
            return error.TestUnexpectedError;
        }
    }
}

test "the codec's JSON reader names each syntax error as validation does" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sample = "{\"type\":\"x\", \"a\":[1,-2.5e+3,0,true,null,{\"b\":\"\\u00e9\\n\xc3\xa9\\ud83d\\ude00\"}],\"c\":{}}";
    // Every prefix, and every byte replaced by each byte the grammar
    // treats apart.
    for (0..sample.len + 1) |cut| try expectSyntaxAgrees(&tmp, sample[0..cut]);
    const alphabet = "{}[]:,\"\\ 0-.eE+tfnux\x01\x7f\xc3\xe2\xf0\xff";
    var document: [sample.len]u8 = undefined;
    for (0..sample.len) |index| for (alphabet) |byte| {
        document = sample.*;
        document[index] = byte;
        try expectSyntaxAgrees(&tmp, &document);
    };
    const open = "{\"a\":" ++ @as([protocol.max_json_depth]u8, @splat('['));
    const close: [protocol.max_json_depth]u8 = @splat(']');
    for ([_][]const u8{ open ++ "1" ++ close ++ "}", open ++ " ", open[0 .. open.len - 1] ++ " ", open ++ "]" }) |deep| try expectSyntaxAgrees(&tmp, deep);
}
