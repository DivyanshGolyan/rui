const std = @import("std");
const utf8_validation = @import("../utf8_validation.zig");
const reply = @import("reply.zig");
const document = @import("document.zig");
const result_parts = @import("result_parts.zig");

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

pub const Ended = struct { server_name: []const u8, ended: Ending };

pub fn write(out: *std.Io.Writer, ended: Ended) !Code {
    return (try writeExcerpt(out, ended)).code;
}

pub const Excerpt = struct { code: Code, total: usize, omitted: bool };

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

pub fn writeFull(out: *std.Io.Writer, ended: Ended) !void {
    _ = try render(out, ended);
}

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
            take = utf8_validation.scalarStart(&self.tail, 4);
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

const TextSink = struct {
    out: *std.Io.Writer,

    fn image(self: *TextSink, _: anytype, raw: []const u8) !void {
        try self.out.writeAll(raw);
    }

    fn badImage(self: *TextSink, _: anytype, raw: []const u8) !void {
        try self.out.writeAll(raw);
    }
};

fn render(out: *std.Io.Writer, ended: Ended) !Code {
    var sink: TextSink = .{ .out = out };
    return renderSink(&sink, ended, true);
}

/// Render text to sink.out and deliver image blocks to sink.image/badImage.
/// Callbacks receive the parsed block and its original JSON, borrowed from ended.
pub fn renderParts(sink: anytype, ended: Ended) !Code {
    return renderSink(sink, ended, false);
}

fn renderSink(sink: anytype, ended: Ended, comptime legacy: bool) !Code {
    const out = sink.out;
    const name = ended.server_name;
    const code = classify(ended.ended);
    switch (ended.ended) {
        .outcome => |outcome| switch (outcome) {
            .waiting => unreachable,
            .result => |result| {
                if (result.is_error) try out.writeAll("The tool reported an error:\n");
                var items = document.Items.init(result.content);
                var any = false;
                var previous_image = false;
                while (items.next()) |block| {
                    const part = result_parts.classify(block);
                    const is_image = part == .image;
                    if (any and (legacy or (!previous_image and !is_image))) try out.writeByte('\n');
                    any = true;
                    previous_image = is_image;
                    switch (part) {
                        .text => |text| try document.writeDecoded(out, text),
                        .other => |raw| try out.writeAll(raw),
                        .image => |image| {
                            try out.flush();
                            try sink.image(image, block);
                        },
                        .bad_image => |reason| {
                            try out.flush();
                            try sink.badImage(reason, block);
                        },
                    }
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
            if (timeout.sent) {
                try out.print("Outcome unknown: no reply from MCP server {s} within {d} s. The call may or may not have run; it was not retried.", .{ name, @as(f64, @floatFromInt(timeout.after_ms)) / 1000 });
                return code;
            }
            try out.print("Failed, not run: MCP server {s} did not accept the call within {d} s.", .{ name, @as(f64, @floatFromInt(timeout.after_ms)) / 1000 });
            return code;
        },
    }
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

test "result_text sink preserves block order and routes malformed images" {
    const TestSink = struct {
        out: *std.Io.Writer,
        pub fn image(self: *@This(), value: result_parts.Image, _: []const u8) !void {
            try self.out.print("<image:{s}:{s}>", .{ value.mime, value.data });
        }
        pub fn badImage(self: *@This(), reason: []const u8, _: []const u8) !void {
            try self.out.print("<bad:{s}>", .{reason});
        }
    };
    const ended: Ended = .{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{
        .content = "[{\"type\":\"text\",\"text\":\"a\\nb\"},{\"type\":\"image\",\"data\":\"YQ==\",\"mimeType\":\"image/png\"},{\"type\":\"image\",\"data\":\"Yg==\",\"mimeType\":\"image/jpeg\"},{\"type\":\"image\",\"data\":\"secret\"},{\"type\":\"text\",\"text\":\"end\"},{\"type\":\"audio\"}]",
        .is_error = true,
        .structured = null,
    } } } };
    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var sink: TestSink = .{ .out = &out };
    try std.testing.expectEqual(Code.failed, try renderParts(&sink, ended));
    try std.testing.expectEqualStrings("The tool reported an error:\na\nb<image:image/png:YQ==><image:image/jpeg:Yg==><bad:missing image MIME type>\nend\n{\"type\":\"audio\"}", out.buffered());
    out = .fixed(&buffer);
    try std.testing.expectEqual(Code.failed, try write(&out, ended));
    try std.testing.expectEqualStrings("The tool reported an error:\na\nb\n{\"type\":\"image\",\"data\":\"YQ==\",\"mimeType\":\"image/png\"}\n{\"type\":\"image\",\"data\":\"Yg==\",\"mimeType\":\"image/jpeg\"}\n{\"type\":\"image\",\"data\":\"secret\"}\nend\n{\"type\":\"audio\"}", out.buffered());
}

test "result_text sink propagates image callback errors" {
    const TestSink = struct {
        out: *std.Io.Writer,
        pub fn image(_: *@This(), _: result_parts.Image, _: []const u8) !void {
            return error.ImageRejected;
        }
        pub fn badImage(_: *@This(), _: []const u8, _: []const u8) !void {
            return error.BadImageRejected;
        }
    };
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var sink: TestSink = .{ .out = &out };
    for ([_]struct { content: []const u8, err: anyerror }{
        .{ .content = "[{\"type\":\"image\",\"data\":\"YQ==\",\"mimeType\":\"image/png\"}]", .err = error.ImageRejected },
        .{ .content = "[{\"type\":\"image\"}]", .err = error.BadImageRejected },
    }) |case| {
        try std.testing.expectError(case.err, renderParts(&sink, .{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = case.content, .is_error = false, .structured = null } } } }));
    }
}

