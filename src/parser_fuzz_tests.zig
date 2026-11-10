//! Coverage-guided fuzz tests of the sans-I/O parsers that read bytes a peer
//! sent: an HTTP/1 response, an MCP event stream and reply, a JSON document,
//! a client request's metadata, MySQL server packets and an HTTPS proxy's
//! answer and settings. Cores may not name `std.testing.fuzz`, so their
//! harnesses live here, in test-logic, and reach them through the same
//! interfaces their shells use. (The Postgres decoder's is in
//! `store/wire/pg_tests.zig`: test-pg owns that module.)
//!
//! Each harness reads its input whole, a byte at a time and in reads the
//! fuzzer picks, and requires one outcome: a parser that keeps state between
//! reads must not depend on where a read happened to end. Each also checks
//! what its parser promises: slices that point into the input, an
//! independent reference where one exists, and no panic on any input.
//!
//! Without `--fuzz` each test runs only its seeds, as an ordinary unit test;
//! test-logic runs them. A live campaign needs a root that links no C:
//! `zig build fuzz-parsers -Dtest-filter='fuzz ' --fuzz=1K --summary all -j2`.
const std = @import("std");
const Http1Parser = @import("http1/Parser.zig");
const EventStream = @import("mcp/EventStream.zig");
const reply = @import("mcp/reply.zig");
const json = @import("codecs/json.zig");
const protocol = @import("protocol.zig");
const mysql = @import("store/wire/mysql.zig");
const proxy = @import("h2/proxy.zig");

const Smith = std.testing.Smith;

/// The longest input a harness reads; long enough to reach every state.
const max_input = 1024;

/// How a harness splits its input into reads.
const Split = union(enum) {
    whole,
    bytes,
    fuzzed: *Smith,

    fn next(self: Split, left: usize) usize {
        return switch (self) {
            .whole => left,
            .bytes => @min(left, 1),
            .fuzzed => |smith| @min(left, smith.valueRangeAtMost(u16, 1, 300)),
        };
    }
};

/// A seed as `Smith.slice` reads one, a little-endian length and the
/// bytes, then `values` as `Smith.value` reads them. Values read past the
/// seed take their least, so a seed's fuzzed reads are a byte each.
inline fn seed(comptime bytes: []const u8, comptime values: []const u64) []const u8 {
    comptime {
        var out: []const u8 = &std.mem.toBytes(std.mem.nativeToLittle(u32, bytes.len)) ++ bytes;
        for (values) |value| out = out ++ &std.mem.toBytes(std.mem.nativeToLittle(u64, value));
        return out;
    }
}

/// Runs `transcript` over the input whole, a byte at a time and in fuzzed
/// reads, and expects the same text from each.
fn expectSplitIndependent(
    comptime transcript: anytype,
    input: []const u8,
    context: anytype,
    smith: *Smith,
) !void {
    var whole: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer whole.deinit();
    try transcript(input, context, Split.whole, &whole.writer);
    for ([_]Split{ .bytes, .{ .fuzzed = smith } }) |split| {
        var other: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer other.deinit();
        try transcript(input, context, split, &other.writer);
        try std.testing.expectEqualStrings(whole.written(), other.written());
    }
}

/// Whether `inner` lies within `outer`.
fn within(inner: []const u8, outer: []const u8) bool {
    if (inner.len == 0) return true;
    const start = @intFromPtr(inner.ptr);
    const base = @intFromPtr(outer.ptr);
    return start >= base and start + inner.len <= base + outer.len;
}

// ------------------------------------------------------------ HTTP/1

test "fuzz http1 response parser" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) !void {
            var buffer: [max_input]u8 = undefined;
            const response = buffer[0..smith.slice(&buffer)];
            try expectSplitIndependent(http1Transcript, response, {}, smith);
        }
    }.one, .{ .corpus = &.{
        seed("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", &.{}),
        seed("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;x=y\r\nabc\r\n0\r\nT: v\r\n\r\n", &.{}),
        seed("HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n{}", &.{}),
        seed("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n", &.{}),
    } });
}

