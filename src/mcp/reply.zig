const std = @import("std");
const document = @import("document.zig");
const json = @import("../codecs/json.zig");
const headers = @import("headers.zig");
const listen = @import("listen.zig");

pub const Body = enum { json, event_stream };

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

fn bodyOf(content_type: ?[]const u8) ?Body {
    const value = content_type orelse return null;
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const media = std.mem.trim(u8, value[0..end], " \t");
    if (std.ascii.eqlIgnoreCase(media, "application/json")) return .json;
    if (std.ascii.eqlIgnoreCase(media, "text/event-stream")) return .event_stream;
    return null;
}

pub const Invalid = error{
    NotJsonRpc,
    WrongId,
    ServerRequest,
    InvalidResult,
    InputRequired,
    UnknownResultType,
};

pub const RpcError = struct {
    code: i64,
    message: []const u8,
    data: ?[]const u8,
};

pub const CallOutcome = union(enum) {
    waiting,
    result: CallResult,
    server_error: RpcError,
    refused: struct { status: u16, body: []const u8 },
};

pub const Message = union(enum) {
    notification,
    result: []const u8,
    rpc_error: RpcError,
};

pub fn readMessage(bytes: []const u8, id: u64) (document.Error || Invalid)!Message {
    try document.check(bytes);
    const object: Object = .whole(bytes);
    return readEnvelope(object, .wholeMember(object, .@"error"), id);
}

const subscription_key = "io.modelcontextprotocol/subscriptionId";
const acknowledged_method = "notifications/subscriptions/acknowledged";
const tools_changed_method = "notifications/tools/list_changed";

/// Reads one event of the `subscriptions/listen` stream that answers request `id`.
/// A final result is the graceful end; an error answering `id` (or null) is a refusal.
pub fn readNotice(bytes: []const u8, id: u64) (document.Error || Invalid)!listen.Event {
    try document.check(bytes);
    const object: Object = .whole(bytes);
    const version = object.get(.jsonrpc) orelse return error.NotJsonRpc;
    if (!version.stringIs("2.0")) return error.NotJsonRpc;
    if (object.get(.method)) |method| {
        if (!method.complete or method.kind() != .string) return error.NotJsonRpc;
        if (object.get(.id) != null) return error.ServerRequest;
        return notice(bytes, method);
    }
    const message = try readEnvelope(object, .wholeMember(object, .@"error"), id);
    return switch (message) {
        .result => |result| .{ .ended = try subscriptionIn(result) },
        .rpc_error => |failure| .{ .refused = .{ .status = null, .rpc_code = failure.code } },
        .notification => error.NotJsonRpc,
    };
}

fn notice(bytes: []const u8, method: Value) Invalid!listen.Event {
    if (method.stringIs(acknowledged_method)) {
        const params = try paramsOf(bytes);
        const filter = if (params) |found| document.member(found, "notifications") else null;
        return .{ .acknowledged = .{ .subscription = try subscriptionIn(params), .tools = honoursTools(filter) } };
    }
    if (method.stringIs(tools_changed_method)) return .{ .tools_changed = try subscriptionIn(try paramsOf(bytes)) };
    return .ignored;
}

fn paramsOf(bytes: []const u8) Invalid!?[]const u8 {
    const value = document.member(bytes, "params") orelse return null;
    if (document.kind(value) != .object) return error.InvalidResult;
    return value;
}

/// The subscriptionId in an object's `_meta`, or null when it names none.
fn subscriptionIn(object: ?[]const u8) Invalid!?u64 {
    const found = object orelse return null;
    const meta = document.member(found, "_meta") orelse return null;
    if (document.kind(meta) != .object) return error.InvalidResult;
    const value = document.member(meta, subscription_key) orelse return null;
    if (document.kind(value) != .number) return error.InvalidResult;
    return std.fmt.parseInt(u64, value, 10) catch error.InvalidResult;
}

/// An acknowledgment's filter keeps `toolsListChanged` only when it is `true`.
fn honoursTools(filter: ?[]const u8) bool {
    const found = filter orelse return false;
    if (document.kind(found) != .object) return false;
    const value = document.member(found, "toolsListChanged") orelse return false;
    return document.kind(value) == .true_value;
}

