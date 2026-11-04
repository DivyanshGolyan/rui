//! MCP 2026-07-28 requests as the bytes of one HTTP/1.1 POST, as values
//! (D64). The protocol is stateless: there is no `initialize` and no
//! session, and every request carries its version, capabilities and client
//! in `_meta` and mirrors its method and name into header fields. A
//! `tools/call` also carries the calling Session, its parent and root, and
//! the Turn (D177, D195, D205); these are context for the server, not a
//! call id, and no call id is sent (D61).
const std = @import("std");
const http1 = @import("../http1/request.zig");
const document = @import("document.zig");
const headers = @import("headers.zig");

pub const protocol_version = "2026-07-28";

pub const Error = headers.Error;

/// The server one request goes to: its loopback target and the static
/// token sent as `Authorization: Bearer` (D120).
pub const Server = struct {
    target: http1.Target,
    bearer_token: []const u8,
};

/// `io.modelcontextprotocol/clientInfo`.
pub const Client = struct {
    name: []const u8,
    version: []const u8,
};

/// Who is calling, as the client API shows these ids (D205).
pub const Caller = struct {
    session_id: []const u8,
    /// Null for a root Session, which then sends no parent key.
    parent_session_id: ?[]const u8,
    root_session_id: []const u8,
    turn_id: []const u8,
};

pub const Call = struct {
    /// The tool's name, decoded.
    name: []const u8,
    /// The tool's saved `inputSchema`, a checked JSON object: its
    /// `x-mcp-header` annotations name the fields the call mirrors.
    input_schema: []const u8,
    /// The arguments the server receives, a checked JSON object holding
    /// only the fields its schema lists (D62).
    arguments: []const u8,
    caller: Caller,
};

/// Writes a `tools/list` request for the page after `cursor`, which is a
/// `nextCursor` string's contents exactly as the server wrote them.
pub fn writeList(writer: *std.Io.Writer, server: Server, client: Client, id: u64, cursor: ?[]const u8) Error!void {
    const body: ListBody = .{ .client = client, .id = id, .cursor = cursor };
    try writeHead(writer, server, "tools/list", null, null, body.length());
    try body.write(writer);
}

/// Writes a `tools/call` request.
pub fn writeCall(writer: *std.Io.Writer, server: Server, client: Client, id: u64, call: Call) Error!void {
    const body: CallBody = .{ .client = client, .id = id, .call = call };
    try writeHead(writer, server, "tools/call", call.name, call, body.length());
    try body.write(writer);
}

/// How many bytes `writeList` or `writeCall` would write with these
/// arguments, so the caller can size the request's buffer first.
pub fn length(comptime write: anytype, args: anytype) Error!usize {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try @call(.auto, write, .{&counter.writer} ++ args);
    return @intCast(counter.fullCount());
}

fn writeHead(writer: *std.Io.Writer, server: Server, method: []const u8, name: ?[]const u8, call: ?Call, body_length: usize) Error!void {
    try http1.beginPost(writer, server.target);
    try http1.writeField(writer, .{ .name = "Accept", .value = "application/json, text/event-stream" });
    try http1.writeField(writer, .{ .name = "Content-Type", .value = "application/json" });
    try http1.writeField(writer, .{ .name = "MCP-Protocol-Version", .value = protocol_version });
    try http1.writeField(writer, .{ .name = "Mcp-Method", .value = method });
    if (name) |tool| try headers.writeValue(writer, "Mcp-Name", tool);
    if (call) |found| try headers.writeParams(writer, found.input_schema, found.arguments);
    try writeBearer(writer, server.bearer_token);
    try http1.endPost(writer, body_length);
}

fn writeBearer(writer: *std.Io.Writer, token: []const u8) Error!void {
    var value: [7 + headers.max_value_bytes]u8 = undefined;
    if (token.len > headers.max_value_bytes) return error.HeaderValueTooLong;
    @memcpy(value[0..7], "Bearer ");
    @memcpy(value[7..][0..token.len], token);
    try http1.writeField(writer, .{ .name = "Authorization", .value = value[0 .. 7 + token.len] });
}

