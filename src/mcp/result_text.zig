//! One MCP renderer, with the model excerpt derived from its complete text.
const std = @import("std");
const reply = @import("reply.zig");
const document = @import("document.zig");

// Kept equal to bash.zig's excerpt_bytes; Running tests check both owners.
pub const excerpt_bytes = 10_000;
pub const max_answer_bytes = 4 * 1024 * 1024;
pub const Code = enum { succeeded, failed, spawn_failed, indeterminate, cancelled };
pub const Ending = union(enum) {
    outcome: reply.CallOutcome,
    not_sent: anyerror,
    lost: anyerror,
    timed_out: struct { after_ms: u64, sent: bool },
    stopped: bool,
    oversized: struct { prefix: []const u8, id: u64 },
};

/// The only owner of MCP resolution certainty. Ending variants encode whether
/// any request byte was sent; an answer cannot exist on the not-sent side.
pub fn classify(ending: Ending) Code {
    return switch (ending) {
        .outcome => |outcome| switch (outcome) {
            .waiting => unreachable,
            .result => |result| if (result.is_error) .failed else .succeeded,
            .server_error => .failed,
            .refused => |failure| if (failure.status >= 400 and failure.status < 500) .failed else .indeterminate,
        },
        .not_sent => .spawn_failed,
        .lost => .indeterminate,
        .timed_out => |timeout| if (timeout.sent) .indeterminate else .spawn_failed,
        .stopped => |sent| if (sent) .indeterminate else .cancelled,
        .oversized => |answer| oversizedCode(answer.prefix, answer.id),
    };
}

/// Do not infer an absent isError from an unfinished result. Explicit flags,
/// a finished result (default false), or error code+message can establish the
/// outcome before a large content/data value ends. Only a syntactically valid
/// prefix with the matching JSON-RPC envelope counts; nested lookalikes do not.
fn oversizedCode(prefix: []const u8, id: u64) Code {
    var capture: AnswerPrefix = .{ .expected_id = id, .prefix = prefix };
    var reader: json.Reader = undefined;
    reader.read(prefix, &capture) catch |err| switch (err) {
        error.UnexpectedJsonEnd => {},
        else => return .indeterminate,
    };
    if (!capture.version or capture.conflict) return .indeterminate;
    if ((capture.id or capture.null_id) and capture.error_code and capture.error_message) return .failed;
    if (!capture.id or capture.result_invalid) return .indeterminate;
    return capture.result_code orelse .indeterminate;
}

