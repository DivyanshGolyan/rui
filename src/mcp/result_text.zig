//! The model-facing resolution of one MCP call, bounded without retaining a copy.
const std = @import("std");
const Call = @import("Call.zig");
const document = @import("document.zig");

// Kept equal to bash.zig's excerpt_bytes; the test below checks both owners.
pub const excerpt_bytes = 10_000;
pub const max_answer_bytes = 4 * 1024 * 1024;
pub const Code = enum { succeeded, failed, spawn_failed, indeterminate };
pub const Ending = union(enum) {
    outcome: Call.Outcome,
    not_sent: anyerror,
    lost: anyerror,
    timed_out: struct { after_ms: u64, sent: bool },
};

/// The server name accompanies the transport's ending, not its borrowed result.
pub const Ended = struct { server_name: []const u8, ended: Ending };

pub fn write(out: *std.Io.Writer, ended: Ended) !Code {
    var bounded: Prefix = .{ .out = out };
    const code = try render(&bounded.writer, ended);
    try bounded.writer.flush();
    try bounded.finish();
    if (bounded.total > bounded.shown) {
        try out.print("\n[{d} more bytes not shown]", .{bounded.total - bounded.shown});
    }
    return code;
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
                return if (result.is_error) .failed else .succeeded;
            },
            .server_error => |failure| {
                try out.print("The MCP server returned error {d}: ", .{failure.code});
                try document.writeDecoded(out, failure.message);
                if (failure.data) |data| {
                    try out.writeByte('\n');
                    try out.writeAll(data);
                }
                return .failed;
            },
            .refused => |failure| {
                try out.print("The MCP server answered HTTP {d}: {s}", .{ failure.status, failure.body });
                return .failed;
            },
        },
        .not_sent => |err| {
            try out.print("Failed, not run: Rui could not reach MCP server {s} ({s}).", .{ name, @errorName(err) });
            return .spawn_failed;
        },
        .lost => |err| {
            if (err == error.AnswerTooLarge) {
                try out.print("The MCP server's answer is larger than {d} bytes.", .{max_answer_bytes});
                return .failed;
            }
            try out.print("Outcome unknown: the connection to MCP server {s} failed after the call was sent ({s}). The call may or may not have run; it was not retried.", .{ name, @errorName(err) });
            return .indeterminate;
        },
        .timed_out => |timeout| {
            // Millisecond precision avoids calling a sub-second deadline zero seconds.
            if (timeout.sent) {
                try out.print("Outcome unknown: no reply from MCP server {s} within {d} s. The call may or may not have run; it was not retried.", .{ name, @as(f64, @floatFromInt(timeout.after_ms)) / 1000 });
                return .indeterminate;
            }
            try out.print("Failed, not run: MCP server {s} did not accept the call within {d} s.", .{ name, @as(f64, @floatFromInt(timeout.after_ms)) / 1000 });
            return .spawn_failed;
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
    comptime std.debug.assert(excerpt_bytes == @import("../bash.zig").excerpt_bytes);
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

test "result_text transport endings and server failures resolve by certainty" {
    const Case = struct { ending: Ending, code: Code, contains: []const u8 };
    const cases = [_]Case{
        .{ .ending = .{ .not_sent = error.ConnectFailed }, .code = .spawn_failed, .contains = "ConnectFailed" },
        .{ .ending = .{ .lost = error.NoAnswer }, .code = .indeterminate, .contains = "not retried" },
        .{ .ending = .{ .lost = error.AnswerTooLarge }, .code = .failed, .contains = "4194304" },
        .{ .ending = .{ .timed_out = .{ .after_ms = 1500, .sent = false } }, .code = .spawn_failed, .contains = "1.5 s" },
        .{ .ending = .{ .timed_out = .{ .after_ms = 600_000, .sent = true } }, .code = .indeterminate, .contains = "600 s" },
        .{ .ending = .{ .outcome = .{ .server_error = .{ .code = -32602, .message = "bad\\nargument", .data = "{\"field\":1}" } } }, .code = .failed, .contains = "bad\nargument\n{\"field\":1}" },
        .{ .ending = .{ .outcome = .{ .refused = .{ .status = 502, .body = "gateway" } } }, .code = .failed, .contains = "502" },
        .{ .ending = .{ .outcome = .{ .result = .{ .is_error = false, .content = "[]", .structured = null } } }, .code = .succeeded, .contains = "(no output)" },
    };
    for (cases) |case| {
        var buffer: [512]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        try std.testing.expectEqual(case.code, try write(&out, .{ .server_name = "test", .ended = case.ending }));
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), case.contains) != null);
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
        _ = try write(&out, .{ .server_name = "test", .ended = .{ .outcome = .{ .refused = .{ .status = 502, .body = content[0 .. length - "The MCP server answered HTTP 502: ".len] } } } });
        try std.testing.expectEqual(length, out.buffered().len);
    }
}