/// What the parser reads from `response`: the head, the body joined across
/// reads, and how the response ended, then the end of the connection.
fn http1Transcript(response: []const u8, _: void, split: Split, out: *std.Io.Writer) !void {
    var parser: Http1Parser = .{};
    var held_buffer: [max_input]u8 = undefined;
    var held: usize = 0;
    var fed: usize = 0;
    var body_length: u64 = 0;
    var content_length: ?u64 = null;
    while (true) {
        const n = split.next(response.len - fed);
        @memcpy(held_buffer[held..][0..n], response[fed..][0..n]);
        held += n;
        fed += n;
        var start: usize = 0;
        while (true) {
            const input = held_buffer[start..held];
            const step = parser.next(input) catch |err| return out.print("{t}\n", .{err});
            try std.testing.expect(step.used <= input.len);
            start += step.used;
            switch (step.event) {
                .more => if (step.used == 0) break,
                .head => |head| {
                    try std.testing.expect(within(head.fields, input));
                    try out.print("head {d}\n", .{head.status});
                    if (head.field("transfer-encoding") == null) {
                        if (head.field("content-length")) |value| content_length = std.fmt.parseInt(u64, value, 10) catch null;
                    }
                    if (head.status == 204 or head.status == 304) content_length = 0;
                },
                .body => |bytes| {
                    try std.testing.expect(bytes.len != 0 and within(bytes, input));
                    try out.writeAll(bytes);
                    body_length += bytes.len;
                },
                .end => {
                    if (content_length) |expected| try std.testing.expectEqual(expected, body_length);
                    return out.writeAll("\nend\n");
                },
            }
        }
        std.mem.copyForwards(u8, held_buffer[0 .. held - start], held_buffer[start..held]);
        held -= start;
        if (fed == response.len) break;
    }
    const event = parser.finish() catch |err| return out.print("\n{t}\n", .{err});
    try std.testing.expectEqual(Http1Parser.Event.end, event);
    try out.writeAll("\nclosed\n");
}

// ------------------------------------------------------------ MCP

test "fuzz mcp event stream against the WHATWG interpretation" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) !void {
            var buffer: [max_input]u8 = undefined;
            const body = buffer[0..smith.slice(&buffer)];
            const capacity = smith.valueRangeAtMost(u8, 1, 64);
            try expectSplitIndependent(eventTranscript, body, capacity, smith);
            var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer expected.deinit();
            try referenceEvents(body, capacity, &expected.writer);
            var found: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer found.deinit();
            try eventTranscript(body, capacity, .whole, &found.writer);
            try std.testing.expectEqualStrings(expected.written(), found.written());
        }
    }.one, .{ .corpus = &.{
        seed("event: message\r\nid: 7\r\ndata: one\r\ndata:two\r\n\r\ndata: three\n\n", &.{64}),
        seed(": keep-alive\n\nretry: 10\ndata\n\ndatum: x\ndata: z\r\r", &.{64}),
        seed("\xef\xbb\xbfdata: {\"jsonrpc\":\"2.0\"}\n\n", &.{64}),
        seed("\xef\xbbdata: x\n\n\xefdata: y\n\ndata: z\n\n", &.{64}),
    } });
}

/// Each event's data and a `|`, then the error that stopped the stream.
fn eventTranscript(body: []const u8, capacity: u8, split: Split, out: *std.Io.Writer) !void {
    var stream: EventStream = .{};
    var data_buffer: [64]u8 = undefined;
    var data: std.Io.Writer = .fixed(data_buffer[0..capacity]);
    var fed: usize = 0;
    while (fed < body.len) {
        var rest = body[fed..][0..split.next(body.len - fed)];
        fed += rest.len;
        while (true) {
            const step = stream.next(rest, &data) catch |err| return out.print("{t}", .{err});
            try std.testing.expect(step.used <= rest.len);
            rest = rest[step.used..];
            if (!step.dispatched) break;
            try out.print("{s}|", .{data.buffered()});
            data = .fixed(data_buffer[0..capacity]);
        }
    }
}

