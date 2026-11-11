//! Owns one call's buffers and deadline until its single resolution. The Host
//! supplies time and readiness; this owner never waits or retries.
const std = @import("std");
const Call = @import("Call.zig");
const post = @import("post.zig");
const result_text = @import("result_text.zig");
const output_retention = @import("../output_retention.zig");
const named_scratch = @import("../named_scratch.zig");
const Allocator = std.mem.Allocator;
const Running = @This();

pub const max_answer_bytes = result_text.max_answer_bytes;
// post.zig writes _meta and at most sixteen mirrored, bounded header values.
// Variable arguments have their own allowance; an oversized head fails NoRoom.
const request_margin = 32 * 1024;

pub const Input = struct {
    server: post.Server,
    client: post.Client,
    name: []const u8,
    input_schema: []const u8,
    arguments: []const u8,
    caller: post.Caller,
    id: u64,
    server_name: []const u8,
    timeout_ms: u64,
    retention: ?Retention = null,
};

/// Borrowed Host queue and the durable attempt identity used for its filename.
pub const Retention = struct { queue: *output_retention.Queue, action_id: u64, attempt_ordinal: u64 };

const State = union(enum) { active, init_failed: anyerror, done };

call: Call = undefined,
gpa: Allocator,
scratch: []u8,
request: []u8,
answer: []u8,
server_name: []const u8,
timeout_ms: u64,
deadline_ms: u64,
state: State,
retention: ?Retention,

/// Initialize in place and keep this owner at one address until deinit.
/// Input strings are borrowed until resolution or deinit. Only OOM escapes;
/// failures to prepare or connect are reported by the first service call.
pub fn start(self: *Running, gpa: Allocator, input: Input, now_ms: u64) error{OutOfMemory}!void {
    self.* = .{
        .gpa = gpa,
        .scratch = &.{},
        .request = &.{},
        .answer = &.{},
        .server_name = input.server_name,
        .timeout_ms = input.timeout_ms,
        .deadline_ms = now_ms +| input.timeout_ms,
        .state = .done,
        .retention = input.retention,
    };
    errdefer self.deinit();
    self.scratch = try gpa.alloc(u8, input.arguments.len);
    const request_bytes = std.math.add(usize, input.arguments.len, request_margin) catch return error.OutOfMemory;
    self.request = try gpa.alloc(u8, request_bytes);
    self.answer = try gpa.alloc(u8, max_answer_bytes);
    self.call.init(.{
        .server = input.server,
        .client = input.client,
        .name = input.name,
        .input_schema = input.input_schema,
        .arguments = input.arguments,
        .caller = input.caller,
        .id = input.id,
        .scratch = self.scratch,
        .request = self.request,
        .answer = self.answer,
    }) catch |err| {
        // Call.init owns cleanup of a socket it could not initialize. Before
        // that it only writes borrowed buffers, so no Call exists to deinit.
        self.state = .{ .init_failed = err };
        return;
    };
    self.state = .active;
}

/// Closing an active Call cancels it. Safe after resolution or failed start.
pub fn deinit(self: *Running) void {
    if (self.state == .active) self.call.deinit();
    self.state = .done;
    self.gpa.free(self.answer);
    self.gpa.free(self.request);
    self.gpa.free(self.scratch);
    self.answer = &.{};
    self.request = &.{};
    self.scratch = &.{};
}

pub fn fd(self: *const Running) std.posix.fd_t {
    return if (self.state == .active) self.call.fd() else -1;
}

pub fn events(self: *const Running) i16 {
    return if (self.state == .active) self.call.events() else 0;
}

/// Whether cancellation must report an unknown remote outcome.
pub fn requestSent(self: *const Running) bool {
    return self.state == .active and self.call.requestSent();
}

pub fn deadlineMs(self: *const Running) u64 {
    return self.deadline_ms;
}