const json = @import("../codecs/json.zig");
const AnswerPrefix = struct {
    expected_id: u64,
    prefix: []const u8,
    version: bool = false,
    id: bool = false,
    null_id: bool = false,
    version_seen: bool = false,
    id_seen: bool = false,
    flag_seen: bool = false,
    root_key: enum { other, version, id, result, rpc_error } = .other,
    result_key: bool = false,
    error_key: enum { other, code, message } = .other,
    result_object: bool = false,
    error_object: bool = false,
    result_seen: bool = false,
    error_seen: bool = false,
    conflict: bool = false,
    result_code: ?Code = null,
    result_invalid: bool = false,
    error_code: bool = false,
    error_message: bool = false,
    error_code_seen: bool = false,
    error_message_seen: bool = false,
    number_start: usize = 0,

    pub fn key(self: *AnswerPrefix, reader: *const json.Reader, depth: u8) void {
        const name = reader.text() orelse "";
        if (depth == 1) {
            self.root_key = if (std.mem.eql(u8, name, "jsonrpc")) .version else if (std.mem.eql(u8, name, "id")) .id else if (std.mem.eql(u8, name, "result")) .result else if (std.mem.eql(u8, name, "error")) .rpc_error else .other;
            if (std.mem.eql(u8, name, "method")) self.conflict = true;
            if (self.root_key == .version) {
                self.conflict = self.conflict or self.version_seen;
                self.version_seen = true;
            }
            if (self.root_key == .id) {
                self.conflict = self.conflict or self.id_seen;
                self.id_seen = true;
            }
        } else if (depth == 2) {
            if (self.result_object) {
                self.result_key = std.mem.eql(u8, name, "isError");
                if (self.result_key) {
                    self.conflict = self.conflict or self.flag_seen;
                    self.flag_seen = true;
                }
            }
            if (self.error_object) {
                self.error_key = if (std.mem.eql(u8, name, "code")) .code else if (std.mem.eql(u8, name, "message")) .message else .other;
                switch (self.error_key) {
                    .code => {
                        self.conflict = self.conflict or self.error_code_seen;
                        self.error_code_seen = true;
                    },
                    .message => {
                        self.conflict = self.conflict or self.error_message_seen;
                        self.error_message_seen = true;
                    },
                    .other => {},
                }
            }
        }
    }

    pub fn begin(self: *AnswerPrefix, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
        if (depth == 2) {
            if (self.result_object and self.result_key and kind != .literal) self.result_invalid = true;
            if (self.error_object and self.error_key == .code) self.number_start = @intCast(reader.offset);
        }
        if (depth != 1) return;
        if (self.root_key == .result) {
            self.conflict = self.conflict or self.result_seen or self.error_seen;
            self.result_seen = true;
            self.result_object = kind == .object;
        } else if (self.root_key == .rpc_error) {
            self.conflict = self.conflict or self.error_seen or self.result_seen;
            self.error_seen = true;
            self.error_object = kind == .object;
        }
    }

    pub fn end(self: *AnswerPrefix, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
        if (depth == 1) switch (self.root_key) {
            .version => self.version = kind == .string and std.mem.eql(u8, reader.text() orelse "", "2.0"),
            .id => {
                self.id = kind == .number and reader.integer != null and reader.integer.? == self.expected_id;
                self.null_id = kind == .literal and reader.literalValue() == .null_value;
            },
            .result => {
                if (kind == .object and self.result_code == null) self.result_code = .succeeded;
                self.result_object = false;
            },
            .rpc_error => self.error_object = false,
            else => {},
        };
        if (depth != 2) return;
        if (self.result_object and self.result_key and kind == .literal) switch (reader.literalValue()) {
            .true_value => self.result_code = .failed,
            .false_value => self.result_code = .succeeded,
            else => self.result_invalid = true,
        };
        if (self.error_object) switch (self.error_key) {
            .code => self.error_code = kind == .number and validErrorCode(self.prefix[self.number_start..@intCast(reader.offset)]),
            .message => self.error_message = kind == .string,
            .other => {},
        };
    }
};

fn validErrorCode(bytes: []const u8) bool {
    _ = std.fmt.parseInt(i64, bytes, 10) catch return false;
    return true;
}

/// The server name accompanies the transport's ending, not its borrowed result.
pub const Ended = struct { server_name: []const u8, ended: Ending };

pub fn write(out: *std.Io.Writer, ended: Ended) !Code {
    var bounded: Prefix = .{ .out = out };
    const code = try render(&bounded.writer, ended);
    try bounded.writer.flush();
    try bounded.finish();
    return code;
}

/// Derive the saved model resolution from the already rendered full answer.
/// The same prefix owner backs write(), preserving existing excerpt bytes.
pub fn writeExcerpt(out: *std.Io.Writer, full: []const u8) !void {
    var bounded: Prefix = .{ .out = out };
    try bounded.append(full);
    try bounded.finish();
}

