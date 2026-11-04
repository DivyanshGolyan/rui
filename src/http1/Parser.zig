//! An HTTP/1.1 response read as it arrives, as values: bytes in, one event
//! out. It owns no buffer. The caller keeps unread bytes and passes them
//! again with whatever arrived after them, so a response head is parsed
//! once it is whole in the caller's buffer and every body slice it returns
//! points into that buffer.
//!
//! It reads one response to a request that is not HEAD: interim 1xx heads
//! are skipped, the body is framed by `Transfer-Encoding: chunked`, by
//! `Content-Length`, or by the end of the connection, and 204 and 304 have
//! none. A response whose framing is ambiguous is refused, as RFC 9112
//! section 6.3 asks of a client that cannot trust it.
const std = @import("std");

const Parser = @This();

/// The longest head, and the longest chunk-size or trailer line, the parser
/// waits for. Node's own limit on a head it sends is 16 KiB.
pub const max_head_bytes = 16 * 1024;
pub const max_line_bytes = 4 * 1024;

pub const Error = error{
    /// The status line or a field line is not RFC 9112 syntax.
    InvalidHead,
    HeadTooLarge,
    /// Content-Length and Transfer-Encoding disagree, a length is not
    /// digits, or a coding other than a lone `chunked` is named.
    InvalidFraming,
    InvalidChunk,
    LineTooLarge,
    /// A 101 Switching Protocols, which no request of this client asks for.
    UnexpectedUpgrade,
    /// The connection ended before the framing said the body did.
    TruncatedResponse,
};

pub const Head = struct {
    status: u16,
    /// The field lines, each ended by CRLF, without the status line and the
    /// final empty line. Borrowed from the bytes passed to `next`.
    fields: []const u8,

    /// The value of the first field named `name`, ignoring case, without
    /// the whitespace around it.
    pub fn field(self: Head, name: []const u8) ?[]const u8 {
        var lines = FieldLines{ .rest = self.fields };
        while (lines.next()) |line| {
            if (std.ascii.eqlIgnoreCase(line.name, name)) return line.value;
        }
        return null;
    }
};

pub const Event = union(enum) {
    /// The bytes passed hold no complete event; pass them again with more.
    more,
    head: Head,
    /// Body bytes, borrowed from the bytes passed to `next`.
    body: []const u8,
    /// The response is complete. Bytes after it are not read.
    end,
};

pub const Step = struct {
    /// How many leading bytes of the input the caller may drop.
    used: usize,
    event: Event,
};

const State = union(enum) {
    head,
    /// Body bytes left under Content-Length.
    length: u64,
    chunk_size,
    /// Data bytes left in the current chunk.
    chunk_data: u64,
    chunk_end,
    trailers,
    until_close,
    done,
};

state: State = .head,
/// How far into the pending head the search for its end has already
/// looked, so a head that arrives a byte at a time is scanned once.
scanned: usize = 0,

