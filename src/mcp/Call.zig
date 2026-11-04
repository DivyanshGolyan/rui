//! One MCP `tools/call` on the wire, read to the outcome the model is told
//! (D144 to D146). The owner polls `fd()` for `events()` and calls
//! `advance()`, as with `Request`; closing it with `deinit` cancels the call
//! (D65). Nothing here retries: Rui sends no call id (D61).
//!
//! The arguments are filtered first (`arguments.zig`), so the server gets
//! only the fields its own schema lists, and `description` is the call's
//! `rui_call_description` for the conversation line.
//!
//! Lifetime: a Call holds a Request, so it has one address; its owner
//! initializes it in place. Everything it was given is borrowed until
//! `deinit`; an outcome's slices point into the answer buffer.
const std = @import("std");
const Request = @import("Request.zig");
const post = @import("post.zig");
const reply = @import("reply.zig");
const arguments = @import("arguments.zig");

const Call = @This();

pub const Error = Request.Error || post.Error || error{
    /// The filtered request outgrew its buffer.
    NoRoom,
};

pub const Outcome = union(enum) {
    waiting,
    /// The server's result; `is_error` marks a tool that failed (D144).
    result: reply.CallResult,
    /// The server's JSON-RPC error, which the model sees as text (D144).
    server_error: reply.RpcError,
    /// An HTTP status with no JSON-RPC answer, with the start of its body.
    refused: struct { status: u16, body: []const u8 },
};

current: Request,
/// The call's `rui_call_description`, as written.
description: ?[]const u8,

pub const Input = struct {
    server: post.Server,
    client: post.Client,
    /// The tool's name, decoded, and its saved schema.
    name: []const u8,
    input_schema: []const u8,
    /// The model's arguments, a checked JSON object.
    arguments: []const u8,
    caller: post.Caller,
    id: u64,
    /// Room for the filtered arguments, then for the request.
    scratch: []u8,
    request: []u8,
    answer: []u8,
};

pub fn init(self: *Call, input: Input) Error!void {
    var filtered: std.Io.Writer = .fixed(input.scratch);
    const split = arguments.writeForServer(&filtered, input.input_schema, input.arguments) catch return error.NoRoom;
    var writer: std.Io.Writer = .fixed(input.request);
    post.writeCall(&writer, input.server, input.client, input.id, .{
        .name = input.name,
        .input_schema = input.input_schema,
        .arguments = filtered.buffered(),
        .caller = input.caller,
    }) catch |err| switch (err) {
        error.WriteFailed => return error.NoRoom,
        else => |other| return other,
    };
    self.description = split.description;
    try self.current.init(input.server.target, writer.buffered(), input.id, input.answer);
}

pub fn deinit(self: *Call) void {
    self.current.deinit();
}

pub fn fd(self: *const Call) std.posix.fd_t {
    return self.current.fd();
}

pub fn events(self: *const Call) i16 {
    return self.current.events();
}

/// Whether any request byte left this process: an error before this is
/// "failed, not run", after it "outcome unknown" (D146).
pub fn requestSent(self: *const Call) bool {
    return self.current.requestSent();
}

pub fn advance(self: *Call) Error!Outcome {
    return switch (try self.current.advance()) {
        .waiting => .waiting,
        .failed => |failed| .{ .refused = .{ .status = failed.status, .body = failed.body } },
        .answered => |message| switch (message) {
            .notification => unreachable,
            .rpc_error => |failure| .{ .server_error = failure },
            .result => |found| .{ .result = reply.readCall(found) catch |err| return err },
        },
    };
}

const Script = @import("test_server.zig");
const http1 = @import("../http1/request.zig");

const caller: post.Caller = .{ .session_id = "s1", .parent_session_id = null, .root_session_id = "s1", .turn_id = "t1" };
const saved_schema = "{\"properties\":{\"q\":{},\"rui_call_description\":{}}}";

