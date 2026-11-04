//! What an MCP server answered, as values: how to read the HTTP body, the
//! JSON-RPC message in it, and the `tools/list` and `tools/call` results
//! (D65). Every slice returned points into the message the caller passed.
//!
//! Left out, as D101 settles: progress (an SSE notification is skipped),
//! output-schema validation, list-change subscriptions and the
//! input-required round trip, which needs client capabilities Rui does not
//! declare.
const std = @import("std");
const document = @import("document.zig");
const headers = @import("headers.zig");

pub const Body = enum { json, event_stream };

/// How a response's body is read, or the HTTP status that ended the
/// request. A JSON body on an error status still carries the server's
/// JSON-RPC error, so it is read.
pub const Reading = union(enum) {
    body: Body,
    failed: u16,
};

pub fn reading(status: u16, content_type: ?[]const u8) Reading {
    const body = bodyOf(content_type);
    if (status == 200) {
        if (body) |found| return .{ .body = found };
        return .{ .failed = status };
    }
    if (status >= 400 and body == .json) return .{ .body = .json };
    return .{ .failed = status };
}

/// The media type, ignoring parameters and case (RFC 9110 section 8.3.1).
fn bodyOf(content_type: ?[]const u8) ?Body {
    const value = content_type orelse return null;
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const media = std.mem.trim(u8, value[0..end], " \t");
    if (std.ascii.eqlIgnoreCase(media, "application/json")) return .json;
    if (std.ascii.eqlIgnoreCase(media, "text/event-stream")) return .event_stream;
    return null;
}

pub const Invalid = error{
    /// Not a JSON-RPC 2.0 response or notification.
    NotJsonRpc,
    /// A response to some other request.
    WrongId,
    /// A request from the server, which the transport forbids on a
    /// response stream.
    ServerRequest,
    /// A result whose shape is not the method's.
    InvalidResult,
    /// `resultType: "input_required"`: the server wants input this client
    /// declared it cannot give.
    InputRequired,
    UnknownResultType,
};

pub const RpcError = struct {
    code: i64,
    /// The message string's contents as written.
    message: []const u8,
    /// The `data` value, if any.
    data: ?[]const u8,
};

pub const Message = union(enum) {
    /// A notification about the request, such as progress: skipped.
    notification,
    /// The result object.
    result: []const u8,
    rpc_error: RpcError,
};

/// Reads one JSON-RPC message, which must answer request `id` or be a
/// notification.
pub fn readMessage(bytes: []const u8, id: u64) (document.Error || Invalid)!Message {
    try document.check(bytes);
    const object = std.mem.trim(u8, bytes, " \t\r\n");
    const version = document.member(object, "jsonrpc") orelse return error.NotJsonRpc;
    if (!std.mem.eql(u8, version, "\"2.0\"")) return error.NotJsonRpc;
    const method = document.member(object, "method");
    const found_id = document.member(object, "id");
    if (method) |name| {
        if (document.kind(name) != .string) return error.NotJsonRpc;
        return if (found_id == null) .notification else error.ServerRequest;
    }
    const answered = found_id orelse return error.NotJsonRpc;
    const result = document.member(object, "result");
    const failure = document.member(object, "error");
    if ((result == null) == (failure == null)) return error.NotJsonRpc;
    if (failure) |value| {
        // A server that could not read the request answers with a null id.
        if (!isId(answered, id) and document.kind(answered) != .null_value) return error.WrongId;
        return .{ .rpc_error = try rpcError(value) };
    }
    if (!isId(answered, id)) return error.WrongId;
    if (document.kind(result.?) != .object) return error.InvalidResult;
    return .{ .result = result.? };
}

fn isId(value: []const u8, id: u64) bool {
    var text: [20]u8 = undefined;
    return std.mem.eql(u8, value, std.fmt.bufPrint(&text, "{d}", .{id}) catch unreachable);
}

fn rpcError(value: []const u8) Invalid!RpcError {
    if (document.kind(value) != .object) return error.NotJsonRpc;
    const code = document.member(value, "code") orelse return error.NotJsonRpc;
    const message = document.member(value, "message") orelse return error.NotJsonRpc;
    if (document.kind(message) != .string) return error.NotJsonRpc;
    return .{
        .code = std.fmt.parseInt(i64, code, 10) catch return error.NotJsonRpc,
        .message = document.contents(message),
        .data = document.member(value, "data"),
    };
}

/// A result is complete when `resultType` is absent or "complete".
fn checkComplete(result: []const u8) Invalid!void {
    const value = document.member(result, "resultType") orelse return;
    if (document.kind(value) != .string) return error.InvalidResult;
    const name = document.contents(value);
    if (document.keyIs(name, "complete")) return;
    if (document.keyIs(name, "input_required")) return error.InputRequired;
    return error.UnknownResultType;
}

pub const ListPage = struct {
    /// The `tools` array; read it with `Tools`.
    tools: []const u8,
    /// The `nextCursor` string's contents as written, to send back as they
    /// are. `ttlMs` and `cacheScope` are read past (D206): tools are
    /// fetched at Host start (D110).
    next_cursor: ?[]const u8,
};