/// Reads from `input`, which begins at the first byte this parser has not
/// yet used.
pub fn next(self: *Parser, input: []const u8) Error!Step {
    while (true) switch (self.state) {
        .head => {
            const from = self.scanned -| 3;
            const found = std.mem.indexOfPos(u8, input, from, "\r\n\r\n") orelse {
                if (input.len >= max_head_bytes) return error.HeadTooLarge;
                self.scanned = input.len;
                return .{ .used = 0, .event = .more };
            };
            const length = found + 4;
            if (length > max_head_bytes) return error.HeadTooLarge;
            self.scanned = 0;
            const head = try parseHead(input[0..length]);
            if (head.status == 101) return error.UnexpectedUpgrade;
            if (head.status < 200) {
                // An interim response; the final one follows it.
                return .{ .used = length, .event = .more };
            }
            self.state = try framing(head);
            return .{ .used = length, .event = .{ .head = head } };
        },
        .length => |left| {
            if (left == 0) {
                self.state = .done;
                continue;
            }
            if (input.len == 0) return .{ .used = 0, .event = .more };
            const take: usize = @intCast(@min(left, input.len));
            self.state = .{ .length = left - take };
            return .{ .used = take, .event = .{ .body = input[0..take] } };
        },
        .chunk_size => {
            const line = (try takeLine(input)) orelse return .{ .used = 0, .event = .more };
            const size = try chunkSize(line.text);
            self.state = if (size == 0) .trailers else .{ .chunk_data = size };
            return .{ .used = line.used, .event = .more };
        },
        .chunk_data => |left| {
            if (input.len == 0) return .{ .used = 0, .event = .more };
            const take: usize = @intCast(@min(left, input.len));
            self.state = if (take == left) .chunk_end else .{ .chunk_data = left - take };
            return .{ .used = take, .event = .{ .body = input[0..take] } };
        },
        .chunk_end => {
            if (input.len < 2) return .{ .used = 0, .event = .more };
            if (!std.mem.eql(u8, input[0..2], "\r\n")) return error.InvalidChunk;
            self.state = .chunk_size;
            return .{ .used = 2, .event = .more };
        },
        .trailers => {
            const line = (try takeLine(input)) orelse return .{ .used = 0, .event = .more };
            if (line.text.len == 0) {
                self.state = .done;
                return .{ .used = line.used, .event = .end };
            }
            // A trailer field carries nothing this client reads; it is
            // still checked, since a malformed one means misframing.
            _ = try fieldLine(line.text);
            return .{ .used = line.used, .event = .more };
        },
        .until_close => {
            if (input.len == 0) return .{ .used = 0, .event = .more };
            return .{ .used = input.len, .event = .{ .body = input } };
        },
        .done => return .{ .used = 0, .event = .end },
    };
}

/// The connection ended, after every byte it carried went through `next`.
/// Returns `.end` when that is where the response ends.
pub fn finish(self: *Parser) Error!Event {
    switch (self.state) {
        .until_close, .done => {
            self.state = .done;
            return .end;
        },
        else => return error.TruncatedResponse,
    }
}

fn parseHead(bytes: []const u8) Error!Head {
    const status_end = std.mem.indexOf(u8, bytes, "\r\n").?;
    const status = try statusLine(bytes[0..status_end]);
    const fields = bytes[status_end + 2 .. bytes.len - 2];
    var lines = FieldLines{ .rest = fields };
    while (try lines.nextChecked()) |_| {}
    return .{ .status = status, .fields = fields };
}

/// `HTTP/1.1 SP 3DIGIT SP reason-phrase`, where the reason may be empty.
/// A 1.0 server is refused: its framing rules differ.
fn statusLine(line: []const u8) Error!u16 {
    const prefix = "HTTP/1.1 ";
    if (line.len < prefix.len + 4 or !std.mem.startsWith(u8, line, prefix)) return error.InvalidHead;
    const code = line[prefix.len..][0..3];
    if (line[prefix.len + 3] != ' ') return error.InvalidHead;
    var status: u16 = 0;
    for (code) |digit| {
        if (!std.ascii.isDigit(digit)) return error.InvalidHead;
        status = status * 10 + (digit - '0');
    }
    if (status < 100) return error.InvalidHead;
    for (line[prefix.len + 4 ..]) |byte| {
        if (byte != '\t' and (byte < ' ' or byte == 0x7f)) return error.InvalidHead;
    }
    return status;
}

const FieldLine = struct { name: []const u8, value: []const u8 };

/// Walks field lines already checked by `parseHead`.
const FieldLines = struct {
    rest: []const u8,

    fn next(self: *FieldLines) ?FieldLine {
        return self.nextChecked() catch unreachable;
    }

    fn nextChecked(self: *FieldLines) Error!?FieldLine {
        if (self.rest.len == 0) return null;
        const end = std.mem.indexOf(u8, self.rest, "\r\n") orelse return error.InvalidHead;
        const line = self.rest[0..end];
        self.rest = self.rest[end + 2 ..];
        return try fieldLine(line);
    }
};