const Field = enum { jsonrpc, id, method, result, @"error", resultType, content, isError, structuredContent, code, message, data };
const Value = struct {
    bytes: []const u8,
    complete: bool,

    fn kind(self: Value) document.Kind {
        return document.kind(self.bytes);
    }

    fn stringIs(self: Value, expected: []const u8) bool {
        return self.complete and self.kind() == .string and document.keyIs(document.contents(self.bytes), expected);
    }
};
const Object = struct {
    checked: ?[]const u8 = null,
    fields: [std.enums.values(Field).len]?Value = @splat(null),
    closed: bool = false,

    fn whole(bytes: []const u8) Object {
        return .{ .checked = std.mem.trim(u8, bytes, " \t\r\n"), .closed = true };
    }

    fn wholeMember(parent: Object, field: Field) Object {
        const value = parent.get(field) orelse return .{};
        return if (value.kind() == .object) .whole(value.bytes) else .{};
    }

    fn get(self: *const Object, field: Field) ?Value {
        if (self.checked) |bytes| {
            const value = document.member(bytes, @tagName(field)) orelse return null;
            return .{ .bytes = value, .complete = true };
        }
        return self.fields[@backingInt(field)];
    }

    fn defaulted(self: *const Object, field: Field) Invalid!?Value {
        const value = self.get(field);
        if (value == null and !self.closed) return error.InvalidResult;
        return value;
    }
};

fn readEnvelope(object: Object, failure: Object, id: u64) Invalid!Message {
    const version = object.get(.jsonrpc) orelse return error.NotJsonRpc;
    if (!version.stringIs("2.0")) return error.NotJsonRpc;
    const found_id = object.get(.id);
    if (object.get(.method)) |method| {
        if (!method.complete or method.kind() != .string) return error.NotJsonRpc;
        return if (found_id == null) .notification else error.ServerRequest;
    }
    const answered = found_id orelse return error.NotJsonRpc;
    const found = object.get(.result);
    const err = object.get(.@"error");
    if ((found == null) == (err == null)) return error.NotJsonRpc;
    if (err) |value| {
        if (!isId(answered, id) and !(answered.complete and answered.kind() == .null_value)) return error.WrongId;
        if (value.kind() != .object) return error.NotJsonRpc;
        return .{ .rpc_error = try rpcError(failure) };
    }
    if (!isId(answered, id)) return error.WrongId;
    if (found.?.kind() != .object) return error.InvalidResult;
    return .{ .result = found.?.bytes };
}

fn isId(value: Value, id: u64) bool {
    var text: [20]u8 = undefined;
    return value.complete and std.mem.eql(u8, value.bytes, std.fmt.bufPrint(&text, "{d}", .{id}) catch unreachable);
}

fn rpcError(object: Object) Invalid!RpcError {
    const code = object.get(.code) orelse return error.NotJsonRpc;
    const text = object.get(.message) orelse return error.NotJsonRpc;
    if (!code.complete or !text.complete or text.kind() != .string) return error.NotJsonRpc;
    return .{
        .code = std.fmt.parseInt(i64, code.bytes, 10) catch return error.NotJsonRpc,
        .message = document.contents(text.bytes),
        .data = if (object.get(.data)) |data| data.bytes else null,
    };
}

fn checkComplete(object: Object) Invalid!void {
    const value = (try object.defaulted(.resultType)) orelse return;
    if (!value.complete or value.kind() != .string) return error.InvalidResult;
    if (value.stringIs("complete")) return;
    if (value.stringIs("input_required")) return error.InputRequired;
    return error.UnknownResultType;
}

pub const Code = enum { succeeded, failed, indeterminate };
pub const Extent = enum { complete, cut };
pub const Answer = struct {
    bytes: []const u8,
    id: u64,
    status: u16 = 200,
    format: ?Body = .json,
    extent: Extent = .complete,
};

pub fn classify(outcome: CallOutcome) Code {
    return switch (outcome) {
        .waiting => unreachable,
        .result => |result| if (result.is_error) .failed else .succeeded,
        .server_error => .failed,
        .refused => |failure| if (failure.status >= 400 and failure.status < 500) .failed else .indeterminate,
    };
}

pub fn judgeCall(answer: Answer) Code {
    return classify(callAnswer(answer));
}

pub fn readCallAnswer(answer: Answer) CallOutcome {
    std.debug.assert(answer.extent == .complete);
    return callAnswer(answer);
}

fn callAnswer(answer: Answer) CallOutcome {
    const refused: CallOutcome = .{ .refused = .{ .status = answer.status, .body = answer.bytes } };
    if (answer.format == null) return refused;
    var fields: AnswerFields = .{ .bytes = answer.bytes };
    var reader: json.Reader = undefined;
    reader.read(answer.bytes, &fields) catch |err| {
        if (err != error.UnexpectedJsonEnd or answer.extent != .cut) return refused;
    };
    return switch (readEnvelope(fields.envelope, fields.failure, answer.id) catch return refused) {
        .notification => refused,
        .rpc_error => |failure| .{ .server_error = failure },
        .result => .{ .result = callResult(fields.result) catch return refused },
    };
}