/// The event stream interpretation of the HTML standard over bytes: one
/// whole leading byte order mark is ignored, lines end at CRLF, CR or LF,
/// and a line the body ends inside, with its event, is dropped. Data past
/// `capacity` is refused as soon as it is read, line ended or not.
fn referenceEvents(body: []const u8, capacity: u8, out: *std.Io.Writer) !void {
    var rest = body;
    if (std.mem.startsWith(u8, rest, "\xef\xbb\xbf")) rest = rest[3..];
    var data_buffer: [64]u8 = undefined;
    var data: std.Io.Writer = .fixed(data_buffer[0..capacity]);
    var has_data = false;
    while (rest.len != 0) {
        const end = std.mem.indexOfAny(u8, rest, "\r\n");
        const line = rest[0 .. end orelse rest.len];
        if (end) |at| {
            rest = rest[at + 1 ..];
            if (line.ptr[line.len] == '\r' and rest.len != 0 and rest[0] == '\n') rest = rest[1..];
        } else rest = &.{};
        if (end != null and line.len == 0) {
            if (has_data) try out.print("{s}|", .{data.buffered()});
            data = .fixed(data_buffer[0..capacity]);
            has_data = false;
            continue;
        }
        if (line.len == 0 or line[0] == ':') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':');
        if (!std.mem.eql(u8, line[0 .. colon orelse line.len], "data")) continue;
        // An unended line's data is read up to the end of the body: a name
        // without its colon has none yet.
        if (end == null and colon == null) break;
        var value = if (colon) |at| line[at + 1 ..] else "";
        if (value.len != 0 and value[0] == ' ') value = value[1..];
        if (has_data) data.writeByte('\n') catch return out.writeAll("EventTooLarge");
        data.writeAll(value) catch return out.writeAll("EventTooLarge");
        has_data = true;
    }
    // An event the body ends inside is dropped.
}

test "fuzz mcp reply reading" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) !void {
            var buffer: [max_input]u8 = undefined;
            const bytes = buffer[0..smith.slice(&buffer)];
            const id = smith.valueRangeAtMost(u8, 0, 9);
            const message = reply.readMessage(bytes, id) catch return;
            // What is read as a message is JSON, as std.json reads it.
            try std.testing.expect(try std.json.validate(std.testing.allocator, bytes));
            switch (message) {
                .notification => {},
                .rpc_error => |failure| {
                    try std.testing.expect(within(failure.message, bytes));
                    if (failure.data) |data| try std.testing.expect(within(data, bytes));
                },
                .result => |result| {
                    try std.testing.expect(within(result, bytes));
                    if (reply.readList(result)) |page| {
                        try std.testing.expect(within(page.tools, bytes));
                        if (page.next_cursor) |cursor| try std.testing.expect(within(cursor, bytes));
                        var tools = reply.Tools.init(page);
                        while (tools.next()) |listed| switch (listed) {
                            .tool => |tool| {
                                try std.testing.expect(within(tool.name, bytes) and within(tool.input_schema, bytes));
                                if (tool.description) |text| try std.testing.expect(within(text, bytes));
                            },
                            .left_out => |left| if (left.name) |name| try std.testing.expect(within(name, bytes)),
                        };
                    } else |_| {}
                    if (reply.readCall(result)) |call| {
                        try std.testing.expect(within(call.content, bytes) or std.mem.eql(u8, call.content, "[]"));
                        if (call.structured) |value| try std.testing.expect(within(value, bytes));
                    } else |_| {}
                },
            }
        }
    }.one, .{ .corpus = &.{
        seed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"a\",\"inputSchema\":{\"type\":\"object\"},\"annotations\":{\"readOnlyHint\":true}},7],\"nextCursor\":\"c\"}}", &.{1}),
        seed("{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"x\"}],\"isError\":false,\"structuredContent\":{}}}", &.{}),
        seed("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"bad\",\"data\":[1]}}", &.{}),
        seed("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}", &.{}),
    } });
}

// ------------------------------------------------------------ JSON

