//! The core's own tools (D24): their record text and their argument
//! checks. A call to one runs as a core command, never as an Action
//! process; who runs a tool is derived from its name (D46).

const std = @import("std");
const protocol = @import("protocol.zig");

/// The most decoded bytes a `message_agent` text carries.
pub const message_agent_max_text_bytes = 64 * 1024;

// Prompt text: written here, and given no tests (D141).
pub const message_agent_description = "Send a Message to another Rui Session by its ID. It returns once the Message is delivered, before any answer. A reply, if the receiver sends one, arrives later as a Message that starts your next turn.";
pub const message_agent_schema = "{\"type\":\"object\",\"properties\":{" ++
    "\"id\":{\"type\":\"string\",\"description\":\"The receiving Session's six-character ID.\"}," ++
    std.fmt.comptimePrint("\"text\":{{\"type\":\"string\",\"description\":\"The Message: nonempty UTF-8, at most {d} bytes.\"}}", .{message_agent_max_text_bytes}) ++
    "},\"required\":[\"id\",\"text\"],\"additionalProperties\":false}";

/// A `message_agent` call's checked arguments, without its text.
pub const MessageAgentArguments = struct {
    id: protocol.Bounded(protocol.session_id_bytes) = .{},
    text_bytes: u64 = 0,
};

/// Why a `message_agent` call's arguments were rejected. Its text goes back
/// to the model as the call's result.
pub const MessageAgentProblem = enum {
    malformed_json,
    unknown_field,
    duplicate_field,
    missing_id,
    missing_text,
    id_invalid,
    text_invalid,

    pub fn text(self: MessageAgentProblem) []const u8 {
        return switch (self) {
            .malformed_json => "the arguments are not one well-formed JSON object",
            .unknown_field => "only id and text are accepted",
            .duplicate_field => "a field appears more than once",
            .missing_id => "id is required",
            .missing_text => "text is required",
            .id_invalid => "id must be a Session's six-character ID",
            .text_invalid => std.fmt.comptimePrint("text must be a nonempty string of UTF-8 text, at most {d} bytes", .{message_agent_max_text_bytes}),
        };
    }
};

pub const MessageAgentCheck = union(enum) {
    accepted: MessageAgentArguments,
    rejected: MessageAgentProblem,
};

/// Checks a `message_agent` call's decoded arguments from `source` (with
/// `peek` and `take`, as Bash's parser reads them) and writes the text's
/// decoded bytes to `text` (with `writeAll`) as they are read. The writer
/// sees text from arguments that may yet be rejected, so a caller keeps it
/// only on `.accepted`.
pub fn checkMessageAgent(source: anytype, text: anytype) !MessageAgentCheck {
    return checkObject(source, text) catch |err| switch (err) {
        error.Malformed => .{ .rejected = .malformed_json },
        else => |e| e,
    };
}