/// `field-name ":" OWS field-value OWS`. Obsolete line folding and bare CR
/// or LF are refused (RFC 9112 section 5.2).
fn fieldLine(line: []const u8) Error!FieldLine {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHead;
    const name = line[0..colon];
    if (!isToken(name)) return error.InvalidHead;
    const raw = line[colon + 1 ..];
    for (raw) |byte| {
        if (byte != '\t' and (byte < ' ' or byte == 0x7f)) return error.InvalidHead;
    }
    return .{ .name = name, .value = std.mem.trim(u8, raw, " \t") };
}

/// RFC 9110 `token`: one or more `tchar`.
pub fn isToken(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return false;
    }
    return true;
}

/// The body state a final response's head selects (RFC 9112 section 6.3).
fn framing(head: Head) Error!State {
    var length: ?u64 = null;
    var chunked = false;
    var lines = FieldLines{ .rest = head.fields };
    while (lines.next()) |line| {
        if (std.ascii.eqlIgnoreCase(line.name, "Transfer-Encoding")) {
            // Only a lone `chunked` is accepted: any other coding would
            // need decoding this client does not do, and two
            // Transfer-Encoding lines are a list whose last item must be
            // chunked, which a lone `chunked` already is only once.
            if (chunked or !std.ascii.eqlIgnoreCase(line.value, "chunked")) return error.InvalidFraming;
            chunked = true;
        } else if (std.ascii.eqlIgnoreCase(line.name, "Content-Length")) {
            const value = try contentLength(line.value);
            if (length) |earlier| {
                if (earlier != value) return error.InvalidFraming;
            }
            length = value;
        }
    }
    if (chunked and length != null) return error.InvalidFraming;
    if (head.status == 204 or head.status == 304) {
        if (chunked or (length orelse 0) != 0) return error.InvalidFraming;
        return .done;
    }
    if (chunked) return .chunk_size;
    if (length) |value| return .{ .length = value };
    return .until_close;
}

fn contentLength(value: []const u8) Error!u64 {
    if (value.len == 0) return error.InvalidFraming;
    var length: u64 = 0;
    for (value) |digit| {
        if (!std.ascii.isDigit(digit)) return error.InvalidFraming;
        length = std.math.mul(u64, length, 10) catch return error.InvalidFraming;
        length = std.math.add(u64, length, digit - '0') catch return error.InvalidFraming;
    }
    return length;
}

const Line = struct { text: []const u8, used: usize };

/// The CRLF-ended line at the start of `input`, or null while it is still
/// arriving.
fn takeLine(input: []const u8) Error!?Line {
    const window = input[0..@min(input.len, max_line_bytes + 2)];
    const end = std.mem.indexOf(u8, window, "\r\n") orelse {
        if (window.len == max_line_bytes + 2) return error.LineTooLarge;
        return null;
    };
    return .{ .text = input[0..end], .used = end + 2 };
}

/// `chunk-size [ chunk-ext ]`: hex digits, then extensions this client
/// ignores, each still required to be printable.
fn chunkSize(line: []const u8) Error!u64 {
    var size: u64 = 0;
    var digits: usize = 0;
    while (digits < line.len) : (digits += 1) {
        const value = std.fmt.charToDigit(line[digits], 16) catch break;
        size = std.math.mul(u64, size, 16) catch return error.InvalidChunk;
        size += value;
    }
    if (digits == 0) return error.InvalidChunk;
    const rest = line[digits..];
    if (rest.len != 0) {
        const trimmed = std.mem.trimStart(u8, rest, " \t");
        if (trimmed.len == 0 or trimmed[0] != ';') return error.InvalidChunk;
        for (trimmed) |byte| {
            if (byte != '\t' and (byte < ' ' or byte == 0x7f)) return error.InvalidChunk;
        }
    }
    return size;
}