fn writeMeta(writer: *std.Io.Writer, client: Client) std.Io.Writer.Error!void {
    try writer.writeAll("\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"" ++ protocol_version ++ "\"," ++
        "\"io.modelcontextprotocol/clientCapabilities\":{}," ++
        "\"io.modelcontextprotocol/clientInfo\":{\"name\":");
    try document.writeString(writer, client.name);
    try writer.writeAll(",\"version\":");
    try document.writeString(writer, client.version);
    try writer.writeByte('}');
}

const ListBody = struct {
    client: Client,
    id: u64,
    cursor: ?[]const u8,

    fn write(self: ListBody, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/list\",\"params\":{{", .{self.id});
        try writeMeta(writer, self.client);
        try writer.writeByte('}');
        if (self.cursor) |cursor| try writer.print(",\"cursor\":\"{s}\"", .{cursor});
        try writer.writeAll("}}");
    }

    fn length(self: ListBody) usize {
        var counter: std.Io.Writer.Discarding = .init(&.{});
        self.write(&counter.writer) catch unreachable;
        return @intCast(counter.fullCount());
    }
};

const CallBody = struct {
    client: Client,
    id: u64,
    call: Call,

    fn write(self: CallBody, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const caller = self.call.caller;
        try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{", .{self.id});
        try writeMeta(writer, self.client);
        try writer.writeAll(",\"dev.rui/sessionId\":");
        try document.writeString(writer, caller.session_id);
        if (caller.parent_session_id) |parent| {
            try writer.writeAll(",\"dev.rui/parentSessionId\":");
            try document.writeString(writer, parent);
        }
        try writer.writeAll(",\"dev.rui/rootSessionId\":");
        try document.writeString(writer, caller.root_session_id);
        try writer.writeAll(",\"dev.rui/turnId\":");
        try document.writeString(writer, caller.turn_id);
        try writer.writeAll("},\"name\":");
        try document.writeString(writer, self.call.name);
        try writer.writeAll(",\"arguments\":");
        try writer.writeAll(self.call.arguments);
        try writer.writeAll("}}");
    }

    fn length(self: CallBody) usize {
        var counter: std.Io.Writer.Discarding = .init(&.{});
        self.write(&counter.writer) catch unreachable;
        return @intCast(counter.fullCount());
    }
};

const test_server: Server = .{
    .target = .{ .family = .ipv4, .address = .{ 127, 0, 0, 1 } ++ @as([12]u8, @splat(0)), .port = 3000, .authority = "127.0.0.1:3000", .path = "/api/mcp" },
    .bearer_token = "secret-token",
};
const test_client: Client = .{ .name = "rui", .version = "test-version" };

fn expectRequest(expected_head: []const u8, expected_body: []const u8, request: []const u8) !void {
    const split = std.mem.indexOf(u8, request, "\r\n\r\n").? + 4;
    try std.testing.expectEqualStrings(expected_head, request[0..split]);
    try std.testing.expectEqualStrings(expected_body, request[split..]);
    try document.check(request[split..]);
}

test "a tools/list request carries the version in a header and in _meta" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeList(&writer, test_server, test_client, 1, null);
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_meta\":{" ++
        "\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"," ++
        "\"io.modelcontextprotocol/clientCapabilities\":{}," ++
        "\"io.modelcontextprotocol/clientInfo\":{\"name\":\"rui\",\"version\":\"test-version\"}}}}";
    try expectRequest("POST /api/mcp HTTP/1.1\r\nHost: 127.0.0.1:3000\r\n" ++
        "Accept: application/json, text/event-stream\r\nContent-Type: application/json\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: tools/list\r\n" ++
        "Authorization: Bearer secret-token\r\n" ++
        std.fmt.comptimePrint("Content-Length: {d}\r\n", .{body.len}) ++ "Connection: close\r\n\r\n", body, writer.buffered());
    try std.testing.expectEqual(writer.buffered().len, try length(writeList, .{ test_server, test_client, @as(u64, 1), @as(?[]const u8, null) }));

    writer = .fixed(&buffer);
    try writeList(&writer, test_server, test_client, 2, "page\\u0032");
    const request = writer.buffered();
    try std.testing.expect(std.mem.endsWith(u8, request, "}},\"cursor\":\"page\\u0032\"}}"));
    try document.check(request[std.mem.indexOf(u8, request, "\r\n\r\n").? + 4 ..]);
}

