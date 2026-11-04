//! One MCP request on the wire: an HTTP/1.1 exchange, and its reply read
//! into the one JSON-RPC message that answers it. The owner polls `fd()`
//! for `events()` and calls `advance()`, as with `http1.Exchange`; nothing
//! here blocks or runs on its own.
//!
//! The answer is read into the caller's buffer, which bounds it. In an SSE
//! reply each event is read there in turn, and notifications such as
//! progress are dropped before the next (D65). The connection closes once
//! the answer is in, or on `deinit`, which is how a call is cancelled.
//!
//! Lifetime: a Request holds an Exchange, so it has one address; its owner
//! initializes it in place. The request bytes and the answer buffer are
//! borrowed until `deinit`; an outcome's slices point into the buffer.
const std = @import("std");
const Exchange = @import("../http1/Exchange.zig");
const http1 = @import("../http1/request.zig");
const EventStream = @import("EventStream.zig");
const reply = @import("reply.zig");

const Request = @This();

pub const Error = Exchange.Error || reply.Invalid || @import("document.zig").Error || error{
    /// The answer outgrew the caller's buffer.
    AnswerTooLarge,
    /// The reply ended without a message answering the request.
    NoAnswer,
};

pub const Outcome = union(enum) {
    waiting,
    /// The server's JSON-RPC answer.
    answered: reply.Message,
    /// An HTTP status that carries no JSON-RPC answer, with the start of
    /// its body as the server wrote it, for the error the model sees.
    failed: struct { status: u16, body: []const u8 },
};

const Reading = union(enum) {
    head,
    body: reply.Body,
    failed: u16,
};

exchange: Exchange,
id: u64,
reading: Reading,
stream: EventStream,
answer: std.Io.Writer,
overflowed: bool,

/// Opens the connection and starts sending `bytes`, a request that
/// `request.writeList` or `request.writeCall` wrote with id `id`.
pub fn init(self: *Request, target: http1.Target, bytes: []const u8, id: u64, buffer: []u8) error{ LocalFailure, ConnectFailed }!void {
    self.id = id;
    self.reading = .head;
    self.stream = .{};
    self.answer = .fixed(buffer);
    self.overflowed = false;
    try self.exchange.init(target, bytes);
}

pub fn deinit(self: *Request) void {
    self.exchange.deinit();
}

pub fn fd(self: *const Request) std.posix.fd_t {
    return self.exchange.fd;
}

pub fn events(self: *const Request) i16 {
    return self.exchange.events();
}

/// Whether any request byte left this process: the line between "failed,
/// not run" and "outcome unknown" (D146).
pub fn requestSent(self: *const Request) bool {
    return self.exchange.requestSent();
}

pub fn advance(self: *Request) Error!Outcome {
    while (true) {
        switch (try self.exchange.advance()) {
            .waiting => return .waiting,
            .head => |head| self.reading = switch (reply.reading(head.status, head.field("Content-Type"))) {
                .body => |body| .{ .body = body },
                .failed => |status| .{ .failed = status },
            },
            .body => |bytes| if (try self.take(bytes)) |outcome| {
                self.exchange.deinit();
                return outcome;
            },
            .end => return self.ended(),
        }
    }
}

/// Reads body bytes; returns the outcome once they complete it.
fn take(self: *Request, bytes: []const u8) Error!?Outcome {
    switch (self.reading) {
        .head => unreachable,
        .failed => {
            // Keep what fits: it is only the start of the server's words.
            const room = self.answer.unusedCapacityLen();
            self.answer.writeAll(bytes[0..@min(room, bytes.len)]) catch unreachable;
            return null;
        },
        .body => |body| switch (body) {
            .json => {
                self.answer.writeAll(bytes) catch return error.AnswerTooLarge;
                return null;
            },
            .event_stream => {
                var rest = bytes;
                while (rest.len != 0) {
                    const step = self.stream.next(rest, &self.answer) catch return error.AnswerTooLarge;
                    rest = rest[step.used..];
                    if (!step.dispatched) break;
                    const message = try reply.readMessage(self.answer.buffered(), self.id);
                    if (message != .notification) return .{ .answered = message };
                    self.answer.end = 0;
                }
                return null;
            },
        },
    }
}