fn checkObject(source: anytype, text: anytype) !MessageAgentCheck {
    // A flat object needs one level of the scanner's stack, which grows
    // its list by more than one byte at a time.
    var stack: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&stack);
    var reader: Reader(@TypeOf(source)) = .{ .source = source, .scanner = .initStreaming(fixed.allocator()) };
    if (try reader.next() != .object_begin) return error.Malformed;
    const Field = enum { id, text };
    var seen: std.EnumSet(Field) = .empty;
    var out: MessageAgentArguments = .{ .id = .{ .len = 0 } };
    while (true) {
        var token = try reader.next();
        if (token == .object_end) break;
        // The key, piece by piece; one longer than every field's is unknown.
        var key: protocol.Bounded(8) = .{ .len = 0 };
        var key_fits = true;
        while (true) {
            const piece = stringPiece(&token) orelse return error.Malformed;
            if (key.len + piece.len > key.bytes.len) key_fits = false else {
                @memcpy(key.bytes[key.len..][0..piece.len], piece);
                key.len += piece.len;
            }
            if (token == .string) break;
            token = try reader.next();
        }
        const field = (if (key_fits) std.meta.stringToEnum(Field, key.slice()) else null) orelse return .{ .rejected = .unknown_field };
        if (seen.contains(field)) return .{ .rejected = .duplicate_field };
        seen.insert(field);
        var value = try reader.next();
        if (stringPiece(&value) == null) return .{ .rejected = switch (field) {
            .id => .id_invalid,
            .text => .text_invalid,
        } };
        var id_fits = true;
        while (true) {
            const piece = stringPiece(&value) orelse return error.Malformed;
            switch (field) {
                .id => if (out.id.len + piece.len > out.id.bytes.len) {
                    id_fits = false;
                } else {
                    @memcpy(out.id.bytes[out.id.len..][0..piece.len], piece);
                    out.id.len += piece.len;
                },
                .text => {
                    out.text_bytes += piece.len;
                    if (out.text_bytes > message_agent_max_text_bytes) return .{ .rejected = .text_invalid };
                    try text.writeAll(piece);
                },
            }
            if (value == .string) break;
            value = try reader.next();
        }
        switch (field) {
            .id => if (!id_fits or !protocol.validSessionId(out.id.slice())) return .{ .rejected = .id_invalid },
            .text => if (out.text_bytes == 0) return .{ .rejected = .text_invalid },
        }
    }
    if (try reader.next() != .end_of_document) return error.Malformed;
    if (!seen.contains(.id)) return .{ .rejected = .missing_id };
    if (!seen.contains(.text)) return .{ .rejected = .missing_text };
    return .{ .accepted = out };
}

/// The bytes a string token carries, or null for any other token.
fn stringPiece(token: *const std.json.Token) ?[]const u8 {
    return switch (token.*) {
        .partial_string, .string => |bytes| bytes,
        .partial_string_escaped_1 => |*bytes| bytes,
        .partial_string_escaped_2 => |*bytes| bytes,
        .partial_string_escaped_3 => |*bytes| bytes,
        .partial_string_escaped_4 => |*bytes| bytes,
        else => null,
    };
}

/// Feeds the scanner from `source` a chunk at a time. A token's bytes
/// point into `chunk`, which is refilled only once they are used.
fn Reader(comptime Source: type) type {
    return struct {
        source: Source,
        scanner: std.json.Scanner,
        chunk: [4096]u8 = undefined,
        ended: bool = false,

        fn next(self: *@This()) !std.json.Token {
            while (true) return self.scanner.next() catch |err| switch (err) {
                error.BufferUnderrun => {
                    try self.refill();
                    continue;
                },
                error.SyntaxError, error.UnexpectedEndOfInput, error.OutOfMemory => error.Malformed,
            };
        }

        fn refill(self: *@This()) !void {
            if (self.ended) return error.Malformed;
            var length: usize = 0;
            while (length < self.chunk.len) : (length += 1) {
                const byte = (self.source.peek() catch |err| return if (isDecodeError(err)) error.Malformed else err) orelse break;
                _ = byte;
                self.chunk[length] = self.source.take() catch |err| return if (isDecodeError(err)) error.Malformed else err;
            }
            if (length == 0) {
                self.ended = true;
                self.scanner.endInput();
            } else self.scanner.feedInput(self.chunk[0..length]);
        }
    };
}

fn isDecodeError(err: anyerror) bool {
    return switch (err) {
        error.InvalidDescriptorShape, error.InvalidUtf8 => true,
        else => false,
    };
}

const TestSource = struct {
    bytes: []const u8,
    position: usize = 0,

    fn peek(self: *TestSource) !?u8 {
        return if (self.position == self.bytes.len) null else self.bytes[self.position];
    }

    fn take(self: *TestSource) !u8 {
        const byte = (try self.peek()) orelse return error.ShortCanonicalRead;
        self.position += 1;
        return byte;
    }
};

const TestText = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,

    fn writeAll(self: *TestText, piece: []const u8) !void {
        @memcpy(self.bytes[self.len..][0..piece.len], piece);
        self.len += piece.len;
    }
};