test "a tools/call request names the tool and its caller, and mirrors its fields" {
    const schema = "{\"type\":\"object\",\"properties\":{\"region\":{\"type\":\"string\",\"x-mcp-header\":\"Region\"},\"q\":{\"type\":\"string\"}}}";
    const call: Call = .{
        .name = "execute_sql",
        .input_schema = schema,
        .arguments = "{\"region\":\"us-west1\",\"q\":\"select \\\"1\\\"\"}",
        .caller = .{ .session_id = "ses_child", .parent_session_id = "ses_parent", .root_session_id = "ses_root", .turn_id = "turn_7" },
    };
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeCall(&writer, test_server, test_client, 9, call);
    const body = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"_meta\":{" ++
        "\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"," ++
        "\"io.modelcontextprotocol/clientCapabilities\":{}," ++
        "\"io.modelcontextprotocol/clientInfo\":{\"name\":\"rui\",\"version\":\"test-version\"}," ++
        "\"dev.rui/sessionId\":\"ses_child\",\"dev.rui/parentSessionId\":\"ses_parent\"," ++
        "\"dev.rui/rootSessionId\":\"ses_root\",\"dev.rui/turnId\":\"turn_7\"}," ++
        "\"name\":\"execute_sql\",\"arguments\":{\"region\":\"us-west1\",\"q\":\"select \\\"1\\\"\"}}}";
    try expectRequest("POST /api/mcp HTTP/1.1\r\nHost: 127.0.0.1:3000\r\n" ++
        "Accept: application/json, text/event-stream\r\nContent-Type: application/json\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: tools/call\r\nMcp-Name: execute_sql\r\n" ++
        "Mcp-Param-Region: us-west1\r\nAuthorization: Bearer secret-token\r\n" ++
        std.fmt.comptimePrint("Content-Length: {d}\r\n", .{body.len}) ++ "Connection: close\r\n\r\n", body, writer.buffered());
    try std.testing.expectEqual(writer.buffered().len, try length(writeCall, .{ test_server, test_client, @as(u64, 9), call }));
}

test "a root Session sends no parent, and an unsafe name is base64" {
    const call: Call = .{
        .name = "caf\xc3\xa9",
        .input_schema = "{\"type\":\"object\"}",
        .arguments = "{}",
        .caller = .{ .session_id = "ses_root", .parent_session_id = null, .root_session_id = "ses_root", .turn_id = "turn_1" },
    };
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeCall(&writer, test_server, test_client, 3, call);
    const request = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, request, "\r\nMcp-Name: =?base64?Y2Fmw6k=?=\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "parentSessionId") == null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"dev.rui/sessionId\":\"ses_root\",\"dev.rui/rootSessionId\":\"ses_root\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, request, "\"name\":\"caf\xc3\xa9\",\"arguments\":{}}}"));
}

test "a token that cannot be a header value is refused" {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var server = test_server;
    server.bearer_token = "bad\r\ntoken";
    try std.testing.expectError(error.InvalidField, writeList(&writer, server, test_client, 1, null));
    const long: [headers.max_value_bytes + 1]u8 = @splat('t');
    server.bearer_token = &long;
    try std.testing.expectError(error.HeaderValueTooLong, writeList(&writer, server, test_client, 1, null));
}