/// Streams the prefix, holding only its last four bytes and one lookahead.
/// The lookahead identifies a cut inside a UTF-8 sequence without changing
/// the server's bytes when the whole output fits (including non-UTF-8 bodies).
const Prefix = struct {
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
    out: *std.Io.Writer,
    total: usize = 0,
    shown: usize = 0,
    tail: [5]u8 = undefined,
    tail_len: usize = 0,

    fn append(self: *Prefix, bytes: []const u8) std.Io.Writer.Error!void {
        self.total += bytes.len;
        const direct = @min(bytes.len, excerpt_bytes - 4 - self.shown);
        try self.out.writeAll(bytes[0..direct]);
        self.shown += direct;
        const saved = @min(bytes.len - direct, self.tail.len - self.tail_len);
        @memcpy(self.tail[self.tail_len..][0..saved], bytes[direct..][0..saved]);
        self.tail_len += saved;
    }

    fn finish(self: *Prefix) std.Io.Writer.Error!void {
        var take = self.tail_len;
        if (self.total > excerpt_bytes) {
            take = 4;
            while (take > 0 and self.tail[take] & 0xc0 == 0x80) take -= 1;
        }
        try self.out.writeAll(self.tail[0..take]);
        self.shown += take;
        if (self.total > self.shown) {
            try self.out.print("\n[{d} more bytes not shown]", .{self.total - self.shown});
        }
    }

    fn drain(writer: *std.Io.Writer, parts: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Prefix = @fieldParentPtr("writer", writer);
        var count: usize = 0;
        for (parts[0 .. parts.len - 1]) |part| {
            try self.append(part);
            count += part.len;
        }
        for (0..splat) |_| {
            try self.append(parts[parts.len - 1]);
            count += parts[parts.len - 1].len;
        }
        return count;
    }
};

/// Render the complete answer once, before Running releases its borrowed reply.
pub fn render(out: *std.Io.Writer, ended: Ended) !Code {
    const name = ended.server_name;
    const code = classify(ended.ended);
    switch (ended.ended) {
        .outcome => |outcome| switch (outcome) {
            .waiting => unreachable,
            .result => |result| {
                if (result.is_error) try out.writeAll("The tool reported an error:\n");
                var items = document.Items.init(result.content);
                var any = false;
                while (items.next()) |block| {
                    if (any) try out.writeByte('\n');
                    any = true;
                    try writeBlock(out, block);
                }
                if (!any) try out.writeAll(result.structured orelse "(no output)");
                return code;
            },
            .server_error => |failure| {
                try out.print("The MCP server returned error {d}: ", .{failure.code});
                try document.writeDecoded(out, failure.message);
                if (failure.data) |data| {
                    try out.writeByte('\n');
                    try out.writeAll(data);
                }
                return code;
            },
            .refused => |failure| {
                if (code == .indeterminate) {
                    try out.print("Outcome unknown: The MCP server answered HTTP {d}. The call may or may not have run; it was not retried.\n{s}", .{ failure.status, failure.body });
                } else try out.print("The MCP server answered HTTP {d}: {s}", .{ failure.status, failure.body });
                return code;
            },
        },
        .not_sent => |err| {
            try out.print("Failed, not run: Rui could not reach MCP server {s} ({s}).", .{ name, @errorName(err) });
            return code;
        },
        .lost => |err| {
            try out.print("Outcome unknown: the connection to MCP server {s} failed after the call was sent ({s}). The call may or may not have run; it was not retried.", .{ name, @errorName(err) });
            return code;
        },
        .oversized => |answer| {
            if (code == .indeterminate) try out.writeAll("Outcome unknown: ");
            try out.print("The MCP server's answer was larger than the {d}-byte limit; the retained prefix follows.", .{max_answer_bytes});
            if (code == .indeterminate) try out.writeAll(" The call may or may not have run; it was not retried.");
            try out.writeByte('\n');
            try out.writeAll(answer.prefix);
            return code;
        },
        .stopped => |sent| {
            try out.writeAll(if (sent) @import("action_text.zig").stop_unknown else @import("action_text.zig").stop_not_sent);
            return code;
        },
        .timed_out => |timeout| {
            // Millisecond precision avoids calling a sub-second deadline zero seconds.
            if (timeout.sent) {
                try out.print("Outcome unknown: no reply from MCP server {s} within {d} s. The call may or may not have run; it was not retried.", .{ name, @as(f64, @floatFromInt(timeout.after_ms)) / 1000 });
                return code;
            }
            try out.print("Failed, not run: MCP server {s} did not accept the call within {d} s.", .{ name, @as(f64, @floatFromInt(timeout.after_ms)) / 1000 });
            return code;
        },
    }
}

