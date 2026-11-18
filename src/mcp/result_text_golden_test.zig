const std = @import("std");
const result_parts = @import("result_parts.zig");
const result_text = @import("result_text.zig");
const Code = result_text.Code;
const Ending = result_text.Ending;
const Ended = result_text.Ended;
const render = result_text.render;

fn legacyWrite(out: *std.Io.Writer, ended: Ended) !Code {
    const legacy = @import("result_text_legacy_test.zig");
    const ending: legacy.Ending = switch (ended.ended) {
        .outcome => |value| .{ .outcome = value },
        .not_sent => |value| .{ .not_sent = value },
        .lost => |value| .{ .lost = value },
        .timed_out => |value| .{ .timed_out = .{ .after_ms = value.after_ms, .sent = value.sent } },
        .stopped => |value| .{ .stopped = value },
        .oversized => |value| .{ .oversized = value },
    };
    return @fromBackingInt(@intCast(@backingInt(try legacy.write(out, .{ .server_name = ended.server_name, .ended = ending }))));
}

test "result_text golden text and non-result endings" {
    const TestSink = struct {
        out: *std.Io.Writer,
        pub fn image(_: *@This(), _: result_parts.Image, _: []const u8, _: bool) !void {
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
        try std.testing.expectEqual(case.code, try render(&sink, ended));
        try std.testing.expectEqualStrings(case.expected, out.buffered());
        out = .fixed(&buffer);
        try std.testing.expectEqual(case.code, try legacyWrite(&out, ended));
        try std.testing.expectEqualStrings(case.expected, out.buffered());
    }
}