test "result_text golden text and non-result endings" {
    const TestSink = struct {
        out: *std.Io.Writer,
        pub fn image(_: *@This(), _: result_parts.Image, _: []const u8) !void {
            return error.UnexpectedImage;
        }
        pub fn badImage(_: *@This(), _: []const u8, _: []const u8) !void {
            return error.UnexpectedImage;
        }
    };
    const cases = [_]struct { ending: Ending, code: Code, expected: []const u8 }{
        .{ .ending = .{ .outcome = .{ .result = .{ .content = "[{\"type\":\"text\",\"text\":\"hello\\nworld\"},{\"type\":\"text\",\"text\":\"again\"},{\"type\":\"audio\"}]", .structured = null, .is_error = false } } }, .code = .succeeded, .expected = "hello\nworld\nagain\n{\"type\":\"audio\"}" },
        .{ .ending = .{ .outcome = .{ .result = .{ .content = "[]", .structured = "{\"a\":1}", .is_error = true } } }, .code = .failed, .expected = "The tool reported an error:\n{\"a\":1}" },
        .{ .ending = .{ .outcome = .{ .result = .{ .content = "[]", .structured = null, .is_error = false } } }, .code = .succeeded, .expected = "(no output)" },
        .{ .ending = .{ .outcome = .{ .server_error = .{ .code = -32602, .message = "bad\\nargument", .data = "{\"field\":1}" } } }, .code = .failed, .expected = "The MCP server returned error -32602: bad\nargument\n{\"field\":1}" },
        .{ .ending = .{ .outcome = .{ .server_error = .{ .code = 1, .message = "bad", .data = null } } }, .code = .failed, .expected = "The MCP server returned error 1: bad" },
        .{ .ending = .{ .outcome = .{ .refused = .{ .status = 403, .body = "denied" } } }, .code = .failed, .expected = "The MCP server answered HTTP 403: denied" },
        .{ .ending = .{ .outcome = .{ .refused = .{ .status = 500, .body = "failure" } } }, .code = .indeterminate, .expected = "Outcome unknown: The MCP server answered HTTP 500. The call may or may not have run; it was not retried.\nfailure" },
        .{ .ending = .{ .not_sent = error.ConnectFailed }, .code = .spawn_failed, .expected = "Failed, not run: Rui could not reach MCP server example (ConnectFailed)." },
        .{ .ending = .{ .lost = error.NoAnswer }, .code = .indeterminate, .expected = "Outcome unknown: the connection to MCP server example failed after the call was sent (NoAnswer). The call may or may not have run; it was not retried." },
        .{ .ending = .{ .timed_out = .{ .after_ms = 1500, .sent = false } }, .code = .spawn_failed, .expected = "Failed, not run: MCP server example did not accept the call within 1.5 s." },
        .{ .ending = .{ .timed_out = .{ .after_ms = 1500, .sent = true } }, .code = .indeterminate, .expected = "Outcome unknown: no reply from MCP server example within 1.5 s. The call may or may not have run; it was not retried." },
        .{ .ending = .{ .stopped = false }, .code = .cancelled, .expected = "Cancelled by Session stop. Failed, not run: the MCP request was not sent." },
        .{ .ending = .{ .stopped = true }, .code = .indeterminate, .expected = "Outcome unknown: Session stop closed the connection after the MCP request was sent. The call may or may not have run; it was not retried." },
        .{ .ending = .{ .oversized = .{ .bytes = "prefix", .id = 7, .status = 500, .extent = .cut } }, .code = .indeterminate, .expected = "Outcome unknown: The MCP server's answer was larger than the 4194304-byte limit; the retained prefix follows. The call may or may not have run; it was not retried.\nprefix" },
        .{ .ending = .{ .oversized = .{ .bytes = "prefix", .id = 7, .status = 403, .extent = .cut } }, .code = .failed, .expected = "The MCP server's answer was larger than the 4194304-byte limit; the retained prefix follows.\nprefix" },
    };
    for (cases) |case| {
        const ended: Ended = .{ .server_name = "example", .ended = case.ending };
        var buffer: [1024]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        var sink: TestSink = .{ .out = &out };
        try std.testing.expectEqual(case.code, try renderParts(&sink, ended));
        try std.testing.expectEqualStrings(case.expected, out.buffered());
        out = .fixed(&buffer);
        try std.testing.expectEqual(case.code, try write(&out, ended));
        try std.testing.expectEqualStrings(case.expected, out.buffered());
    }
}