test "fuzz json reader against std.json" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) !void {
            var buffer: [512]u8 = undefined;
            const document = buffer[0..smith.slice(&buffer)];
            var whole: JsonRecorder = .init();
            defer whole.deinit();
            var reader: json.Reader = undefined;
            const read = reader.read(document, &whole);

            var source: ByteSource = .{ .bytes = document };
            var streamed: JsonRecorder = .init();
            defer streamed.deinit();
            const read_source = reader.readSource(&source, &streamed);

            // Both readers read one grammar, and hear the same document.
            try std.testing.expectEqual(read, read_source);
            if (read) |_| try std.testing.expectEqualStrings(whole.text.written(), streamed.text.written()) else |err| {
                // std.json has no depth limit.
                if (err == error.JsonTooDeep) return;
            }
            const trimmed = std.mem.trimStart(u8, document, " \t\r\n");
            const expected = trimmed.len != 0 and trimmed[0] == '{' and try std.json.validate(std.testing.allocator, document);
            try std.testing.expectEqual(expected, if (read) |_| true else |_| false);
        }
    }.one, .{ .corpus = &.{
        seed("{\"a\":[1,-2,3.5e+2,0,true,false,null],\"b\":{\"c\":[[],{}]}}", &.{}),
        seed("{\"a\\u0062\":\"\\ud83d\\ude00\\n\\/\",\"\xc3\xa9\":\"\xe6\x97\xa5\"}", &.{}),
        seed("{\"a\":18446744073709551616,\"b\":-0.0E-0}", &.{}),
        seed("{\"a\":\"\\ud800\\u0041\"}", &.{}),
    } });
}

/// Every event a reader reports, as text.
const JsonRecorder = struct {
    text: std.Io.Writer.Allocating,

    fn init() JsonRecorder {
        return .{ .text = .init(std.testing.allocator) };
    }

    fn deinit(self: *JsonRecorder) void {
        self.text.deinit();
    }

    pub fn key(self: *JsonRecorder, reader: *const json.Reader, depth: u8) void {
        self.print("k{d}", .{depth});
        self.string(reader);
    }

    pub fn begin(self: *JsonRecorder, _: *const json.Reader, kind: json.Kind, depth: u8) void {
        self.print("<{t}{d} ", .{ kind, depth });
    }

    pub fn end(self: *JsonRecorder, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
        self.print(">{t}{d}", .{ kind, depth });
        switch (kind) {
            .string => self.string(reader),
            .number => self.print("={?d}/{t} ", .{ reader.integer, reader.digits }),
            .literal => self.print("={t} ", .{reader.literalValue()}),
            .object, .array => self.print(" ", .{}),
        }
    }

    fn string(self: *JsonRecorder, reader: *const json.Reader) void {
        const range = reader.string();
        self.print("[{d},{d}]{?s} ", .{ range.start, range.length, reader.text() });
    }

    fn print(self: *JsonRecorder, comptime format: []const u8, args: anytype) void {
        self.text.writer.print(format, args) catch @panic("OOM");
    }
};

/// The byte source `Reader.readSource` reads, over a slice.
const ByteSource = struct {
    bytes: []const u8,
    at: usize = 0,

    pub fn peek(self: *ByteSource) !?u8 {
        return if (self.at < self.bytes.len) self.bytes[self.at] else null;
    }

    pub fn take(self: *ByteSource) !u8 {
        defer self.at += 1;
        return self.bytes[self.at];
    }
};

// ------------------------------------------------------------ requests

/// Value-only custody: the metadata parser never touches content files.
const NoCustody = struct {
    pub const File = struct {};
    pub const Budget = struct {};
    pub const Io = void;
    pub fn release(_: ?File, _: ?Budget, _: u64, _: Io) void {}
};
const Requests = protocol.Requests(NoCustody);

