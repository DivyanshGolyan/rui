//! The test MCP server's held listen stream, driven over the real client transport. Kept apart from
//! test_server.zig so the fixture does not import the client it serves.

const std = @import("std");
const Exchange = @import("../http1/Exchange.zig");
const http1 = @import("../http1/request.zig");
const post = @import("post.zig");
const Request = @import("Request.zig");
const Script = @import("test_server.zig");
const Listening = Script.Listening;
const jsonReply = Script.jsonReply;

/// Reads the stream's body into `got` until `needle` is in it. Bytes read past an earlier needle stay in
/// `got`, so a later call still finds an event that arrived in the same read.
fn readUntil(exchange: *Exchange, needle: []const u8, got: []u8, length: *usize) !void {
    var poll_fd = [_]std.c.pollfd{.{ .fd = exchange.fd, .events = 0, .revents = 0 }};
    while (std.mem.indexOf(u8, got[0..length.*], needle) == null) {
        switch (try exchange.advance()) {
            // Only an exchange that has nothing buffered waits on the socket: a head and its body
            // can arrive in one read, and polling then would wait for bytes already taken.
            .waiting => {
                poll_fd[0].events = exchange.events();
                if (std.c.poll(&poll_fd, 1, 10_000) <= 0) return error.ConnectionLost;
            },
            .head => {},
            .body => |bytes| {
                if (length.* + bytes.len > got.len) return error.StreamTooLong;
                @memcpy(got[length.*..][0..bytes.len], bytes);
                length.* += bytes.len;
            },
            .end => return error.StreamEnded,
        }
    }
}

test "EXR-78 a held subscriptions/listen stream gets a pushed list change while a tools/list on the same server is answered" {
    const tools = "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"tools\":[]}}";
    var listening: Listening = .{};
    var script: Script = .{ .reply = jsonReply(tools), .listening = &listening };
    try script.start();
    defer script.stop();
    var address: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&address, "http://127.0.0.1:{d}/mcp", .{script.port}) catch unreachable;
    const at = try http1.parseTarget(url);

    var bytes: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try post.writeListen(&writer, .{ .target = at, .bearer_token = "t" }, .{ .name = "rui", .version = "test" }, 1);
    var stream: Exchange = undefined;
    try stream.init(at, writer.buffered());
    defer stream.deinit();
    var got: [2048]u8 = undefined;
    var length: usize = 0;
    try readUntil(&stream, "subscriptions/acknowledged", &got, &length);

    listening.push("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n");

    var list_bytes: [1024]u8 = undefined;
    var list_writer: std.Io.Writer = .fixed(&list_bytes);
    try post.writeList(&list_writer, .{ .target = at, .bearer_token = "t" }, .{ .name = "rui", .version = "test" }, 5, null);
    var request: Request = undefined;
    var buffer: [256]u8 = undefined;
    try request.init(at, list_writer.buffered(), 5, &buffer);
    defer request.deinit();
    var poll_fd = [_]std.c.pollfd{.{ .fd = request.fd(), .events = 0, .revents = 0 }};
    const outcome = while (true) {
        const next = try request.advance();
        if (next != .waiting) break next;
        poll_fd[0].events = request.events();
        if (std.c.poll(&poll_fd, 1, 10_000) <= 0) return error.ConnectionLost;
    };
    try std.testing.expectEqualStrings("{\"tools\":[]}", outcome.answered.result);

    try readUntil(&stream, "notifications/tools/list_changed", &got, &length);
    listening.finish();
}
