const std = @import("std");
const utf8_validation = @import("../utf8_validation.zig");
const Call = @import("Call.zig");
const post = @import("post.zig");
const result_text = @import("result_text.zig");
const output_retention = @import("../output_retention.zig");
const pages = @import("../os/pages.zig");
const Allocator = std.mem.Allocator;
const Running = @This();

pub const max_answer_bytes = result_text.max_answer_bytes;
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
};

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
    };
    errdefer self.deinit();
    self.scratch = try gpa.alloc(u8, input.arguments.len);
    const request_bytes = std.math.add(usize, input.arguments.len, request_margin) catch return error.OutOfMemory;
    self.request = try gpa.alloc(u8, request_bytes);
    self.answer = pages.mapZeroed(u8, max_answer_bytes) catch return error.OutOfMemory;
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
        self.state = .{ .init_failed = err };
        return;
    };
    self.state = .active;
}

pub fn deinit(self: *Running) void {
    if (self.state == .active) self.call.deinit();
    self.state = .done;
    pages.unmapZeroed(self.answer);
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

pub fn requestSent(self: *const Running) bool {
    return self.state == .active and self.call.requestSent();
}

pub fn deadlineMs(self: *const Running) u64 {
    return self.deadline_ms;
}

/// The returned ending borrows the answer allocation until deinit. The
/// caller must render and settle it before releasing Running.
pub fn poll(self: *Running, now_ms: u64) ?result_text.Ended {
    switch (self.state) {
        .done => return null,
        .init_failed => |err| return self.finish(.{ .not_sent = err }),
        .active => {},
    }
    if (now_ms >= self.deadline_ms) {
        const sent = self.call.requestSent();
        return self.finish(.{ .timed_out = .{ .after_ms = self.timeout_ms, .sent = sent } });
    }
    const outcome = self.call.advance() catch |err| {
        const ending: result_text.Ending = if (err == error.AnswerTooLarge)
            .{ .oversized = self.call.answerPrefix() }
        else if (self.call.requestSent()) .{ .lost = err } else .{ .not_sent = err };
        return self.finish(ending);
    };
    if (outcome == .waiting) return null;
    return self.finish(.{ .outcome = outcome });
}

fn finish(self: *Running, ending: result_text.Ending) result_text.Ended {
    if (self.state == .active) self.call.deinit();
    self.state = .done;
    return .{ .server_name = self.server_name, .ended = ending };
}

const Script = @import("test_server.zig");
const http1 = @import("../http1/request.zig");
const test_poll = @import("test_poll");

fn testInput(port: u16) Input {
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
    ended: ?result_text.Ended = null,

    fn step(self: *Drive) !bool {
        self.ended = self.running.poll(1);
        return self.ended != null;
    }
};

fn drive(running: *Running) !result_text.Ended {
    var context: Drive = .{ .running = running };
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &context, Drive.step);
    return context.ended.?;
}