const AnswerFields = struct {
    bytes: []const u8,
    envelope: Object = .{},
    result: Object = .{},
    failure: Object = .{},
    active: [2]?Field = @splat(null),
    starts: [2]usize = @splat(0),

    fn object(self: *AnswerFields, depth: u8) ?*Object {
        if (depth == 1) return &self.envelope;
        if (depth != 2) return null;
        return switch (self.active[0] orelse return null) {
            .result => &self.result,
            .@"error" => &self.failure,
            else => null,
        };
    }

    pub fn key(self: *AnswerFields, reader: *const json.Reader, depth: u8) void {
        const target = self.object(depth) orelse return;
        const field = std.meta.stringToEnum(Field, reader.text() orelse "");
        self.active[depth - 1] = if (field != null and target.get(field.?) == null) field else null;
    }

    pub fn begin(self: *AnswerFields, reader: *const json.Reader, _: json.Kind, depth: u8) void {
        const target = self.object(depth) orelse return;
        const field = self.active[depth - 1] orelse return;
        const start: usize = @intCast(reader.offset);
        self.starts[depth - 1] = start;
        target.fields[@backingInt(field)] = .{ .bytes = self.bytes[start..], .complete = false };
    }

    pub fn end(self: *AnswerFields, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
        if (kind == .object) {
            if (depth == 0) self.envelope.closed = true;
            if (depth == 1) if (self.object(2)) |child| {
                child.closed = true;
            };
        }
        const target = self.object(depth) orelse return;
        const field = self.active[depth - 1] orelse return;
        const end_at: usize = @intCast(reader.offset + @as(u64, if (kind == .number) 0 else 1));
        target.fields[@backingInt(field)] = .{ .bytes = self.bytes[self.starts[depth - 1]..end_at], .complete = true };
    }
};

pub const ListPage = struct {
    tools: []const u8,
    next_cursor: ?[]const u8,
    /// The page's `ttlMs` when it is a positive whole number of milliseconds; null otherwise.
    ttl_ms: ?u64,
};

pub fn readList(result: []const u8) Invalid!ListPage {
    try checkComplete(.whole(result));
    const tools = document.member(result, "tools") orelse return error.InvalidResult;
    if (document.kind(tools) != .array) return error.InvalidResult;
    const cursor: ?[]const u8 = if (document.member(result, "nextCursor")) |value| switch (document.kind(value)) {
        .string => document.contents(value),
        .null_value => null,
        else => return error.InvalidResult,
    } else null;
    const ttl: ?u64 = if (document.member(result, "ttlMs")) |value| positiveTtl(value) else null;
    return .{ .tools = tools, .next_cursor = cursor, .ttl_ms = ttl };
}

/// A `ttlMs` value that names a positive whole number of milliseconds; absent, zero, negative,
/// fractional, non-numeric or beyond u64 values name none.
fn positiveTtl(value: []const u8) ?u64 {
    if (document.kind(value) != .number) return null;
    const ms = std.fmt.parseInt(u64, value, 10) catch return null;
    return if (ms == 0) null else ms;
}

pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8,
    input_schema: []const u8,
};

pub const LeftOut = union(enum) {
    malformed,
    header: headers.Invalid,
};

pub const Listed = union(enum) {
    tool: Tool,
    left_out: struct { name: ?[]const u8, reason: LeftOut },
};

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
        return .{ .tool = .{ .name = name.?, .description = description, .input_schema = schema } };
    }
};

pub const CallResult = struct {
    is_error: bool,
    content: []const u8,
    structured: ?[]const u8,
};

pub fn readCall(result: []const u8) Invalid!CallResult {
    return callResult(.whole(result));
}