/// A terminal service writes once and releases all per-call storage, including
/// on writer failure. Further service calls do nothing; a new start may reuse
/// this owner. The deadline wins over a reply not yet observed at that time.
pub fn service(self: *Running, now_ms: u64, out: *std.Io.Writer) !?result_text.Code {
    switch (self.state) {
        .done => return null,
        .init_failed => |err| return try self.finish(out, .{ .not_sent = err }),
        .active => {},
    }
    if (now_ms >= self.deadline_ms) {
        const sent = self.call.requestSent();
        self.call.deinit();
        self.state = .done;
        return try self.finish(out, .{ .timed_out = .{ .after_ms = self.timeout_ms, .sent = sent } });
    }
    const outcome = self.call.advance() catch |err| {
        const prefix = self.call.answerPrefix();
        const ending: result_text.Ending = if (err == error.AnswerTooLarge)
            .{ .oversized = .{ .prefix = prefix.bytes, .id = prefix.id } }
        else if (self.call.requestSent()) .{ .lost = err } else .{ .not_sent = err };
        return try self.finish(out, ending);
    };
    if (outcome == .waiting) return null;
    return try self.finish(out, .{ .outcome = outcome });
}

fn finish(self: *Running, out: *std.Io.Writer, ending: result_text.Ending) !result_text.Code {
    defer self.deinit();
    const ended: result_text.Ended = .{ .server_name = self.server_name, .ended = ending };
    const excerpt = try result_text.writeExcerpt(out, ended);
    if (excerpt.omitted) {
        if (self.retention) |retention| {
            var name_buffer: [96]u8 = undefined;
            const name = named_scratch.NumericName.@"mcp-output".format(&name_buffer, retention.action_id, retention.attempt_ordinal) catch unreachable;
            if (retention.queue.writeFile(name, excerpt.total, ended, result_text.writeFull)) {
                try out.print("\nFull output: {s}/{s}\n", .{ retention.queue.scratch_path, name });
                return excerpt.code;
            }
        }
        // Optional scratch loss must never change the MCP call's outcome.
        try out.writeAll("\nFull output was not retained.\n");
    }
    return excerpt.code;
}

const Script = @import("test_server.zig");
const http1 = @import("../http1/request.zig");
const test_poll = @import("test_poll");

fn testInput(port: u16) Input {
    // Only the port varies; the production target parser is exercised by Call.
    var target = http1.parseTarget("http://127.0.0.1:1/mcp") catch unreachable;
    target.port = port;
    return .{
        .server = .{ .target = target, .bearer_token = "t" },
        .client = .{ .name = "rui", .version = "test" },
        .name = "search",
        .input_schema = "{\"properties\":{\"q\":{}}}",
        .arguments = "{\"q\":\"x\"}",
        .caller = .{ .session_id = "s", .parent_session_id = null, .root_session_id = "s", .turn_id = "t" },
        .id = 7,
        .server_name = "test",
        .timeout_ms = 600_000,
    };
}

const Drive = struct {
    running: *Running,
    out: *std.Io.Writer,
    code: ?result_text.Code = null,

    fn step(self: *Drive) !bool {
        self.code = try self.running.service(1, self.out);
        return self.code != null;
    }
};

fn drive(running: *Running, out: *std.Io.Writer) !result_text.Code {
    var context: Drive = .{ .running = running, .out = out };
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &context, Drive.step);
    return context.code.?;
}

test "Running resolves socket replies and a peer closing after the request" {
    comptime std.debug.assert(result_text.excerpt_bytes == @import("../bash.zig").excerpt_bytes);
    const Case = struct { reply: []const u8, code: result_text.Code };
    const cases = [_]Case{
        .{ .reply = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}"), .code = .succeeded },
        .{ .reply = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[],\"isError\":true}}"), .code = .failed },
        .{ .reply = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32602,\"message\":\"bad\"}}"), .code = .failed },
        .{ .reply = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 4\r\n\r\ndown", .code = .indeterminate },
        .{ .reply = "HTTP/1.1 403 Forbidden\r\nContent-Length: 4\r\n\r\nnope", .code = .failed },
        .{ .reply = "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}", .code = .failed },
        .{ .reply = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}", .code = .indeterminate },
        .{ .reply = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: application/json\r\nContent-Length: 64\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32602,\"message\":\"bad\"}}", .code = .failed },
        .{ .reply = "", .code = .indeterminate },
    };
    const gpa = std.testing.allocator;
    const running = try gpa.create(Running);
    defer gpa.destroy(running);
    for (cases) |case| {
        var script: Script = .{ .reply = case.reply };
        try script.start();
        defer script.stop();
        try running.start(gpa, testInput(script.port), 0);
        defer running.deinit();
        var buffer: [512]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        try std.testing.expectEqual(case.code, try drive(running, &out));
        try std.testing.expect(out.buffered().len > 0);
        try std.testing.expectEqual(@as(usize, 0), running.answer.len);
        try std.testing.expectEqual(@as(std.posix.fd_t, -1), running.fd());
        try std.testing.expectEqual(@as(i16, 0), running.events());
    }
}