// Tests drive whole responses through every way of splitting them, so the
// outcome cannot depend on where a read happened to end.

const Collected = struct {
    status: u16 = 0,
    content_type: [64]u8 = undefined,
    content_type_len: usize = 0,
    body: [1024]u8 = undefined,
    body_len: usize = 0,
    ended: bool = false,
};

/// Feeds `response` as two reads split at `split`, keeping unused bytes as
/// a caller's buffer would, then ends the connection.
fn collect(response: []const u8, split: usize, out: *Collected) Error!void {
    var parser: Parser = .{};
    var buffer: [2048]u8 = undefined;
    var held: usize = 0;
    const reads = [_][]const u8{ response[0..split], response[split..] };
    for (reads) |read| {
        @memcpy(buffer[held..][0..read.len], read);
        held += read.len;
        var start: usize = 0;
        while (true) {
            const step = try parser.next(buffer[start..held]);
            start += step.used;
            switch (step.event) {
                .more => if (step.used == 0) break,
                .head => |head| {
                    out.status = head.status;
                    if (head.field("content-type")) |value| {
                        @memcpy(out.content_type[0..value.len], value);
                        out.content_type_len = value.len;
                    }
                },
                .body => |bytes| {
                    @memcpy(out.body[out.body_len..][0..bytes.len], bytes);
                    out.body_len += bytes.len;
                },
                .end => {
                    out.ended = true;
                    return;
                },
            }
        }
        std.mem.copyForwards(u8, buffer[0 .. held - start], buffer[start..held]);
        held -= start;
    }
    if (try parser.finish() == .end) out.ended = true;
}

fn expectEverySplit(response: []const u8, status: u16, body: []const u8) !void {
    for (0..response.len + 1) |split| {
        var out: Collected = .{};
        try collect(response, split, &out);
        try std.testing.expect(out.ended);
        try std.testing.expectEqual(status, out.status);
        try std.testing.expectEqualStrings(body, out.body[0..out.body_len]);
    }
}

fn expectRefused(response: []const u8, expected: Error) !void {
    for (0..response.len + 1) |split| {
        var out: Collected = .{};
        try std.testing.expectError(expected, collect(response, split, &out));
    }
}

test "a Content-Length body ends at its length, ignoring what follows" {
    try expectEverySplit("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}extra", 200, "{\"a\":1}");
    try expectEverySplit("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", 200, "");
    try expectEverySplit("HTTP/1.1 202 Accepted\r\nContent-Length: 2\r\ncontent-length: 2\r\n\r\nok", 202, "ok");
}

test "a chunked body is joined, with extensions and trailers read past" {
    try expectEverySplit("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n" ++ "1;name=value\r\n,\r\n" ++ "6 ; x\r\n world\r\n" ++ "0\r\nX-Trailer: done\r\n\r\n", 200, "hello, world");
    try expectEverySplit("HTTP/1.1 200 OK\r\ntransfer-encoding: Chunked\r\n\r\nA\r\n0123456789\r\n0\r\n\r\n", 200, "0123456789");
}

test "a body with no framing runs to the end of the connection" {
    try expectEverySplit("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: 1\n\n", 200, "data: 1\n\n");
    try expectEverySplit("HTTP/1.1 200 OK\r\n\r\n", 200, "");
}

test "interim responses are skipped and 204 has no body" {
    try expectEverySplit("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx", 200, "x");
    try expectEverySplit("HTTP/1.1 204 No Content\r\n\r\n", 204, "");
    try expectEverySplit("HTTP/1.1 401 \r\nContent-Length: 0\r\n\r\n", 401, "");
}