fn writeBlock(out: *std.Io.Writer, block: []const u8) !void {
    if (document.kind(block) == .object) {
        if (document.member(block, "type")) |kind| {
            if (document.kind(kind) == .string and document.keyIs(document.contents(kind), "text")) {
                if (document.member(block, "text")) |text| {
                    if (document.kind(text) == .string) {
                        try document.writeDecoded(out, document.contents(text));
                        return;
                    }
                }
            }
        }
    }
    try out.writeAll(block);
}

test "result_text renders blocks and structured content with resolution codes" {
    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const result = @import("reply.zig");
    const mixed: result.CallResult = .{ .content = "[{\"type\":\"text\",\"text\":\"a\\nb\"},{\"type\":\"text\",\"text\":\"c\"},{\"type\":\"image\",\"data\":\"x\"}]", .is_error = false, .structured = null };
    try std.testing.expectEqual(Code.succeeded, try write(&out, .{ .server_name = "test", .ended = .{ .outcome = .{ .result = mixed } } }));
    try std.testing.expectEqualStrings("a\nb\nc\n{\"type\":\"image\",\"data\":\"x\"}", out.buffered());
    out = .fixed(&buffer);
    try std.testing.expectEqual(Code.failed, try write(&out, .{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = "[]", .structured = "{\"x\":1}", .is_error = true } } } }));
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), "{\"x\":1}"));
    out = .fixed(&buffer);
    _ = try write(&out, .{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = "[{\"type\":\"text\",\"text\":7}]", .structured = null, .is_error = false } } } });
    try std.testing.expectEqualStrings("{\"type\":\"text\",\"text\":7}", out.buffered());
}

test "result_text keeps a UTF-8 prefix and counts omitted bytes" {
    const gpa = std.testing.allocator;
    const content = try gpa.alloc(u8, excerpt_bytes + 100);
    defer gpa.free(content);
    // Use structured JSON so the boundary crosses a multibyte character.
    @memset(content, 'x');
    content[0] = '"';
    @memcpy(content[excerpt_bytes - 1 ..][0..2], "é");
    content[content.len - 1] = '"';
    const buffer = try gpa.alloc(u8, excerpt_bytes + 100);
    defer gpa.free(buffer);
    var out: std.Io.Writer = .fixed(buffer);
    _ = try write(&out, .{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = "[]", .structured = content, .is_error = false } } } });
    try std.testing.expect(std.unicode.utf8ValidateSlice(out.buffered()));
    try std.testing.expectEqualStrings("\n[101 more bytes not shown]", out.buffered()[excerpt_bytes - 1 ..]);
}