test "Running reports nothing listening as not run and expired unsent calls as not run" {
    const gpa = std.testing.allocator;
    const running = try gpa.create(Running);
    defer gpa.destroy(running);
    const port = try @import("../socket_fixture.zig").refusedPort();
    try running.start(gpa, testInput(port), 0);
    defer running.deinit();
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectEqual(result_text.Code.spawn_failed, try drive(running, &out));
    try running.start(gpa, testInput(port), 10);
    out = .fixed(&buffer);
    try std.testing.expectEqual(@as(u64, 600_010), running.deadlineMs());
    try std.testing.expectEqual(result_text.Code.spawn_failed, (try running.service(running.deadlineMs(), &out)).?);
}

test "Running records request preparation failures for the service path" {
    const gpa = std.testing.allocator;
    const running = try gpa.create(Running);
    defer gpa.destroy(running);
    var input = testInput(1);
    const huge = try gpa.alloc(u8, request_margin * 2);
    defer gpa.free(huge);
    @memset(huge, 's');
    input.caller.session_id = huge;
    try running.start(gpa, input, 0);
    defer running.deinit();
    try std.testing.expectEqual(error.NoRoom, running.state.init_failed);
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectEqual(result_text.Code.spawn_failed, (try running.service(0, &out)).?);
}

test "Running deadline cancels a sent call and the holding peer observes close" {
    const gpa = std.testing.allocator;
    const running = try gpa.create(Running);
    defer gpa.destroy(running);
    var script: Script = .{ .reply = "", .hold_reply = true };
    try script.start();
    defer script.stop();
    try running.start(gpa, testInput(script.port), 0);
    defer running.deinit();
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const Sent = struct {
        running: *Running,
        script: *Script,
        out: *std.Io.Writer,
        fn check(self: *@This()) !bool {
            try std.testing.expectEqual(null, try self.running.service(1, self.out));
            return self.script.request_received.load(.acquire);
        }
    };
    var sent: Sent = .{ .running = running, .script = &script, .out = &out };
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &sent, Sent.check);
    try std.testing.expectEqual(result_text.Code.indeterminate, (try running.service(running.deadlineMs(), &out)).?);
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &script.connection_closed, test_poll.isSet);
    try std.testing.expectEqual(@as(usize, 0), running.answer.len);
}

test "Running oversized JSON and SSE answers retain evidence and release the call" {
    const gpa = std.testing.allocator;
    const running = try gpa.create(Running);
    defer gpa.destroy(running);
    const response = try gpa.alloc(u8, max_answer_bytes + 1024);
    defer gpa.free(response);
    const Case = struct { prefix: []const u8, code: result_text.Code };
    for ([_]bool{ false, true }) |sse| {
        for ([_]Case{
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"isError\":false,\"content\":[{\"type\":\"text\",\"text\":\"", .code = .succeeded },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"", .code = .failed },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"", .code = .indeterminate },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32602,\"message\":\"bad\",\"data\":\"", .code = .failed },
        }) |case| {
            var wire: std.Io.Writer = .fixed(response);
            const body_len = max_answer_bytes + 1;
            try wire.print("HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ if (sse) "text/event-stream" else "application/json", body_len + @as(usize, if (sse) 6 else 0) });
            if (sse) try wire.writeAll("data: ");
            try wire.writeAll(case.prefix);
            try wire.splatByteAll('x', body_len - case.prefix.len);
            var script: Script = .{ .reply = wire.buffered() };
            try script.start();
            defer script.stop();
            try running.start(gpa, testInput(script.port), 0);
            defer running.deinit();
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            try std.testing.expectEqual(case.code, try drive(running, &out.writer));
            try std.testing.expect(std.mem.indexOf(u8, out.written(), "4194304-byte limit") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.written(), case.prefix) != null);
            try std.testing.expectEqual(@as(usize, 0), running.answer.len);
            try std.testing.expectEqual(@as(std.posix.fd_t, -1), running.fd());
        }
    }
}