test "fuzz protocol request metadata parser" {
    const v = "{\"version\":\"" ++ protocol.wire_version ++ "\",";
    const value = "{\"state\":\"value\",\"value\":\"\"}";
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) !void {
            var buffer: [max_input]u8 = undefined;
            const metadata = buffer[0..smith.slice(&buffer)];
            const route: ?protocol.Kind = if (smith.value(bool)) smith.value(protocol.Kind) else null;
            parseRequest(metadata, route) catch return;
            // The Ingress parses the metadata each time a token ends and
            // waits on NeedInput, so no part of an accepted request may be
            // accepted or refused on its own.
            for (0..metadata.len) |length| {
                try std.testing.expectError(error.NeedInput, parseRequest(metadata[0..length], route));
            }
        }
    }.one, .{ .corpus = &.{
        seed(v ++ "\"kind\":\"host_info\",\"store\":\"s\"}", &.{}),
        seed(v ++ "\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"sender\":null,\"sender_handle\":null,\"text\":" ++ value ++ "}", &.{}),
        seed(v ++ "\"kind\":\"configure\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"configuration\":{\"model\":{\"state\":\"value\",\"value\":\"m\"},\"instructions\":" ++ value ++ "}}", &.{}),
        seed(v ++ "\"kind\":\"inspect_session\",\"store\":\"s\",\"session\":\"peer\",\"failed_response\":\"body\",\"operation\":\"1\",\"attempt\":\"1\"}", &.{}),
        seed(v ++ "\"kind\":\"activity_content\",\"store\":\"s\",\"session\":\"peer\",\"position\":\"1\",\"ordinal\":\"0\"}", &.{}),
    } });
}

fn parseRequest(metadata: []const u8, route: ?protocol.Kind) !void {
    var source: protocol.MetadataSource = .{ .input = metadata };
    var parser: Requests.Parser = .{ .source = &source, .expected_kind = route, .captured = &.{ .{}, .{} } };
    var request: Requests.Request = undefined;
    try parser.parse(&request);
}

// ------------------------------------------------------------ MySQL

test "fuzz mysql client reading server packets" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) !void {
            var buffer: [max_input]u8 = undefined;
            const server = buffer[0..smith.slice(&buffer)];
            const start = smith.value(MysqlStart);
            try expectSplitIndependent(mysqlTranscript, server, start, smith);
        }
    }.one, .{
        .corpus = &.{
            // A query's result set: one column, the rows "ab" and NULL, then
            // its end.
            seed("\x01\x00\x00\x01\x01" ++
                "\x17\x00\x00\x02\x03def\x00\x00\x00\x01a\x00\x0c\xff\x00\x10\x00\x00\x00\xfd\x00\x00\x00\x00\x00" ++
                "\x03\x00\x00\x03\x02ab" ++ "\x01\x00\x00\x04\xfb" ++ "\x07\x00\x00\x05\xfe\x00\x00\x02\x00\x00\x00", &.{}),
            // An OK with more results, then an error.
            seed("\x07\x00\x00\x01\x00\x01\x00\x0a\x00\x00\x00" ++ "\x09\x00\x00\x02\xff\x28\x04#42000x", &.{}),
        },
    });
}

/// Where the MySQL harness starts: a handshake over one transport, or a
/// logged-in client whose query is out.
const MysqlStart = enum(u8) { query, tcp, tcp_tls, unix_socket };