fn callResult(object: Object) Invalid!CallResult {
    try checkComplete(object);
    const content = try object.defaulted(.content);
    if (content) |value| if (value.kind() != .array) {
        return error.InvalidResult;
    };
    const flag = try object.defaulted(.isError);
    const is_error = if (flag) |value| value: {
        if (!value.complete) return error.InvalidResult;
        break :value switch (value.kind()) {
            .true_value => true,
            .false_value => false,
            else => return error.InvalidResult,
        };
    } else false;
    return .{
        .is_error = is_error,
        .content = if (content) |value| value.bytes else "[]",
        .structured = if (object.get(.structuredContent)) |value| value.bytes else null,
    };
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
    const escaped = try readMessage("{\"jsonrpc\":\"2\\u002e0\",\"id\":4,\"result\":{}}", 4);
    try std.testing.expectEqualStrings("{}", escaped.result);
    const unread = try readMessage("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}", 4);
    try std.testing.expectEqual(null, unread.rpc_error.data);

    const refused = [_]struct { []const u8, anyerror }{
        .{ "{\"id\":4,\"result\":{}}", error.NotJsonRpc },
        .{ "{\"jsonrpc\":\"1.0\",\"id\":4,\"result\":{}}", error.NotJsonRpc },
        .{ "{\"jsonrpc\":2.0,\"id\":4,\"result\":{}}", error.NotJsonRpc },
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

test "EXR-76 a listen stream event reads as its domain event, and a malformed one is refused" {
    const cases = [_]struct { []const u8, listen.Event }{
        .{ "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1},\"notifications\":{\"toolsListChanged\":true,\"resourceSubscriptions\":[\"file:///a\"]}}}", .{ .acknowledged = .{ .subscription = 1, .tools = true } } },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1},\"notifications\":{\"resourceSubscriptions\":[]}}}", .{ .acknowledged = .{ .subscription = 1, .tools = false } } },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1},\"notifications\":{\"toolsListChanged\":false}}}", .{ .acknowledged = .{ .subscription = 1, .tools = false } } },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\"}", .{ .acknowledged = .{ .subscription = null, .tools = false } } },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":9},\"notifications\":{\"toolsListChanged\":true}}}", .{ .acknowledged = .{ .subscription = 9, .tools = true } } },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}", .{ .tools_changed = null } },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}}", .{ .tools_changed = 1 } },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":9}}}", .{ .tools_changed = 9 } },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":1}}", .ignored },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":\"not read\"}", .ignored },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}}", .{ .ended = 1 } },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\"}}", .{ .ended = null } },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}", .{ .refused = .{ .status = null, .rpc_code = -32601 } } },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}", .{ .refused = .{ .status = null, .rpc_code = -32700 } } },
    };
    for (cases) |case| try std.testing.expectEqualDeep(case[1], try readNotice(case[0], 1));

    const refused = [_]struct { []const u8, anyerror }{
        .{ "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}", error.WrongId },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sampling/createMessage\"}", error.ServerRequest },
        .{ "{\"id\":1,\"method\":\"notifications/progress\"}", error.NotJsonRpc },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":5}", error.NotJsonRpc },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[]}", error.InvalidResult },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":[]}", error.InvalidResult },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"x\"}}}", error.InvalidResult },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1.5}}}", error.InvalidResult },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"", error.UnexpectedJsonEnd },
    };
    for (refused) |case| try std.testing.expectError(case[1], readNotice(case[0], 1));
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
    try std.testing.expectEqual(@as(?u64, 300_000), page.ttl_ms);
    try std.testing.expectEqualStrings("next\\u002dpage", page.next_cursor.?);
    var tools = Tools.init(page);
    const weather = tools.next().?.tool;
    try std.testing.expectEqualStrings("get_weather", weather.name);
    try std.testing.expectEqualStrings("Get the weather", weather.description.?);
    try std.testing.expectEqualStrings("{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}", weather.input_schema);
    const send = tools.next().?.tool;
    try std.testing.expectEqual(null, send.description);
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

test "EXR-70 a tools/list page's ttlMs counts only as a positive whole number of milliseconds" {
    const cases = [_]struct { []const u8, ?u64 }{
        .{ "{\"tools\":[]}", null },
        .{ "{\"ttlMs\":-1,\"tools\":[]}", null },
        .{ "{\"ttlMs\":0,\"tools\":[]}", null },
        .{ "{\"ttlMs\":1.5,\"tools\":[]}", null },
        .{ "{\"ttlMs\":1e3,\"tools\":[]}", null },
        .{ "{\"ttlMs\":\"300000\",\"tools\":[]}", null },
        .{ "{\"ttlMs\":null,\"tools\":[]}", null },
        .{ "{\"ttlMs\":18446744073709551616,\"tools\":[]}", null },
        .{ "{\"ttlMs\":1,\"tools\":[]}", 1 },
        .{ "{\"ttlMs\":18446744073709551615,\"tools\":[]}", std.math.maxInt(u64) },
    };
    for (cases) |case| try std.testing.expectEqual(case[1], (try readList(case[0])).ttl_ms);
}

test "a tool lists the same with or without a readOnlyHint" {
    const hinted = try readList("{\"tools\":[{\"name\":\"get_weather\",\"description\":\"Get the weather\",\"inputSchema\":{\"type\":\"object\"},\"annotations\":{\"readOnlyHint\":true}}]}");
    const plain = try readList("{\"tools\":[{\"name\":\"get_weather\",\"description\":\"Get the weather\",\"inputSchema\":{\"type\":\"object\"}}]}");
    var hinted_tools = Tools.init(hinted);
    var plain_tools = Tools.init(plain);
    const a = hinted_tools.next().?.tool;
    const b = plain_tools.next().?.tool;
    try std.testing.expectEqualStrings(b.name, a.name);
    try std.testing.expectEqualStrings(b.description.?, a.description.?);
    try std.testing.expectEqualStrings(b.input_schema, a.input_schema);
    try std.testing.expectEqualDeep(b, a);
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
