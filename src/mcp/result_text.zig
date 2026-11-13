//! The model-facing excerpt and full rendering of one borrowed MCP answer.
const std = @import("std");
const reply = @import("reply.zig");
const document = @import("document.zig");

// MCP's own prefix budget; Bash's head-and-tail excerpt has a separate one.
pub const excerpt_bytes = 10_000;
pub const max_answer_bytes = 4 * 1024 * 1024;
pub const Code = enum { succeeded, failed, spawn_failed, indeterminate, cancelled };
pub const Ending = union(enum) {
    outcome: reply.CallOutcome,
    not_sent: anyerror,
    lost: anyerror,
    timed_out: struct { after_ms: u64, sent: bool },
    stopped: bool,
    oversized: reply.Answer,
};

/// The only owner of MCP resolution certainty. Ending variants encode whether
/// any request byte was sent; an answer cannot exist on the not-sent side.
pub fn classify(ending: Ending) Code {
    return switch (ending) {
        .outcome => |outcome| answerCode(reply.classify(outcome)),
        .not_sent => .spawn_failed,
        .lost => .indeterminate,
        .timed_out => |timeout| if (timeout.sent) .indeterminate else .spawn_failed,
        .stopped => |sent| if (sent) .indeterminate else .cancelled,
        .oversized => |answer| answerCode(reply.judgeCall(answer)),
    };
}

fn answerCode(code: reply.Code) Code {
    return switch (code) {
        .succeeded => .succeeded,
        .failed => .failed,
        .indeterminate => .indeterminate,
    };
}

/// The server name accompanies the transport's ending, not its borrowed result.
pub const Ended = struct { server_name: []const u8, ended: Ending };

pub fn write(out: *std.Io.Writer, ended: Ended) !Code {
    return (try writeExcerpt(out, ended)).code;
}

pub const Excerpt = struct { code: Code, total: usize, omitted: bool };

/// Preserve the existing excerpt bytes; the execution owner may append a
/// scratch notice when omitted, before releasing the borrowed answer.
pub fn writeExcerpt(out: *std.Io.Writer, ended: Ended) !Excerpt {
    var bounded: Prefix = .{ .out = out };
    const code = try render(&bounded.writer, ended);
    try bounded.writer.flush();
    try bounded.finish();
    if (bounded.total > bounded.shown) {
        try out.print("\n[{d} more bytes not shown]", .{bounded.total - bounded.shown});
    }
    return .{ .code = code, .total = bounded.total, .omitted = bounded.total > bounded.shown };
}

