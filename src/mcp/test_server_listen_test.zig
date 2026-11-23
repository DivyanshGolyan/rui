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

/// Writes the subscribe request for `id` into `bytes` and points `stream` at it. The caller keeps `bytes` alive
/// for the exchange; the caller deinits `stream`.
fn subscribe(at: http1.Target, id: u64, bytes: *[1024]u8, stream: *Exchange) !void {
    var writer: std.Io.Writer = .fixed(bytes);
    try post.writeListen(&writer, .{ .target = at, .bearer_token = "t" }, .{ .name = "rui", .version = "test" }, id);
    try stream.init(at, writer.buffered());
}

/// Reads the stream until the server closes it without a chunked end: the connection ends with an error or a close.
fn expectConnectionEnd(exchange: *Exchange) !void {
    var poll_fd = [_]std.c.pollfd{.{ .fd = exchange.fd, .events = 0, .revents = 0 }};
    while (true) {
        const event = exchange.advance() catch return;
        switch (event) {
            .waiting => {
                poll_fd[0].events = exchange.events();
                if (std.c.poll(&poll_fd, 1, 10_000) <= 0) return error.ConnectionLost;
            },
            .head, .body => {},
            .end => return error.ChunkedEndAfterDrop,
        }
    }
}

fn targetOf(script: *const Script, address: *[64]u8) !http1.Target {
    const url = std.fmt.bufPrint(address, "http://127.0.0.1:{d}/mcp", .{script.port}) catch unreachable;
    return http1.parseTarget(url);
}

test "EXR-82 a finished listen stream sends its completion result and then the chunked end" {
    var listening: Listening = .{};
    var script: Script = .{ .reply = jsonReply("{}"), .listening = &listening };
    try script.start();
    defer script.stop();
    var address: [64]u8 = undefined;
    const at = try targetOf(&script, &address);

    var request: [1024]u8 = undefined;
    var stream: Exchange = undefined;
    try subscribe(at, 1, &request, &stream);
    defer stream.deinit();
    var got: [2048]u8 = undefined;
    var length: usize = 0;
    try readUntil(&stream, "subscriptions/acknowledged", &got, &length);

    listening.finish();
    try readUntil(&stream, "\"resultType\":\"complete\"", &got, &length);
    // After the completion the stream ends with its chunked terminator, not a dropped connection.
    var poll_fd = [_]std.c.pollfd{.{ .fd = stream.fd, .events = 0, .revents = 0 }};
    while (true) {
        switch (try stream.advance()) {
            .end => break,
            .waiting => {
                poll_fd[0].events = stream.events();
                if (std.c.poll(&poll_fd, 1, 10_000) <= 0) return error.ConnectionLost;
            },
            .head, .body => {},
        }
    }
}

test "EXR-83 a dropped listen stream ends for the client without a chunked end" {
    var listening: Listening = .{};
    var script: Script = .{ .reply = jsonReply("{}"), .listening = &listening };
    try script.start();
    defer script.stop();
    var address: [64]u8 = undefined;
    const at = try targetOf(&script, &address);

    var request: [1024]u8 = undefined;
    var stream: Exchange = undefined;
    try subscribe(at, 1, &request, &stream);
    defer stream.deinit();
    var got: [2048]u8 = undefined;
    var length: usize = 0;
    try readUntil(&stream, "subscriptions/acknowledged", &got, &length);

    listening.drop();
    try expectConnectionEnd(&stream);
}

test "EXR-84 a subscribe the server refuses with 405 gets that status and holds no stream" {
    var listening: Listening = .{ .opening = .{ .status = 405 } };
    var script: Script = .{ .reply = jsonReply("{}"), .listening = &listening };
    try script.start();
    defer script.stop();
    var address: [64]u8 = undefined;
    const at = try targetOf(&script, &address);

    var request: [1024]u8 = undefined;
    var stream: Exchange = undefined;
    try subscribe(at, 1, &request, &stream);
    defer stream.deinit();
    var poll_fd = [_]std.c.pollfd{.{ .fd = stream.fd, .events = 0, .revents = 0 }};
    var status: u16 = 0;
    while (status == 0) {
        switch (try stream.advance()) {
            .head => |head| status = head.status,
            .waiting => {
                poll_fd[0].events = stream.events();
                if (std.c.poll(&poll_fd, 1, 10_000) <= 0) return error.ConnectionLost;
            },
            .body, .end => return error.StreamEnded,
        }
    }
    try std.testing.expectEqual(@as(u16, 405), status);
    try std.testing.expectEqual(@as(u64, 0), listening.accepted());
}

test "EXR-85 an acknowledgment whose filter drops toolsListChanged says so on the wire" {
    var listening: Listening = .{ .opening = .{ .acknowledge = .{ .tools = false } } };
    var script: Script = .{ .reply = jsonReply("{}"), .listening = &listening };
    try script.start();
    defer script.stop();
    var address: [64]u8 = undefined;
    const at = try targetOf(&script, &address);

    var request: [1024]u8 = undefined;
    var stream: Exchange = undefined;
    try subscribe(at, 1, &request, &stream);
    defer stream.deinit();
    var got: [2048]u8 = undefined;
    var length: usize = 0;
    try readUntil(&stream, "subscriptions/acknowledged", &got, &length);
    try std.testing.expect(std.mem.indexOf(u8, got[0..length], "toolsListChanged") == null);
    try std.testing.expect(std.mem.indexOf(u8, got[0..length], "\"notifications\":{}") != null);
    try std.testing.expectEqual(@as(u64, 1), listening.accepted());
}

test "EXR-86 a second listen subscribe closes the first stream and the pushes reach only the second" {
    var listening: Listening = .{};
    var script: Script = .{ .reply = jsonReply("{}"), .listening = &listening };
    try script.start();
    defer script.stop();
    var address: [64]u8 = undefined;
    const at = try targetOf(&script, &address);

    var first_request: [1024]u8 = undefined;
    var first: Exchange = undefined;
    try subscribe(at, 1, &first_request, &first);
    defer first.deinit();
    var first_got: [2048]u8 = undefined;
    var first_length: usize = 0;
    try readUntil(&first, "subscriptions/acknowledged", &first_got, &first_length);

    var second_request: [1024]u8 = undefined;
    var second: Exchange = undefined;
    try subscribe(at, 2, &second_request, &second);
    defer second.deinit();
    var second_got: [2048]u8 = undefined;
    var second_length: usize = 0;
    try readUntil(&second, "subscriptionId\":2", &second_got, &second_length);

    try expectConnectionEnd(&first);
    listening.push("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n");
    try readUntil(&second, "notifications/tools/list_changed", &second_got, &second_length);
    try std.testing.expectEqual(@as(u64, 2), listening.accepted());
}