test "result_text classification covers every ending and certainty boundary" {
    const Case = struct { ending: Ending, code: Code, contains: []const u8 };
    // Answers imply sent. The sent/not-sent split is carried only by transport
    // endings, timeout and stop; contradictory answer-without-send states do not exist.
    const cases = [_]Case{
        .{ .ending = .{ .not_sent = error.ConnectFailed }, .code = .spawn_failed, .contains = "Failed, not run" },
        .{ .ending = .{ .lost = error.NoAnswer }, .code = .indeterminate, .contains = "not retried" },
        .{ .ending = .{ .lost = error.TruncatedResponse }, .code = .indeterminate, .contains = "Outcome unknown" },
        .{ .ending = .{ .timed_out = .{ .after_ms = 1500, .sent = false } }, .code = .spawn_failed, .contains = "1.5 s" },
        .{ .ending = .{ .timed_out = .{ .after_ms = 600_000, .sent = true } }, .code = .indeterminate, .contains = "600 s" },
        .{ .ending = .{ .stopped = false }, .code = .cancelled, .contains = "not sent" },
        .{ .ending = .{ .stopped = true }, .code = .indeterminate, .contains = "not retried" },
        .{ .ending = .{ .outcome = .{ .server_error = .{ .code = -32602, .message = "bad\\nargument", .data = "{\"field\":1}" } } }, .code = .failed, .contains = "bad\nargument\n{\"field\":1}" },
        .{ .ending = .{ .outcome = .{ .refused = .{ .status = 400, .body = "bad request" } } }, .code = .failed, .contains = "The MCP server answered HTTP 400" },
        .{ .ending = .{ .outcome = .{ .refused = .{ .status = 403, .body = "refused" } } }, .code = .failed, .contains = "HTTP 403" },
        .{ .ending = .{ .outcome = .{ .refused = .{ .status = 429, .body = "slow down" } } }, .code = .failed, .contains = "HTTP 429" },
        .{ .ending = .{ .outcome = .{ .refused = .{ .status = 499, .body = "refused" } } }, .code = .failed, .contains = "HTTP 499" },
        .{ .ending = .{ .outcome = .{ .refused = .{ .status = 500, .body = "internal" } } }, .code = .indeterminate, .contains = "not retried" },
        .{ .ending = .{ .outcome = .{ .refused = .{ .status = 502, .body = "gateway" } } }, .code = .indeterminate, .contains = "Outcome unknown" },
        .{ .ending = .{ .outcome = .{ .refused = .{ .status = 599, .body = "lost" } } }, .code = .indeterminate, .contains = "HTTP 599" },
        .{ .ending = .{ .outcome = .{ .result = .{ .is_error = false, .content = "[]", .structured = null } } }, .code = .succeeded, .contains = "(no output)" },
        .{ .ending = .{ .outcome = .{ .result = .{ .is_error = true, .content = "[]", .structured = null } } }, .code = .failed, .contains = "tool reported an error" },
    };
    for (cases) |case| {
        var buffer: [1024]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        try std.testing.expectEqual(case.code, classify(case.ending));
        try std.testing.expectEqual(case.code, try write(&out, .{ .server_name = "test", .ended = case.ending }));
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), case.contains) != null);
    }
    const PrefixCase = struct { prefix: []const u8, code: Code };
    const envelope = "{\"jsonrpc\":\"2.0\",\"id\":7,";
    const prefixes = [_]PrefixCase{
        .{ .prefix = envelope ++ "\"result\":{\"isError\":true,\"content\":[", .code = .failed },
        .{ .prefix = envelope ++ "\"result\":{\"isError\":false,\"content\":[", .code = .succeeded },
        .{ .prefix = envelope ++ "\"result\":{\"content\":[],\"isError\":true", .code = .failed },
        .{ .prefix = envelope ++ "\"result\":{\"content\":[],\"isError\":false", .code = .succeeded },
        .{ .prefix = envelope ++ "\"result\":{\"content\":[]},\"padding\":\"", .code = .succeeded },
        .{ .prefix = envelope ++ "\"result\":{\"content\":[", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"isError\":tru", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"isError\":null,\"content\":[", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"content\":[{\"isError\":true}],", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"isError\":trueX", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"is\\u0045rror\":true,", .code = .failed },
        .{ .prefix = envelope ++ "\"error\":{\"code\":-32602,\"message\":\"bad\",\"data\":", .code = .failed },
        .{ .prefix = envelope ++ "\"error\":{\"code\":-32602,\"message\":\"bad", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"error\":{\"code\":1.5,\"message\":\"bad\",\"data\":", .code = .indeterminate },
        .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"bad\",", .code = .failed },
        .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{\"isError\":true,", .code = .indeterminate },
        .{ .prefix = "{\"result\":{\"isError\":false,", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"isError\":false},\"error\":{", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"content\":[]},\"other\":{\"isError\":true,", .code = .succeeded },
        .{ .prefix = envelope ++ "\"result\":{\"isError\":true,\"content\":[]}}", .code = .failed },
        .{ .prefix = envelope ++ "\"result\":{\"isError\":false,\"isError\":true,", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"id\":7,\"result\":{\"isError\":true,", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"method\":\"unexpected\",\"result\":{\"isError\":true,", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"error\":{\"code\":null,\"code\":-32602,\"message\":\"bad\",", .code = .indeterminate },
    };
    for (prefixes) |case| {
        const ending: Ending = .{ .oversized = .{ .prefix = case.prefix, .id = 7 } };
        var buffer: [1024]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        try std.testing.expectEqual(case.code, classify(ending));
        try std.testing.expectEqual(case.code, try write(&out, .{ .server_name = "test", .ended = ending }));
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "larger than") != null);
        try std.testing.expect(std.mem.endsWith(u8, out.buffered(), case.prefix));
        if (case.code == .indeterminate) try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "not retried") != null);
    }
}