test "fields are found by name ignoring case, trimmed" {
    var parser: Parser = .{};
    const step = try parser.next("HTTP/1.1 200 OK\r\nX-One: \t a b \t\r\nContent-Type:text/event-stream\r\nx-one: second\r\n\r\n");
    const head = step.event.head;
    try std.testing.expectEqualStrings("a b", head.field("x-one").?);
    try std.testing.expectEqualStrings("text/event-stream", head.field("CONTENT-TYPE").?);
    try std.testing.expectEqual(null, head.field("X-Two"));
}

test "a malformed head is refused" {
    const heads = [_][]const u8{
        "HTTP/1.0 200 OK\r\n\r\n",
        "HTTP/1.1 20 OK\r\n\r\n",
        "HTTP/1.1 2000 OK\r\n\r\n",
        "HTTP/1.1 099 Low\r\n\r\n",
        "HTTP/1.1 200\r\n\r\n",
        "HTTP/1.1 200 O\x01K\r\n\r\n",
        "HTTP/1.1 200 OK\r\nNo-Colon\r\n\r\n",
        "HTTP/1.1 200 OK\r\nBad Name: x\r\n\r\n",
        "HTTP/1.1 200 OK\r\n: empty name\r\n\r\n",
        "HTTP/1.1 200 OK\r\nX: a\nb\r\n\r\n",
        "HTTP/1.1 200 OK\r\nX: a\r\n folded\r\n\r\n",
        "HTTP/1.1 200 OK\r\nX: a\x7f\r\n\r\n",
    };
    for (heads) |head| try expectRefused(head, error.InvalidHead);
}

test "ambiguous framing is refused" {
    const heads = [_][]const u8{
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: +1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 1, 1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length:\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 99999999999999999999\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: identity\r\n\r\n",
        "HTTP/1.1 204 No Content\r\nContent-Length: 1\r\n\r\n",
    };
    for (heads) |head| try expectRefused(head, error.InvalidFraming);
}

test "malformed chunks are refused" {
    const bodies = [_][]const u8{
        "\r\n",
        "x\r\n",
        "5\r\nhelloXX",
        "1 junk\r\n",
        "11111111111111111\r\n",
        "0\r\nBad Trailer\r\n\r\n",
    };
    for (bodies) |body| {
        var response: [128]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&response, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n{s}", .{body});
        const expected: Error = if (std.mem.indexOf(u8, body, "Trailer") != null) error.InvalidHead else error.InvalidChunk;
        try expectRefused(bytes, expected);
    }
}

test "a response cut short is truncated, whatever framed it" {
    const responses = [_][]const u8{
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nabc",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nab",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n",
        "HTTP/1.1 200 OK\r\nContent-",
        "",
    };
    for (responses) |response| try expectRefused(response, error.TruncatedResponse);
}

test "101 is refused" {
    try expectRefused("HTTP/1.1 101 Switching Protocols\r\nUpgrade: h2c\r\n\r\n", error.UnexpectedUpgrade);
}

test "a head and a line are bounded" {
    var parser: Parser = .{};
    const big: [max_head_bytes]u8 = @splat('a');
    try std.testing.expectError(error.HeadTooLarge, parser.next(&big));

    var chunked: Parser = .{ .state = .chunk_size };
    const long_line = [_]u8{'1'} ++ @as([max_line_bytes + 1]u8, @splat(' '));
    try std.testing.expectError(error.LineTooLarge, chunked.next(&long_line));
    const short = [_]u8{'1'} ++ @as([max_line_bytes - 1]u8, @splat(' '));
    try std.testing.expectEqual(Event.more, (try chunked.next(&short)).event);
}

test "a head arriving a byte at a time is scanned once" {
    const response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
    var parser: Parser = .{};
    for (1..response.len) |len| {
        const step = try parser.next(response[0..len]);
        try std.testing.expectEqual(@as(usize, 0), step.used);
        try std.testing.expectEqual(len, parser.scanned);
    }
    const step = try parser.next(response);
    try std.testing.expectEqual(@as(u16, 200), step.event.head.status);
    try std.testing.expectEqual(Event.end, (try parser.next(response[step.used..])).event);
}