test "Running resolves socket replies and a peer closing after the request" {
    const Case = struct { reply: []const u8, code: result_text.Code };
    const cases = [_]Case{
        .{ .reply = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}"), .code = .succeeded },
        .{ .reply = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[],\"isError\":true}}"), .code = .failed },
        .{ .reply = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resultType\":\"input_required\",\"isError\":false,\"content\":[]}}"), .code = .indeterminate },
        .{ .reply = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resultType\":\"complete\",\"isError\":false,\"content\":\"text\"}}"), .code = .indeterminate },
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
        const ended = try drive(running);
        try std.testing.expectEqual(case.code, result_text.classify(ended.ended));
        try std.testing.expectEqualStrings("test", ended.server_name);
        try std.testing.expectEqual(@as(usize, max_answer_bytes), running.answer.len);
        try std.testing.expectEqual(null, running.poll(1));
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
    try std.testing.expectEqual(result_text.Code.spawn_failed, result_text.classify((try drive(running)).ended));
    running.deinit();
    try running.start(gpa, testInput(port), 10);
    try std.testing.expectEqual(@as(u64, 600_010), running.deadlineMs());
    try std.testing.expectEqual(result_text.Code.spawn_failed, result_text.classify(running.poll(running.deadlineMs()).?.ended));
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
    try std.testing.expectEqual(result_text.Code.spawn_failed, result_text.classify(running.poll(0).?.ended));
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
    const Sent = struct {
        running: *Running,
        script: *Script,
        fn check(self: *@This()) !bool {
            try std.testing.expectEqual(null, self.running.poll(1));
            return self.script.request_received.load(.acquire);
        }
    };
    var sent: Sent = .{ .running = running, .script = &script };
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &sent, Sent.check);
    try std.testing.expectEqual(result_text.Code.indeterminate, result_text.classify(running.poll(running.deadlineMs()).?.ended));
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &script.connection_closed, test_poll.isSet);
    try std.testing.expectEqual(@as(usize, max_answer_bytes), running.answer.len);
    running.deinit();
    try std.testing.expectEqual(@as(usize, 0), running.answer.len);
}

fn allocationFailureCase(gpa: Allocator) !void {
    const running = try std.testing.allocator.create(Running);
    defer std.testing.allocator.destroy(running);
    try running.start(gpa, testInput(1), 0);
    defer running.deinit();
}

test "Running start releases partial allocations on every OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureCase, .{});
}

test "Running oversized JSON and SSE answers preserve borrowed evidence until release" {
    const gpa = std.testing.allocator;
    const running = try gpa.create(Running);
    defer gpa.destroy(running);
    const response = try gpa.alloc(u8, max_answer_bytes + 1024);
    defer gpa.free(response);
    const Case = struct { prefix: []const u8, code: result_text.Code, status: u16 = 200 };
    for ([_]bool{ false, true }) |sse| {
        for ([_]Case{
            .{ .prefix = "not a JSON-RPC answer: ", .code = .failed, .status = 403 },
            .{ .prefix = "not a JSON-RPC answer: ", .code = .indeterminate, .status = 502 },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{\"isError\":false,\"content\":[", .code = .failed, .status = 403 },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resultType\":\"input_required\",\"isError\":false,\"content\":[", .code = .indeterminate },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resultType\":\"complete\",\"isError\":false,\"content\":\"", .code = .indeterminate },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resultType\":\"complete\",\"isError\":false,\"content\":[{\"type\":\"text\",\"text\":\"", .code = .succeeded },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resultType\":\"complete\",\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"", .code = .failed },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"", .code = .indeterminate },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32602,\"message\":\"bad\",\"data\":\"", .code = .failed },
        }) |case| {
            var wire: std.Io.Writer = .fixed(response);
            const body_len = max_answer_bytes + 1;
            try wire.print("HTTP/1.1 {d} Test\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ case.status, if (sse) "text/event-stream" else "application/json", body_len + @as(usize, if (sse) 6 else 0) });
            if (sse) try wire.writeAll("data: ");
            try wire.writeAll(case.prefix);
            try wire.splatByteAll('x', body_len - case.prefix.len);
            var script: Script = .{ .reply = wire.buffered() };
            try script.start();
            defer script.stop();
            try running.start(gpa, testInput(script.port), 0);
            defer running.deinit();
            const ended = try drive(running);
            try std.testing.expectEqual(case.code, result_text.classify(ended.ended));
            const answer = switch (ended.ended) {
                .oversized => |value| value,
                else => return error.ExpectedOversized,
            };
            try std.testing.expect(std.mem.indexOf(u8, answer.bytes, case.prefix) != null);
            try std.testing.expect(answer.bytes.len > result_text.excerpt_bytes);
            try std.testing.expectEqual(@as(usize, max_answer_bytes), running.answer.len);
            try std.testing.expectEqual(@as(std.posix.fd_t, -1), running.fd());
            try std.testing.expectEqual(null, running.poll(1));
        }
    }
}