test "result_text truncates at every UTF-8 offset and preserves exact-fit output" {
    const gpa = std.testing.allocator;
    const content = try gpa.alloc(u8, excerpt_bytes + 32);
    defer gpa.free(content);
    const buffer = try gpa.alloc(u8, excerpt_bytes + 100);
    defer gpa.free(buffer);
    for ([_][]const u8{ "é", "€", "😀" }) |character| {
        for (excerpt_bytes - 4..excerpt_bytes + 2) |at| {
            @memset(content, 'x');
            content[0] = '"';
            content[content.len - 1] = '"';
            @memcpy(content[at..][0..character.len], character);
            var out: std.Io.Writer = .fixed(buffer);
            _ = try write(&out, .{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = "[]", .structured = content, .is_error = false } } } });
            const kept = if (at < excerpt_bytes and at + character.len > excerpt_bytes) at else excerpt_bytes;
            try std.testing.expect(std.unicode.utf8ValidateSlice(out.buffered()));
            try std.testing.expectEqualSlices(u8, content[0..kept], out.buffered()[0..kept]);
            var suffix: [64]u8 = undefined;
            const expected = try std.fmt.bufPrint(&suffix, "\n[{d} more bytes not shown]", .{content.len - kept});
            try std.testing.expectEqualStrings(expected, out.buffered()[kept..]);
        }
    }
    for ([_]usize{ excerpt_bytes - 4, excerpt_bytes - 1, excerpt_bytes }) |length| {
        @memset(content, 'x');
        var out: std.Io.Writer = .fixed(buffer);
        _ = try write(&out, .{ .server_name = "test", .ended = .{ .outcome = .{ .refused = .{ .status = 403, .body = content[0 .. length - "The MCP server answered HTTP 403: ".len] } } } });
        try std.testing.expectEqual(length, out.buffered().len);
    }
}

test "result_text full render derives the unchanged excerpt without rendering twice" {
    const gpa = std.testing.allocator;
    const content = try gpa.alloc(u8, excerpt_bytes + 32);
    defer gpa.free(content);
    for ([_]usize{ 0, excerpt_bytes - 4, excerpt_bytes - 1, excerpt_bytes, excerpt_bytes + 1, content.len }) |length| {
        for ([_][]const u8{ "é", "€", "😀" }) |character| {
            for (excerpt_bytes - 4..excerpt_bytes + 2) |at| {
                @memset(content, 'x');
                @memcpy(content[at..][0..character.len], character);
                const ended: Ended = .{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = "[]", .structured = content[0..length], .is_error = false } } } };
                var full: std.Io.Writer.Allocating = .init(gpa);
                defer full.deinit();
                try std.testing.expectEqual(Code.succeeded, try render(&full.writer, ended));
                try std.testing.expectEqualStrings(content[0..length], full.written());
                var excerpt: std.Io.Writer.Allocating = .init(gpa);
                defer excerpt.deinit();
                try writeExcerpt(&excerpt.writer, full.written());
                var previous: std.Io.Writer.Allocating = .init(gpa);
                defer previous.deinit();
                _ = try write(&previous.writer, ended);
                try std.testing.expectEqualStrings(previous.written(), excerpt.written());
            }
        }
    }
}
