//! Frozen base renderer used only by the excerpt compatibility oracle.
const std = @import("std");
const utf8_validation = @import("../utf8_validation.zig");
const reply = @import("reply.zig");
const document = @import("document.zig");
const result_parts = @import("result_parts_legacy_test.zig");

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