test "a message_agent call's arguments name a Session and carry nonempty text" {
    const Case = struct { arguments: []const u8, expected: union(enum) { accepted: []const u8, rejected: MessageAgentProblem } };
    for ([_]Case{
        .{ .arguments = "{\"id\":\"k7m2qx\",\"text\":\"report back\"}", .expected = .{ .accepted = "report back" } },
        .{ .arguments = " { \"text\" : \"a\\nb \\u00e9\\ud83d\\ude00\" , \"id\" : \"k7m2qx\" } ", .expected = .{ .accepted = "a\nb é😀" } },
        .{ .arguments = "{\"id\":\"k7m2qx\"}", .expected = .{ .rejected = .missing_text } },
        .{ .arguments = "{\"text\":\"hi\"}", .expected = .{ .rejected = .missing_id } },
        .{ .arguments = "{\"id\":\"k7m2qx\",\"text\":\"\"}", .expected = .{ .rejected = .text_invalid } },
        .{ .arguments = "{\"id\":\"k7m2qx\",\"text\":7}", .expected = .{ .rejected = .text_invalid } },
        .{ .arguments = "{\"id\":\"K7M2QX\",\"text\":\"hi\"}", .expected = .{ .rejected = .id_invalid } },
        .{ .arguments = "{\"id\":\"k7m2qxk7m2qx\",\"text\":\"hi\"}", .expected = .{ .rejected = .id_invalid } },
        .{ .arguments = "{\"id\":[\"k7m2qx\"],\"text\":\"hi\"}", .expected = .{ .rejected = .id_invalid } },
        .{ .arguments = "{\"id\":\"k7m2qx\",\"id\":\"k7m2qx\",\"text\":\"hi\"}", .expected = .{ .rejected = .duplicate_field } },
        .{ .arguments = "{\"id\":\"k7m2qx\",\"text\":\"hi\",\"note\":1}", .expected = .{ .rejected = .unknown_field } },
        .{ .arguments = "{\"identifier\":\"k7m2qx\"}", .expected = .{ .rejected = .unknown_field } },
        .{ .arguments = "{\"id\":\"k7m2qx\",\"text\":\"hi\"} {}", .expected = .{ .rejected = .malformed_json } },
        .{ .arguments = "{\"id\":\"k7m2qx\",\"text\":\"hi\"", .expected = .{ .rejected = .malformed_json } },
        .{ .arguments = "[]", .expected = .{ .rejected = .malformed_json } },
        .{ .arguments = "", .expected = .{ .rejected = .malformed_json } },
        .{ .arguments = "{\"id\":\"k7m2qx\",\"text\":\"\xff\"}", .expected = .{ .rejected = .malformed_json } },
    }) |case| {
        var source: TestSource = .{ .bytes = case.arguments };
        var text: TestText = .{};
        const check = try checkMessageAgent(&source, &text);
        switch (case.expected) {
            .accepted => |expected| {
                try std.testing.expectEqualStrings("k7m2qx", check.accepted.id.slice());
                try std.testing.expectEqualStrings(expected, text.bytes[0..text.len]);
                try std.testing.expectEqual(expected.len, check.accepted.text_bytes);
            },
            .rejected => |expected| try std.testing.expectEqual(MessageAgentCheck{ .rejected = expected }, check),
        }
    }
}

test "a message_agent text over its bound is rejected, across chunk boundaries" {
    const Discard = struct {
        fn writeAll(_: *@This(), _: []const u8) !void {}
    };
    var buffer: [message_agent_max_text_bytes + 64]u8 = undefined;
    for ([_]usize{ message_agent_max_text_bytes, message_agent_max_text_bytes + 1 }) |length| {
        const head = "{\"id\":\"k7m2qx\",\"text\":\"";
        @memcpy(buffer[0..head.len], head);
        @memset(buffer[head.len..][0..length], 'a');
        @memcpy(buffer[head.len + length ..][0..2], "\"}");
        var source: TestSource = .{ .bytes = buffer[0 .. head.len + length + 2] };
        var discard: Discard = .{};
        const check = try checkMessageAgent(&source, &discard);
        if (length == message_agent_max_text_bytes)
            try std.testing.expectEqual(@as(u64, length), check.accepted.text_bytes)
        else
            try std.testing.expectEqual(MessageAgentCheck{ .rejected = .text_invalid }, check);
    }
}