fn allocationFailureCase(gpa: Allocator) !void {
    // Keep the large Call out of the test helper's frame; inject only the
    // allocations owned by start, not the test's storage for Running itself.
    const running = try std.testing.allocator.create(Running);
    defer std.testing.allocator.destroy(running);
    try running.start(gpa, testInput(1), 0);
    defer running.deinit();
}

test "Running start releases partial allocations on every OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureCase, .{});
}

test "Running terminal writer failure still cancels and frees the call" {
    const gpa = std.testing.allocator;
    const running = try gpa.create(Running);
    defer gpa.destroy(running);
    try running.start(gpa, testInput(1), 0);
    defer running.deinit();
    var out: std.Io.Writer = .fixed(&.{});
    try std.testing.expectError(error.WriteFailed, running.service(running.deadlineMs(), &out));
    try std.testing.expectEqual(@as(usize, 0), running.answer.len);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), running.fd());
}

test "Running retains only omitted rendered MCP answers and preserves the excerpt" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [@import("../protocol.zig").max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [4]output_retention.Entry = @splat(.{});
    var queue = output_retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = max_answer_bytes }, &entries);
    defer queue.cleanupAll();
    const running = try gpa.create(Running);
    defer gpa.destroy(running);
    const Case = struct { length: usize, kind: enum { text, mixed_error, structured, rpc_error, refused } = .text };
    for ([_]Case{
        .{ .length = 32 },
        .{ .length = result_text.excerpt_bytes },
        .{ .length = result_text.excerpt_bytes + 128 },
        .{ .length = result_text.excerpt_bytes + 128, .kind = .mixed_error },
        .{ .length = result_text.excerpt_bytes + 128, .kind = .structured },
        .{ .length = result_text.excerpt_bytes + 128, .kind = .rpc_error },
        .{ .length = result_text.excerpt_bytes + 128, .kind = .refused },
    }) |case| {
        const payload = try gpa.alloc(u8, case.length);
        defer gpa.free(payload);
        @memset(payload, 'x');
        if (case.length > result_text.excerpt_bytes) @memcpy(payload[result_text.excerpt_bytes - 1 ..][0..2], "é");
        const body = switch (case.kind) {
            .text => try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}}}", .{payload}),
            .mixed_error => try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{{\"isError\":true,\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}},{{\"type\":\"image\",\"data\":\"x\"}}]}}}}", .{payload}),
            .structured => try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{{\"content\":[],\"structuredContent\":{{\"data\":\"{s}\"}}}}}}", .{payload}),
            .rpc_error => try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{{\"code\":-1,\"message\":\"{s}\"}}}}", .{payload}),
            .refused => try gpa.dupe(u8, payload),
        };
        defer gpa.free(body);
        const full = switch (case.kind) {
            .text, .refused => try std.fmt.allocPrint(gpa, "{s}{s}", .{ if (case.kind == .refused) "The MCP server answered HTTP 502: " else "", payload }),
            .mixed_error => try std.fmt.allocPrint(gpa, "The tool reported an error:\n{s}\n{{\"type\":\"image\",\"data\":\"x\"}}", .{payload}),
            .structured => try std.fmt.allocPrint(gpa, "{{\"data\":\"{s}\"}}", .{payload}),
            .rpc_error => try std.fmt.allocPrint(gpa, "The MCP server returned error -1: {s}", .{payload}),
        };
        defer gpa.free(full);
        const wire = try std.fmt.allocPrint(gpa, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ if (case.kind == .refused) "502 Bad Gateway" else "200 OK", if (case.kind == .refused) "text/plain" else "application/json", body.len, body });
        defer gpa.free(wire);
        var script: Script = .{ .reply = wire };
        try script.start();
        defer script.stop();
        var input = testInput(script.port);
        input.retention = .{ .queue = &queue, .action_id = 17, .attempt_ordinal = 1 };
        try running.start(gpa, input, 0);
        defer running.deinit();
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const expected_code: result_text.Code = switch (case.kind) {
            .text, .structured => .succeeded,
            else => .failed,
        };
        try std.testing.expectEqual(expected_code, try drive(running, &out.writer));
        if (full.len <= result_text.excerpt_bytes) {
            try std.testing.expectEqualStrings(full, out.written());
            try std.testing.expectEqual(@as(usize, 0), queue.occupied());
            try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "mcp-output-17-1.tmp", .{}));
        } else {
            var kept: usize = result_text.excerpt_bytes;
            while (full[kept] & 0xc0 == 0x80) kept -= 1;
            const expected = try std.fmt.allocPrint(gpa, "{s}\n[{d} more bytes not shown]\nFull output: {s}/mcp-output-17-1.tmp\n", .{ full[0..kept], full.len - kept, root });
            defer gpa.free(expected);
            try std.testing.expectEqualStrings(expected, out.written());
            const saved = try tmp.dir.readFileAlloc(std.testing.io, "mcp-output-17-1.tmp", gpa, .limited(max_answer_bytes));
            defer gpa.free(saved);
            try std.testing.expectEqualStrings(full, saved);
            try std.testing.expectEqual(@as(u64, full.len), used.load(.acquire));
            try std.testing.expectEqual(@as(usize, 1), queue.occupied());
            queue.cleanupAll();
            // Losing optional scratch never rewrites the saved resolution.
            try std.testing.expectEqualStrings(expected, out.written());
        }
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    }
}