/// Each event, a value's bytes joined to it, and the error that ended the
/// exchange. A logged-in client sends a query whenever it is ready.
fn mysqlTranscript(server: []const u8, start: MysqlStart, split: Split, out: *std.Io.Writer) !void {
    var client = try mysql.Client.init(.{
        .user = "rui",
        .password = "pw",
        .database = "rui",
        .transport = switch (start) {
            .query, .tcp => .tcp,
            .tcp_tls => .tcp_tls,
            .unix_socket => .unix_socket,
        },
    });
    if (start == .query) {
        client.state = .ready;
        _ = try client.query(1);
    }
    var held_buffer: [max_input]u8 = undefined;
    var held: usize = 0;
    var fed: usize = 0;
    var send: [mysql.send_buffer_min]u8 = undefined;
    var value_left: ?u32 = null;
    while (fed < server.len) {
        const n = split.next(server.len - fed);
        @memcpy(held_buffer[held..][0..n], server[fed..][0..n]);
        held += n;
        fed += n;
        var used: usize = 0;
        while (true) {
            if (client.state == .closed) return out.writeAll("closed\n");
            if (client.isReady()) {
                try out.writeAll("query\n");
                _ = try client.query(1);
            }
            const input = held_buffer[used..held];
            const step = client.read(input, &send) catch |err| return out.print("{t}\n", .{err});
            try std.testing.expect(step.consumed <= input.len);
            used += step.consumed;
            const event = step.event orelse if (step.consumed == 0) break else continue;
            if (event == .bytes) {
                try std.testing.expect(event.bytes.len != 0 and within(event.bytes, input));
                value_left.? = try std.math.sub(u32, value_left.?, @intCast(event.bytes.len));
                try out.writeAll(event.bytes);
                continue;
            }
            // A value's bytes add up to its length before the next event.
            if (value_left) |left| try std.testing.expectEqual(@as(u32, 0), left);
            value_left = if (event == .value) event.value else null;
            switch (event) {
                .err => |err| try std.testing.expect(within(err.message, input)),
                .column => |column| try std.testing.expect(within(column.name, input)),
                else => {},
            }
            try out.print("\n{f}\n", .{event});
        }
        std.mem.copyForwards(u8, held_buffer[0 .. held - used], held_buffer[used..held]);
        held -= used;
    }
}

// ------------------------------------------------------------ HTTPS proxy

test "fuzz https proxy answer and settings" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *Smith) !void {
            var buffer: [max_input]u8 = undefined;
            const bytes = buffer[0..smith.slice(&buffer)];
            try expectSplitIndependent(answerTranscript, bytes, {}, smith);

            // The same bytes as settings: a proxy URL, NO_PROXY and a host.
            const host_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
            const host = bytes[0..@min(host_end, proxy.max_host_bytes)];
            _ = proxy.isLoopback(host);
            _ = proxy.bypasses(bytes, host);
            if (proxy.Address.parse(host)) |address| try expectStdAddress(host, address);
            const parts = proxy.splitUrl(bytes) catch return;
            try std.testing.expect(within(parts.authority, bytes));
            const credentials: ?[]u8 = if (parts.user_info) |info| proxy.basicCredentials(std.testing.allocator, info) catch null else null;
            defer if (credentials) |value| std.testing.allocator.free(value);
            var request: [proxy.max_request_bytes]u8 = undefined;
            _ = proxy.connectRequest(&request, host, smith.value(u16), credentials);
        }
    }.one, .{ .corpus = &.{
        seed("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 Connection established\r\nProxy-Agent: x\r\n\r\n", &.{}),
        seed("::ffff:127.0.0.1\nhttp://us%3Aer:p%40ss@proxy.example:3128/", &.{}),
        seed("10.0.0.1\n10.0.0.0/8, .example.com,fd00::/8", &.{}),
    } });
}

/// The answer's outcome and where in the bytes it ended.
fn answerTranscript(bytes: []const u8, _: void, split: Split, out: *std.Io.Writer) !void {
    var answer: proxy.Answer = .{};
    var fed: usize = 0;
    while (fed < bytes.len) {
        const read = bytes[fed..][0..split.next(bytes.len - fed)];
        switch (answer.feed(read)) {
            .more => fed += read.len,
            .done => |done| {
                try std.testing.expect(done.used <= read.len);
                return out.print("{d} at {d}", .{ done.status, fed + done.used });
            },
            .malformed => return out.writeAll("malformed"),
        }
    }
    try out.writeAll("more");
}

/// An address the proxy core parses is one std parses to the same bytes.
fn expectStdAddress(text: []const u8, address: proxy.Address) !void {
    switch (address.len) {
        4 => {
            const parsed = try std.Io.net.Ip4Address.parse(text, 0);
            try std.testing.expectEqualSlices(u8, &parsed.bytes, address.bytes[0..4]);
        },
        16 => {
            const parsed = try std.Io.net.Ip6Address.parse(text, 0);
            try std.testing.expectEqualSlices(u8, &parsed.bytes, &address.bytes);
        },
        else => unreachable,
    }
}