pub fn readList(result: []const u8) Invalid!ListPage {
    try checkComplete(result);
    const tools = document.member(result, "tools") orelse return error.InvalidResult;
    if (document.kind(tools) != .array) return error.InvalidResult;
    const cursor: ?[]const u8 = if (document.member(result, "nextCursor")) |value| switch (document.kind(value)) {
        .string => document.contents(value),
        .null_value => null,
        else => return error.InvalidResult,
    } else null;
    return .{ .tools = tools, .next_cursor = cursor };
}

pub const Tool = struct {
    /// String contents as written.
    name: []const u8,
    description: ?[]const u8,
    /// The checked `inputSchema` object.
    input_schema: []const u8,
    /// `annotations.readOnlyHint`, false when absent (D184).
    read_only: bool,
};

/// Why a listed tool is left out.
pub const LeftOut = union(enum) {
    /// No string `name`, or no object `inputSchema`.
    malformed,
    /// An invalid `x-mcp-header` annotation (D206).
    header: headers.Invalid,
};

pub const Listed = union(enum) {
    tool: Tool,
    left_out: struct { name: ?[]const u8, reason: LeftOut },
};

/// The tools of one page, in the server's order.
pub const Tools = struct {
    items: document.Items,

    pub fn init(page: ListPage) Tools {
        return .{ .items = document.Items.init(page.tools) };
    }

    pub fn next(self: *Tools) ?Listed {
        const item = self.items.next() orelse return null;
        if (document.kind(item) != .object) return .{ .left_out = .{ .name = null, .reason = .malformed } };
        const name: ?[]const u8 = if (document.member(item, "name")) |value|
            (if (document.kind(value) == .string) document.contents(value) else null)
        else
            null;
        const malformed: Listed = .{ .left_out = .{ .name = name, .reason = .malformed } };
        const schema = document.member(item, "inputSchema") orelse return malformed;
        if (name == null or document.kind(schema) != .object) return malformed;
        const description: ?[]const u8 = if (document.member(item, "description")) |value| switch (document.kind(value)) {
            .string => document.contents(value),
            .null_value => null,
            else => return malformed,
        } else null;
        if (headers.check(schema)) |invalid| return .{ .left_out = .{ .name = name, .reason = .{ .header = invalid } } };
        var read_only = false;
        if (document.member(item, "annotations")) |annotations| {
            if (document.kind(annotations) == .object) {
                if (document.member(annotations, "readOnlyHint")) |hint| read_only = document.kind(hint) == .true_value;
            }
        }
        return .{ .tool = .{ .name = name.?, .description = description, .input_schema = schema, .read_only = read_only } };
    }
};

pub const CallResult = struct {
    /// `isError: true`: the tool failed and the content says how (D144).
    is_error: bool,
    /// The `content` array of blocks; empty when absent.
    content: []const u8,
    /// `structuredContent`, any JSON value.
    structured: ?[]const u8,
};

pub fn readCall(result: []const u8) Invalid!CallResult {
    try checkComplete(result);
    const content = document.member(result, "content") orelse "[]";
    if (document.kind(content) != .array) return error.InvalidResult;
    const is_error = if (document.member(result, "isError")) |value| switch (document.kind(value)) {
        .true_value => true,
        .false_value => false,
        else => return error.InvalidResult,
    } else false;
    return .{ .is_error = is_error, .content = content, .structured = document.member(result, "structuredContent") };
}

test "a body is read by its media type, and an error status only as JSON" {
    try std.testing.expectEqual(Reading{ .body = .json }, reading(200, "application/json"));
    try std.testing.expectEqual(Reading{ .body = .json }, reading(200, "Application/JSON; charset=utf-8"));
    try std.testing.expectEqual(Reading{ .body = .event_stream }, reading(200, "text/event-stream"));
    try std.testing.expectEqual(Reading{ .failed = 200 }, reading(200, "text/html"));
    try std.testing.expectEqual(Reading{ .failed = 200 }, reading(200, null));
    try std.testing.expectEqual(Reading{ .body = .json }, reading(400, "application/json"));
    try std.testing.expectEqual(Reading{ .failed = 401 }, reading(401, "text/plain"));
    try std.testing.expectEqual(Reading{ .failed = 202 }, reading(202, null));
    try std.testing.expectEqual(Reading{ .failed = 500 }, reading(500, "text/event-stream"));
}