/// A second streaming pass only for omitted output: no full rendered copy is
/// allocated, and each byte is written to scratch once.
pub fn writeFull(out: *std.Io.Writer, ended: Ended) !void {
    _ = try render(out, ended);
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

fn render(out: *std.Io.Writer, ended: Ended) !Code {
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
            try out.writeAll(answer.bytes);
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
        .{ .prefix = envelope ++ "\"result\":{\"isError\":false,\"content\":[],\"resultType\":\"input_required\",\"padding\":\"", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"resultType\":\"complete\",\"isError\":false,\"content\":[{\"resultType\":\"input_required\",\"isError\":true}", .code = .succeeded },
        .{ .prefix = envelope ++ "\"result\":{\"isError\":false,\"content\":[", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"resultType\":\"complete\",\"isError\":false,", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"resultType\":\"complete\",\"isError\":false,\"content\":", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"resultType\":\"complete\",\"isError\":false,\"content\":[],\"resultType\":\"input_required\",\"padding\":\"", .code = .succeeded },
        .{ .prefix = envelope ++ "\"result\":{\"resultType\":\"input_required\",\"isError\":false,\"content\":[", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"resultType\":\"complete\",\"isError\":false,\"content\":\"", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"resultType\":\"complete\",\"isError\":true,\"content\":[", .code = .failed },
        .{ .prefix = envelope ++ "\"result\":{\"resultType\":\"complete\",\"isError\":false,\"content\":[", .code = .succeeded },
        .{ .prefix = envelope ++ "\"result\":{\"resultType\":\"complete\",\"content\":[],\"isError\":true", .code = .failed },
        .{ .prefix = envelope ++ "\"result\":{\"resultType\":\"complete\",\"content\":[],\"isError\":false", .code = .succeeded },
        .{ .prefix = envelope ++ "\"result\":{\"content\":[]},\"padding\":\"", .code = .succeeded },
        .{ .prefix = envelope ++ "\"result\":{\"content\":[", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"isError\":tru", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"isError\":null,\"content\":[", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"content\":[{\"isError\":true}],", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"isError\":trueX", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"is\\u0045rror\":true},\"padding\":\"", .code = .failed },
        .{ .prefix = envelope ++ "\"error\":{\"code\":-32602,\"message\":\"bad\",\"data\":", .code = .failed },
        .{ .prefix = envelope ++ "\"error\":{\"code\":-32602,\"message\":\"bad", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"error\":{\"code\":1.5,\"message\":\"bad\",\"data\":", .code = .indeterminate },
        .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"bad\",", .code = .failed },
        .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{\"isError\":true,", .code = .indeterminate },
        .{ .prefix = "{\"result\":{\"isError\":false,", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"isError\":false},\"error\":{", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"result\":{\"content\":[]},\"other\":{\"isError\":true,", .code = .succeeded },
        .{ .prefix = envelope ++ "\"result\":{\"isError\":true,\"content\":[]}}", .code = .failed },
        .{ .prefix = envelope ++ "\"result\":{\"isError\":false,\"isError\":true},\"padding\":\"", .code = .succeeded },
        .{ .prefix = envelope ++ "\"id\":7,\"result\":{\"isError\":true},\"padding\":\"", .code = .failed },
        .{ .prefix = envelope ++ "\"method\":\"unexpected\",\"result\":{\"isError\":true,", .code = .indeterminate },
        .{ .prefix = envelope ++ "\"error\":{\"code\":null,\"code\":-32602,\"message\":\"bad\",", .code = .indeterminate },
    };
    for (prefixes) |case| {
        const ending: Ending = .{ .oversized = .{ .bytes = case.prefix, .id = 7, .extent = .cut } };
        var buffer: [1024]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        try std.testing.expectEqual(case.code, classify(ending));
        try std.testing.expectEqual(case.code, try write(&out, .{ .server_name = "test", .ended = ending }));
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "larger than") != null);
        try std.testing.expect(std.mem.endsWith(u8, out.buffered(), case.prefix));
        if (case.code == .indeterminate) try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "not retried") != null);
    }
    // One reply domain: size, HTTP status, media and envelope correlation are
    // independent inputs. The overflow is in padding, after the semantic object,
    // so every observed field must have the same judgment as a fitting answer.
    const AnswerCase = struct { payload: []const u8, code: reply.Code };
    const answers = [_]AnswerCase{
        .{ .payload = "\"result\":{}", .code = .succeeded },
        .{ .payload = "\"result\":{\"resultType\":\"complete\",\"content\":[],\"isError\":false}", .code = .succeeded },
        .{ .payload = "\"result\":{\"resultType\":\"complete\",\"content\":[],\"isError\":true}", .code = .failed },
        .{ .payload = "\"result\":{\"resultType\":\"input_required\",\"content\":[],\"isError\":false}", .code = .indeterminate },
        .{ .payload = "\"result\":{\"resultType\":\"later\",\"isError\":true}", .code = .indeterminate },
        .{ .payload = "\"result\":{\"resultType\":7}", .code = .indeterminate },
        .{ .payload = "\"result\":{\"content\":\"text\",\"isError\":false}", .code = .indeterminate },
        .{ .payload = "\"result\":{\"content\":{},\"isError\":true}", .code = .indeterminate },
        .{ .payload = "\"result\":{\"content\":null}", .code = .indeterminate },
        .{ .payload = "\"result\":{\"content\":false}", .code = .indeterminate },
        .{ .payload = "\"result\":{\"content\":42}", .code = .indeterminate },
        .{ .payload = "\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}", .code = .succeeded },
        .{ .payload = "\"result\":{\"isError\":true}", .code = .failed },
        .{ .payload = "\"result\":{\"isError\":null}", .code = .indeterminate },
        .{ .payload = "\"result\":{\"isError\":1}", .code = .indeterminate },
        .{ .payload = "\"result\":{\"isError\":\"false\"}", .code = .indeterminate },
        .{ .payload = "\"result\":{\"content\":[],\"structuredContent\":{\"x\":1}}", .code = .succeeded },
        .{ .payload = "\"result\":[]", .code = .indeterminate },
        .{ .payload = "\"error\":{\"code\":-32602,\"message\":\"bad\",\"data\":{}}", .code = .failed },
        .{ .payload = "\"error\":{\"code\":1.5,\"message\":\"bad\"}", .code = .indeterminate },
        .{ .payload = "\"error\":{\"code\":1,\"message\":7}", .code = .indeterminate },
        .{ .payload = "\"error\":{\"code\":1}", .code = .indeterminate },
        .{ .payload = "\"result\":{},\"error\":{\"code\":1,\"message\":\"bad\"}", .code = .indeterminate },
        .{ .payload = "\"method\":\"unexpected\",\"result\":{}", .code = .indeterminate },
        .{ .payload = "\"result\":{\"isError\":false,\"isError\":true}", .code = .succeeded },
        .{ .payload = "\"result\":{\"isError\":true,\"isError\":false}", .code = .failed },
        .{ .payload = "\"result\":{\"resultType\":\"input_required\",\"resultType\":\"complete\"}", .code = .indeterminate },
        .{ .payload = "\"result\":{\"is\\u0045rror\":true}", .code = .failed },
    };
    for (answers) |case| {
        for ([_]u16{ 200, 400, 403, 429, 499, 500, 502, 599 }) |status| {
            for ([_]bool{ false, true }) |is_json| {
                for ([_]bool{ false, true }) |matches| {
                    for ([_]reply.Extent{ .complete, .cut }) |extent| {
                        var bytes: [1024]u8 = undefined;
                        const body = try std.fmt.bufPrint(&bytes, "{{\"jsonrpc\":\"2.0\",\"id\":{d},{s},\"padding\":\"{s}", .{ @as(u64, if (matches) 7 else 8), case.payload, if (extent == .complete) "\"}" else "" });
                        const answer: reply.Answer = .{ .bytes = body, .id = 7, .status = status, .format = if (is_json) .json else null, .extent = extent };
                        const fallback: reply.Code = if (status >= 400 and status < 500) .failed else .indeterminate;
                        const expected = if (is_json and matches and case.code != .indeterminate) case.code else fallback;
                        errdefer std.debug.print("reply parity: HTTP {d}, json={}, matching={}, {s}, {s}\n", .{ status, is_json, matches, @tagName(extent), case.payload });
                        try std.testing.expectEqual(expected, reply.judgeCall(answer));
                        if (extent == .complete) {
                            try std.testing.expectEqual(answerCode(expected), classify(.{ .outcome = reply.readCallAnswer(answer) }));
                        } else {
                            try std.testing.expectEqual(answerCode(expected), classify(.{ .oversized = answer }));
                        }
                    }
                }
            }
        }
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
