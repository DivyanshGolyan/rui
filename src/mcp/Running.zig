//! Owns one call's buffers and deadline until its single resolution. The Host
//! supplies time and readiness; this owner never waits or retries.
const std = @import("std");
const Call = @import("Call.zig");
const post = @import("post.zig");
const result_text = @import("result_text.zig");
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
        const ending: result_text.Ending = if (self.call.requestSent()) .{ .lost = err } else .{ .not_sent = err };
        return try self.finish(out, ending);
    };
    if (outcome == .waiting) return null;
    return try self.finish(out, .{ .outcome = outcome });
}

fn finish(self: *Running, out: *std.Io.Writer, ending: result_text.Ending) !result_text.Code {
    defer self.deinit();
    return result_text.write(out, .{ .server_name = self.server_name, .ended = ending });
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
    const Case = struct { reply: []const u8, code: result_text.Code };
    const cases = [_]Case{
        .{ .reply = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}"), .code = .succeeded },
        .{ .reply = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[],\"isError\":true}}"), .code = .failed },
        .{ .reply = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32602,\"message\":\"bad\"}}"), .code = .failed },
        .{ .reply = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 4\r\n\r\ndown", .code = .failed },
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
    // Bind without listening: the port is reserved but cannot accept a call.
    const socket = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    try std.testing.expect(socket >= 0);
    defer _ = std.c.close(socket);
    var address: std.c.sockaddr.in = std.mem.zeroes(std.c.sockaddr.in);
    address.family = std.c.AF.INET;
    address.addr = @bitCast([4]u8{ 127, 0, 0, 1 });
    if (@hasField(std.c.sockaddr.in, "len")) address.len = @sizeOf(std.c.sockaddr.in);
    try std.testing.expectEqual(@as(c_int, 0), std.c.bind(socket, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)));
    var length: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    try std.testing.expectEqual(@as(c_int, 0), std.c.getsockname(socket, @ptrCast(&address), &length));
    const port = std.mem.bigToNative(u16, address.port);
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

test "Running rejects answers exceeding the per-call buffer as failed" {
    const gpa = std.testing.allocator;
    const running = try gpa.create(Running);
    defer gpa.destroy(running);
    const response = try gpa.alloc(u8, max_answer_bytes + 256);
    defer gpa.free(response);
    var wire: std.Io.Writer = .fixed(response);
    try wire.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{max_answer_bytes + 1});
    try wire.splatByteAll('x', max_answer_bytes + 1);
    var script: Script = .{ .reply = wire.buffered() };
    try script.start();
    defer script.stop();
    try running.start(gpa, testInput(script.port), 0);
    defer running.deinit();
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectEqual(result_text.Code.failed, try drive(running, &out));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "4194304") != null);
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