test "a message answers this request, or is a notification" {
    const result = try readMessage("{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"tools\":[]}}", 4);
    try std.testing.expectEqualStrings("{\"tools\":[]}", result.result);
    const progress = try readMessage("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":1}}", 4);
    try std.testing.expectEqual(Message.notification, progress);
    const failure = try readMessage("{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32602,\"message\":\"Unknown tool: x\",\"data\":{\"a\":1}}}", 4);
    try std.testing.expectEqual(@as(i64, -32602), failure.rpc_error.code);
    try std.testing.expectEqualStrings("Unknown tool: x", failure.rpc_error.message);
    try std.testing.expectEqualStrings("{\"a\":1}", failure.rpc_error.data.?);
    const unread = try readMessage("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}", 4);
    try std.testing.expectEqual(null, unread.rpc_error.data);

    const refused = [_]struct { []const u8, anyerror }{
        .{ "{\"id\":4,\"result\":{}}", error.NotJsonRpc },
        .{ "{\"jsonrpc\":\"1.0\",\"id\":4,\"result\":{}}", error.NotJsonRpc },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{}}", error.WrongId },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":\"4\",\"result\":{}}", error.WrongId },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":{}}", error.WrongId },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":1,\"message\":\"\"}}", error.WrongId },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"sampling/createMessage\"}", error.ServerRequest },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":4}", error.NotJsonRpc },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{},\"error\":{\"code\":1,\"message\":\"\"}}", error.NotJsonRpc },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":1.5,\"message\":\"\"}}", error.NotJsonRpc },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":1}}", error.NotJsonRpc },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":[]}", error.InvalidResult },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":", error.UnexpectedJsonEnd },
    };
    for (refused) |case| try std.testing.expectError(case[1], readMessage(case[0], 4));
}

test "a tools/list page lists its tools and leaves out invalid ones" {
    const message =
        \\{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","ttlMs":300000,"cacheScope":"public",
        \\ "nextCursor":"next\u002dpage","tools":[
        \\  {"name":"get_weather","title":"Weather","description":"Get the weather","inputSchema":{"type":"object","properties":{"city":{"type":"string"}}},
        \\   "annotations":{"readOnlyHint":true}},
        \\  {"name":"send","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":"yes"}},
        \\  {"name":"bad_header","inputSchema":{"type":"object","properties":{"a":{"type":"number","x-mcp-header":"A"}}}},
        \\  {"name":"no_schema"},
        \\  {"name":7,"inputSchema":{}},
        \\  "not a tool"
        \\]}}
    ;
    const page = try readList((try readMessage(message, 1)).result);
    try std.testing.expectEqualStrings("next\\u002dpage", page.next_cursor.?);
    var tools = Tools.init(page);
    const weather = tools.next().?.tool;
    try std.testing.expectEqualStrings("get_weather", weather.name);
    try std.testing.expectEqualStrings("Get the weather", weather.description.?);
    try std.testing.expectEqualStrings("{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}", weather.input_schema);
    try std.testing.expect(weather.read_only);
    const send = tools.next().?.tool;
    try std.testing.expectEqual(null, send.description);
    try std.testing.expect(!send.read_only);
    const bad = tools.next().?.left_out;
    try std.testing.expectEqualStrings("bad_header", bad.name.?);
    try std.testing.expectEqual(LeftOut{ .header = .not_primitive }, bad.reason);
    const no_schema = tools.next().?.left_out;
    try std.testing.expectEqualStrings("no_schema", no_schema.name.?);
    try std.testing.expectEqual(LeftOut.malformed, no_schema.reason);
    try std.testing.expectEqual(null, tools.next().?.left_out.name);
    try std.testing.expectEqual(null, tools.next().?.left_out.name);
    try std.testing.expectEqual(null, tools.next());

    const last = try readList("{\"tools\":[]}");
    try std.testing.expectEqual(null, last.next_cursor);
    try std.testing.expectError(error.InvalidResult, readList("{\"tools\":{}}"));
    try std.testing.expectError(error.InvalidResult, readList("{}"));
    try std.testing.expectError(error.InvalidResult, readList("{\"tools\":[],\"nextCursor\":3}"));
    try std.testing.expectError(error.UnknownResultType, readList("{\"resultType\":\"partial\",\"tools\":[]}"));
}

test "a tools/call result carries content, structured content and isError" {
    const done = try readCall("{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"72F\"}],\"structuredContent\":{\"t\":72},\"isError\":false}");
    try std.testing.expect(!done.is_error);
    try std.testing.expectEqualStrings("[{\"type\":\"text\",\"text\":\"72F\"}]", done.content);
    try std.testing.expectEqualStrings("{\"t\":72}", done.structured.?);
    const failed = try readCall("{\"content\":[{\"type\":\"text\",\"text\":\"no such city\"}],\"isError\":true}");
    try std.testing.expect(failed.is_error);
    try std.testing.expectEqual(null, failed.structured);
    const bare = try readCall("{\"structuredContent\":[1,2]}");
    try std.testing.expectEqualStrings("[]", bare.content);
    try std.testing.expectError(error.InputRequired, readCall("{\"resultType\":\"input_required\",\"inputRequests\":{}}"));
    try std.testing.expectError(error.UnknownResultType, readCall("{\"resultType\":\"later\"}"));
    try std.testing.expectError(error.InvalidResult, readCall("{\"content\":\"text\"}"));
    try std.testing.expectError(error.InvalidResult, readCall("{\"content\":[],\"isError\":1}"));
}