fn ended(self: *Request) Error!Outcome {
    return switch (self.reading) {
        .head => unreachable,
        .failed => |status| .{ .failed = .{ .status = status, .body = self.answer.buffered() } },
        .body => |body| switch (body) {
            .json => json: {
                const message = try reply.readMessage(self.answer.buffered(), self.id);
                // A body of only a notification answers nothing.
                if (message == .notification) return error.NoAnswer;
                break :json .{ .answered = message };
            },
            // The stream closed before the answer: a lost request.
            .event_stream => error.NoAnswer,
        },
    };
}

// Tests run a scripted loopback server on a thread, as the HTTP/1.1
// client's own tests do.

const Script = @import("test_server.zig");

const request = @import("request.zig");

/// Sends a tools/list to `script` and drives the reply to its outcome.
fn run(script: *Script, buffer: []u8) !Outcome {
    try script.start();
    defer script.stop();
    var url: [64]u8 = undefined;
    const target = http1.parseTarget(std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/mcp", .{script.port}) catch unreachable) catch unreachable;
    var bytes: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    request.writeList(&writer, .{ .target = target, .bearer_token = "t" }, .{ .name = "rui", .version = "test" }, 5, null) catch unreachable;
    const self = std.testing.allocator.create(Request) catch unreachable;
    defer std.testing.allocator.destroy(self);
    try self.init(target, writer.buffered(), 5, buffer);
    defer self.deinit();
    while (true) {
        const outcome = try self.advance();
        if (outcome != .waiting) return outcome;
        var poll_fd = [_]std.c.pollfd{.{ .fd = self.fd(), .events = self.events(), .revents = 0 }};
        if (std.c.poll(&poll_fd, 1, 10_000) <= 0) return error.ConnectionLost;
    }
}

const tools_result = "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"tools\":[]}}";

test "a JSON reply is read whole as the answer" {
    var script: Script = .{ .reply = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{tools_result.len}) ++ tools_result };
    var buffer: [256]u8 = undefined;
    const outcome = try run(&script, &buffer);
    try std.testing.expectEqualStrings("{\"tools\":[]}", outcome.answered.result);
    try std.testing.expect(std.mem.indexOf(u8, script.seen[0..script.seen_len], "\r\nMcp-Method: tools/list\r\n") != null);
}

test "a JSON body of only a notification is not an answer" {
    const note = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}";
    var script: Script = .{ .reply = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{note.len}) ++ note };
    var buffer: [256]u8 = undefined;
    try std.testing.expectError(error.NoAnswer, run(&script, &buffer));
}

test "an SSE reply skips progress and answers with the response event" {
    const progress = ": keep-alive\n\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n";
    const answer = "data: " ++ tools_result ++ "\n\n";
    // Chunks split the events where they please; the server would keep
    // the stream open, and the answer is enough.
    var script: Script = .{ .reply = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        std.fmt.comptimePrint("{x}\r\n", .{progress.len + 10}) ++ progress ++ answer[0..10] ++ "\r\n" ++
        std.fmt.comptimePrint("{x}\r\n", .{answer.len - 10}) ++ answer[10..] ++ "\r\n" };
    var buffer: [256]u8 = undefined;
    const outcome = try run(&script, &buffer);
    try std.testing.expectEqualStrings("{\"tools\":[]}", outcome.answered.result);
}

test "an SSE reply that ends without the answer is a lost request" {
    var script: Script = .{ .reply = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n" };
    var buffer: [256]u8 = undefined;
    try std.testing.expectError(error.NoAnswer, run(&script, &buffer));
}

test "an error status with JSON carries the server's JSON-RPC error" {
    const body = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[\"2025-11-25\"]}}}";
    var script: Script = .{ .reply = std.fmt.comptimePrint("HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{body.len}) ++ body };
    var buffer: [256]u8 = undefined;
    const outcome = try run(&script, &buffer);
    try std.testing.expectEqual(@as(i64, -32022), outcome.answered.rpc_error.code);
}

test "any other status keeps the start of the server's words" {
    var script: Script = .{ .reply = "HTTP/1.1 401 Unauthorized\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nbad token now" };
    var buffer: [8]u8 = undefined;
    const outcome = try run(&script, &buffer);
    try std.testing.expectEqual(@as(u16, 401), outcome.failed.status);
    try std.testing.expectEqualStrings("bad toke", outcome.failed.body);
}

test "an answer larger than the buffer is refused" {
    var script: Script = .{ .reply = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{tools_result.len}) ++ tools_result };
    var buffer: [16]u8 = undefined;
    try std.testing.expectError(error.AnswerTooLarge, run(&script, &buffer));
}