test "Running reports optional MCP retention refusal without changing success" {
    const gpa = std.testing.allocator;
    const payload: [result_text.excerpt_bytes + 1]u8 = @splat('x');
    const wire = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"" ++ payload ++ "\"}]}}");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [@import("../protocol.zig").max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const running = try gpa.create(Running);
    defer gpa.destroy(running);
    const Reason = enum { absent, budget, capacity, reserved, sequence, create };
    for (std.meta.tags(Reason)) |reason| {
        var used: std.atomic.Value(u64) = .init(0);
        var entries: [2]output_retention.Entry = @splat(.{});
        var queue = output_retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = if (reason == .budget) 1 else max_answer_bytes }, if (reason == .capacity) &.{} else &entries);
        defer queue.cleanupAll();
        if (reason == .reserved) _ = try queue.reservePair("protected-out", 0, "protected-err", 0);
        if (reason == .sequence) queue.next_sequence = std.math.maxInt(u64);
        if (reason == .create) try tmp.dir.createDir(std.testing.io, "mcp-output-17-1.tmp", .default_dir);
        defer if (reason == .create) tmp.dir.deleteDir(std.testing.io, "mcp-output-17-1.tmp") catch {};
        var script: Script = .{ .reply = wire };
        try script.start();
        defer script.stop();
        var input = testInput(script.port);
        if (reason != .absent) input.retention = .{ .queue = &queue, .action_id = 17, .attempt_ordinal = 1 };
        try running.start(gpa, input, 0);
        defer running.deinit();
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try std.testing.expectEqual(result_text.Code.succeeded, try drive(running, &out.writer));
        try std.testing.expectEqualStrings(payload[0..result_text.excerpt_bytes] ++ "\n[1 more bytes not shown]\nFull output was not retained.\n", out.written());
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
        try std.testing.expectEqual(@as(usize, if (reason == .reserved) 2 else 0), queue.occupied());
    }
}