/// Sends a call to `script` and drives it to its outcome.
fn run(script: *Script, call: *Call, sent: *bool) !Outcome {
    try script.start();
    defer script.stop();
    var url: [64]u8 = undefined;
    const target = try http1.parseTarget(try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/mcp", .{script.port}));
    var scratch: [512]u8 = undefined;
    var wire: [2048]u8 = undefined;
    var answer: [1024]u8 = undefined;
    try call.init(.{
        .server = .{ .target = target, .bearer_token = "t" },
        .client = .{ .name = "rui", .version = "test" },
        .name = "search",
        .input_schema = saved_schema,
        .arguments = "{\"q\":\"x\",\"rui_call_description\":\"Find x\",\"extra\":true}",
        .caller = caller,
        .id = 7,
        .scratch = &scratch,
        .request = &wire,
        .answer = &answer,
    });
    defer call.deinit();
    while (true) {
        const outcome = try call.advance();
        sent.* = call.requestSent();
        if (outcome != .waiting) return keep(outcome);
        var poll_fd = [_]std.c.pollfd{.{ .fd = call.fd(), .events = call.events(), .revents = 0 }};
        if (std.c.poll(&poll_fd, 1, 10_000) <= 0) return error.ConnectionLost;
    }
}

var kept: [1024]u8 = undefined;

/// The tests read an outcome after `run` ended its buffers, so its text is
/// copied out first.
fn keep(outcome: Outcome) Outcome {
    switch (outcome) {
        .result => |found| {
            @memcpy(kept[0..found.content.len], found.content);
            return .{ .result = .{ .is_error = found.is_error, .content = kept[0..found.content.len], .structured = null } };
        },
        .server_error => |failure| {
            @memcpy(kept[0..failure.message.len], failure.message);
            return .{ .server_error = .{ .code = failure.code, .message = kept[0..failure.message.len], .data = null } };
        },
        .refused => |failed| {
            @memcpy(kept[0..failed.body.len], failed.body);
            return .{ .refused = .{ .status = failed.status, .body = kept[0..failed.body.len] } };
        },
        .waiting => unreachable,
    }
}

test "a result carries the server's text, and the server was sent only its own fields" {
    const body = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}";
    var script: Script = .{ .reply = Script.jsonReply(body) };
    var call: Call = undefined;
    var sent = false;
    const outcome = try run(&script, &call, &sent);
    try std.testing.expect(!outcome.result.is_error);
    try std.testing.expectEqualStrings("[{\"type\":\"text\",\"text\":\"hi\"}]", outcome.result.content);
    try std.testing.expect(sent);
    try std.testing.expectEqualStrings("Find x", call.description.?);
    const seen = script.seen[0..script.seen_len];
    try std.testing.expect(std.mem.indexOf(u8, seen, "\"arguments\":{\"q\":\"x\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "extra") == null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "rui_call_description") == null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "dev.rui/sessionId") != null);
}

test "an isError result is a result that says it failed" {
    const body = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"isError\":true,\"content\":[]}}";
    var script: Script = .{ .reply = Script.jsonReply(body) };
    var call: Call = undefined;
    var sent = false;
    try std.testing.expect((try run(&script, &call, &sent)).result.is_error);
}

test "a JSON-RPC error carries the server's own text" {
    const body = "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32602,\"message\":\"bad q\"}}";
    var script: Script = .{ .reply = Script.jsonReply(body) };
    var call: Call = undefined;
    var sent = false;
    const outcome = try run(&script, &call, &sent);
    try std.testing.expectEqualStrings("bad q", outcome.server_error.message);
    try std.testing.expectEqual(@as(i64, -32602), outcome.server_error.code);
}

test "an HTTP error status keeps the start of its body" {
    var script: Script = .{ .reply = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nContent-Length: 4\r\n\r\ndown" };
    var call: Call = undefined;
    var sent = false;
    const outcome = try run(&script, &call, &sent);
    try std.testing.expectEqual(@as(u16, 502), outcome.refused.status);
    try std.testing.expectEqualStrings("down", outcome.refused.body);
}

test "a connection that dies after the request left is an unknown outcome" {
    var script: Script = .{ .reply = "" };
    var call: Call = undefined;
    var sent = false;
    // The server reads the request and closes without answering.
    try std.testing.expectError(error.TruncatedResponse, run(&script, &call, &sent));
    try std.testing.expect(sent);
}
