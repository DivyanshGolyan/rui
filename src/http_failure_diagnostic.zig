//! Bounded, redacted summary of a provider HTTP error body: the classification
//! an answered HTTP failure retains after its scratch capture is discarded.
//!
//! Providers can echo prompts, tool arguments or credentials in error text, so
//! no raw body byte reaches the summary unexamined. JSON keeps object keys,
//! numbers, literals and short identifier-shaped strings; prose fields such as
//! `message` and `detail` keep ordinary words. Quoted spans that are not one
//! short identifier, long letter-digit runs, email-like words and other string
//! values become `<redacted N bytes>`. Non-JSON text gets the same prose rule;
//! control bytes mark the body binary and keep no excerpt. The result is JSON
//! of printable ASCII with no `"` or `\` inside the excerpt, so it is
//! terminal-safe and its JSON spelling is its own length.
const std = @import("std");

/// The Operation classification bound, including the JSON frame.
pub const max_bytes = 512;
/// Leading bytes of the sealed capture that a summary examines.
pub const window_bytes = 4096;
const max_excerpt_bytes = 360;
const max_token_bytes = 64;
const max_depth = 4;
const max_key_bytes = 32;

pub const Body = enum { empty, json, text, binary };

/// `window` is the first min(`body_length`, `window_bytes`) captured bytes.
pub fn summarize(http_status: u32, body_length: u64, window: []const u8, buffer: *[max_bytes]u8) []const u8 {
    std.debug.assert(window.len == @min(body_length, window_bytes));
    var excerpt: Excerpt = .{};
    const body = classify(window);
    switch (body) {
        .empty, .binary => {},
        .json => redactJson(window, body_length > window.len, &excerpt),
        .text => {
            var prose: Prose = .{ .out = &excerpt };
            for (window) |byte| prose.feed(byte);
            prose.finish(body_length > window.len);
        },
    }
    const truncated = excerpt.truncated or (body != .binary and body_length > window.len);
    return std.fmt.bufPrint(buffer, "{{\"http_status\":\"{d}\",\"body\":\"{s}\",\"body_bytes\":\"{d}\",\"excerpt\":\"{s}\",\"truncated\":{}}}", .{
        http_status, @tagName(body), body_length, excerpt.slice(), truncated,
    }) catch unreachable;
}

fn classify(window: []const u8) Body {
    if (window.len == 0) return .empty;
    for (window) |byte| switch (byte) {
        '\t', '\n', '\r' => {},
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => return .binary,
        else => {},
    };
    for (window) |byte| switch (byte) {
        ' ', '\t', '\n', '\r' => {},
        '{', '[' => return .json,
        else => return .text,
    };
    return .text;
}

const Excerpt = struct {
    bytes: [max_excerpt_bytes]u8 = undefined,
    len: usize = 0,
    truncated: bool = false,

    fn slice(self: *const Excerpt) []const u8 {
        return self.bytes[0..self.len];
    }

    fn append(self: *Excerpt, text: []const u8) void {
        for (text) |value| self.byte(value);
    }

    fn byte(self: *Excerpt, value: u8) void {
        if (self.len == self.bytes.len) {
            self.truncated = true;
            return;
        }
        self.bytes[self.len] = switch (value) {
            '"' => '\'',
            '\\' => '/',
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => value,
            else => '?',
        };
        self.len += 1;
    }

    fn redacted(self: *Excerpt, length: usize) void {
        var text: [40]u8 = undefined;
        self.append(std.fmt.bufPrint(&text, "<redacted {d} bytes>", .{length}) catch unreachable);
    }
};

/// A short value safe to keep verbatim: a model name, error code or path.
fn identifier(token: []const u8) bool {
    if (token.len == 0 or token.len > max_token_bytes or secret(token)) return false;
    for (token) |value| switch (value) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', ':', '/', '[', ']' => {},
        else => return false,
    };
    return true;
}

/// Credential- or identifier-shaped: a long letter-digit run or an address.
fn secret(token: []const u8) bool {
    var run: usize = 0;
    var digits: usize = 0;
    for (token) |value| {
        switch (value) {
            'a'...'z', 'A'...'Z' => run += 1,
            '0'...'9' => {
                run += 1;
                digits += 1;
            },
            '@' => return true,
            else => {
                run = 0;
                digits = 0;
            },
        }
        if (run >= 24 or (run >= 16 and digits != 0)) return true;
    }
    return false;
}

/// Ordinary words pass; quoted spans and secret-shaped words do not.
const Prose = struct {
    out: *Excerpt,
    token: [max_token_bytes]u8 = undefined,
    token_len: usize = 0,
    /// Length of the current word or quoted span, including overflow.
    seen: usize = 0,
    quote: ?u8 = null,
    closing: bool = false,
    space: bool = false,

    fn feed(self: *Prose, value: u8) void {
        if (self.quote) |quote| {
            if (self.closing) {
                self.closing = false;
                if (std.ascii.isAlphanumeric(value)) {
                    // An apostrophe inside the span, not its end.
                    self.keep(quote);
                    self.keep(value);
                    return;
                }
                self.closeSpan(true, false);
            } else if (value == quote) {
                self.closing = true;
                return;
            } else {
                self.keep(value);
                return;
            }
        }
        switch (value) {
            ' ', '\t', '\n', '\r' => {
                self.flushWord();
                if (self.out.len != 0) self.space = true;
            },
            // Any quote opens a span, including one after `=` or `(`, except
            // an apostrophe inside a word such as `don't` or `users'`.
            '\'', '`', '"' => if (value == '\'' and self.token_len != 0 and std.ascii.isAlphanumeric(self.token[self.token_len - 1])) {
                self.keep(value);
            } else {
                self.flushWord();
                self.separate();
                self.quote = value;
            },
            else => self.keep(value),
        }
    }

    /// `cut` means the text continues past what was fed, so the pending word
    /// or span may be a credential's prefix and is never kept.
    fn finish(self: *Prose, cut: bool) void {
        if (self.quote != null) {
            self.closeSpan(self.closing and !cut, cut);
        } else if (cut and self.seen != 0) {
            self.separate();
            self.out.redacted(self.seen);
            self.token_len = 0;
            self.seen = 0;
        } else self.flushWord();
    }

    fn keep(self: *Prose, value: u8) void {
        if (self.token_len < self.token.len) {
            self.token[self.token_len] = value;
            self.token_len += 1;
        }
        self.seen += 1;
    }

    fn separate(self: *Prose) void {
        if (self.space) self.out.byte(' ');
        self.space = false;
    }

    fn flushWord(self: *Prose) void {
        if (self.seen == 0) return;
        self.separate();
        const word = self.token[0..self.token_len];
        if (self.seen > self.token.len or secret(word)) self.out.redacted(self.seen) else self.out.append(word);
        self.token_len = 0;
        self.seen = 0;
    }

    fn closeSpan(self: *Prose, closed: bool, cut: bool) void {
        const quote = self.quote.?;
        const span = self.token[0..self.token_len];
        self.out.byte(quote);
        if (!cut and self.seen <= self.token.len and identifier(span)) self.out.append(span) else self.out.redacted(self.seen);
        if (closed) self.out.byte(quote);
        self.quote = null;
        self.closing = false;
        self.token_len = 0;
        self.seen = 0;
    }
};

/// String fields whose value is provider prose rather than an identifier.
fn proseKey(key: []const u8) bool {
    const names = [_][]const u8{ "message", "detail", "error", "error_description", "msg", "reason", "title", "description" };
    for (names) |name| if (std.ascii.eqlIgnoreCase(key, name)) return true;
    return false;
}

const Frame = struct {
    object: bool,
    key: [max_key_bytes]u8 = undefined,
    key_len: usize = 0,
    key_valid: bool = false,
};

/// A lenient scan of possibly truncated JSON. It emits one `path=value` per
/// scalar leaf and never validates; malformed bytes only lose structure.
/// `cut` means the body continues past the window.
fn redactJson(window: []const u8, cut: bool, out: *Excerpt) void {
    var frames: [max_depth]Frame = undefined;
    var depth: usize = 0;
    var overflow: usize = 0;
    var expect_key = false;
    var leaves: usize = 0;
    var index: usize = 0;
    while (index < window.len) {
        const value = window[index];
        switch (value) {
            '{', '[' => {
                index += 1;
                if (depth == max_depth) {
                    overflow += 1;
                    out.truncated = true;
                } else {
                    frames[depth] = .{ .object = value == '{' };
                    depth += 1;
                }
                expect_key = value == '{';
            },
            '}', ']' => {
                index += 1;
                if (overflow != 0) overflow -= 1 else if (depth != 0) depth -= 1;
                expect_key = false;
            },
            ',' => {
                index += 1;
                expect_key = overflow == 0 and depth != 0 and frames[depth - 1].object;
            },
            ':' => {
                index += 1;
                expect_key = false;
            },
            '"' => {
                if (expect_key and overflow == 0) {
                    const frame = &frames[depth - 1];
                    var key: Token = .{};
                    const scan = scanString(window, index, &key, null, out);
                    index = scan.index;
                    // Token keeps up to 64 bytes; a frame keeps at most 32.
                    frame.key_len = @min(key.len, max_key_bytes);
                    @memcpy(frame.key[0..frame.key_len], key.bytes[0..frame.key_len]);
                    frame.key_valid = scan.closed and key.seen <= max_key_bytes and identifier(frame.key[0..frame.key_len]);
                    expect_key = false;
                    continue;
                }
                const leaf = overflow == 0;
                if (leaf) startLeaf(out, frames[0..depth], &leaves);
                const prose = depth == 0 or (frames[depth - 1].object and frames[depth - 1].key_valid and
                    proseKey(frames[depth - 1].key[0..frames[depth - 1].key_len]));
                if (leaf and prose) {
                    var sink: Prose = .{ .out = out };
                    const scan = scanString(window, index, null, &sink, out);
                    index = scan.index;
                    sink.finish(!scan.closed);
                } else {
                    var token: Token = .{};
                    const scan = scanString(window, index, &token, null, out);
                    index = scan.index;
                    if (leaf) {
                        if (scan.closed and token.seen <= max_token_bytes and identifier(token.bytes[0..token.len])) out.append(token.bytes[0..token.len]) else out.redacted(token.seen);
                    }
                }
            },
            ' ', '\t', '\n', '\r' => index += 1,
            else => {
                const start = index;
                while (index < window.len and literalByte(window[index])) index += 1;
                if (index == start) {
                    index += 1;
                    continue;
                }
                if (overflow != 0) continue;
                startLeaf(out, frames[0..depth], &leaves);
                const literal = window[start..index];
                // Malformed JSON can carry bare words; only JSON literals and
                // whole numbers survive, never a cut prefix.
                if ((index < window.len or !cut) and jsonLiteral(literal)) out.append(literal) else out.redacted(literal.len);
            },
        }
    }
}

fn literalByte(value: u8) bool {
    return std.ascii.isAlphanumeric(value) or value == '-' or value == '+' or value == '.';
}

fn jsonLiteral(literal: []const u8) bool {
    if (std.mem.eql(u8, literal, "true") or std.mem.eql(u8, literal, "false") or std.mem.eql(u8, literal, "null")) return true;
    if (literal.len > 24 or !(std.ascii.isDigit(literal[0]) or literal[0] == '-')) return false;
    for (literal) |value| switch (value) {
        '0'...'9', '-', '+', '.', 'e', 'E' => {},
        else => return false,
    };
    return true;
}

fn startLeaf(out: *Excerpt, frames: []const Frame, leaves: *usize) void {
    if (leaves.* != 0) out.append("; ");
    leaves.* += 1;
    var first = true;
    for (frames) |frame| {
        if (frame.object) {
            if (!first) out.byte('.');
            if (frame.key_valid) out.append(frame.key[0..frame.key_len]) else out.byte('?');
        } else out.append("[]");
        first = false;
    }
    if (frames.len != 0) out.byte('=');
}

const Token = struct {
    bytes: [max_token_bytes]u8 = undefined,
    len: usize = 0,
    seen: usize = 0,

    fn feed(self: *Token, value: u8) void {
        if (self.len < self.bytes.len) {
            self.bytes[self.len] = value;
            self.len += 1;
        }
        self.seen += 1;
    }
};

const Scan = struct { index: usize, closed: bool };

/// Decodes the string starting at `start` (its opening quote) into exactly
/// one sink and returns the index after its closing quote, or the window end
/// for an unterminated string.
fn scanString(window: []const u8, start: usize, token: ?*Token, prose: ?*Prose, out: *Excerpt) Scan {
    var index = start + 1;
    while (index < window.len) {
        var value = window[index];
        index += 1;
        if (value == '"') return .{ .index = index, .closed = true };
        if (value == '\\') {
            if (index == window.len) break;
            const escaped = window[index];
            index += 1;
            value = switch (escaped) {
                'n', 't', 'r', 'b', 'f' => ' ',
                'u' => blk: {
                    if (window.len - index < 4) {
                        index = window.len;
                        break :blk '?';
                    }
                    const code = std.fmt.parseInt(u16, window[index..][0..4], 16) catch 0;
                    index += 4;
                    break :blk if (code >= 0x20 and code < 0x7f) @intCast(code) else '?';
                },
                else => escaped,
            };
        } else if (value >= 0x80) {
            // One placeholder per UTF-8 sequence.
            while (index < window.len and window[index] & 0xc0 == 0x80) index += 1;
            value = '?';
        }
        if (token) |sink| sink.feed(value) else prose.?.feed(value);
    }
    out.truncated = true;
    return .{ .index = window.len, .closed = false };
}

fn expectSummary(expected: []const u8, http_status: u32, body: []const u8) !void {
    var buffer: [max_bytes]u8 = undefined;
    const window = body[0..@min(body.len, window_bytes)];
    try std.testing.expectEqualStrings(expected, summarize(http_status, body.len, window, &buffer));
}

test "unsupported model detail keeps its prose and the quoted model name" {
    try expectSummary(
        "{\"http_status\":\"400\",\"body\":\"json\",\"body_bytes\":\"94\",\"excerpt\":\"detail=The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account.\",\"truncated\":false}",
        400,
        "{\"detail\":\"The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account.\"}",
    );
}

test "OpenAI error envelope keeps codes and redacts echoed input" {
    try expectSummary(
        "{\"http_status\":\"400\",\"body\":\"json\",\"body_bytes\":\"172\",\"excerpt\":\"error.message=Invalid value: '<redacted 30 bytes>'. Supported values are: 'auto'.; error.type=invalid_request_error; error.param=input[0].content; error.code=null\",\"truncated\":false}",
        400,
        "{\"error\":{\"message\":\"Invalid value: 'my private plan for the merger'. Supported values are: 'auto'.\",\"type\":\"invalid_request_error\",\"param\":\"input[0].content\",\"code\":null}}",
    );
}

test "credentials, addresses and non-prose strings never reach the excerpt" {
    const body =
        "{\"error\":{\"message\":\"Bearer sk-proj-abcDEF0123456789xyz rejected for user@example.com: \\\"tell me the launch codes\\\"\"," ++
        "\"arguments\":\"{\\\"cmd\\\":\\\"cat secrets\\\"}\",\"token\":\"eyJhbGciOiJIUzI1NiJ9abcdefghijkl\"}}";
    var buffer: [max_bytes]u8 = undefined;
    const summary = summarize(400, body.len, body, &buffer);
    inline for (.{ "sk-proj", "0123456789", "example.com", "launch", "codes", "cat secrets", "eyJ", "cmd" }) |leak| {
        if (std.mem.indexOf(u8, summary, leak) != null) {
            std.debug.print("leaked {s} in {s}\n", .{ leak, summary });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, summary, "error.message=Bearer <redacted 27 bytes> rejected for <redacted 17 bytes> '<redacted 24 bytes>'") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "error.arguments=<redacted 21 bytes>; error.token=<redacted 32 bytes>") != null);
}

test "an apostrophe inside a quoted span does not end its redaction" {
    try expectSummary(
        "{\"http_status\":\"400\",\"body\":\"text\",\"body_bytes\":\"41\",\"excerpt\":\"rejected '<redacted 26 bytes>' now\",\"truncated\":false}",
        400,
        "rejected 'please don't share my plan' now",
    );
}

test "quotes after punctuation still open redacted spans" {
    try expectSummary(
        "{\"http_status\":\"400\",\"body\":\"json\",\"body_bytes\":\"96\",\"excerpt\":\"detail=Rejected input='<redacted 22 bytes>' or arguments=('<redacted 12 bytes>') users' data\",\"truncated\":false}",
        400,
        "{\"detail\":\"Rejected input='LEAKPROMPT do not keep' or arguments=(\\\"cat LEAKARGS\\\") users' data\"}",
    );
}

test "malformed bare words and cut tokens fail closed" {
    try expectSummary(
        "{\"http_status\":\"400\",\"body\":\"json\",\"body_bytes\":\"40\",\"excerpt\":\"message=<redacted 6 bytes>; message=<redacted 21 bytes>\",\"truncated\":false}",
        400,
        "{\"message\":Bearer abcdef0123456789ghijk}",
    );
    try expectSummary(
        "{\"http_status\":\"400\",\"body\":\"json\",\"body_bytes\":\"42\",\"excerpt\":\"code=400; ok=true; x=null; n=-1.5e3\",\"truncated\":false}",
        400,
        "{\"code\":400,\"ok\":true,\"x\":null,\"n\":-1.5e3}",
    );
    // A credential that the window cuts after six bytes keeps none of them.
    const credential = "sk-LEAKabcdefghijklmnop";
    var text: [window_bytes - 6 + credential.len]u8 = undefined;
    @memset(&text, ' ');
    text[0] = 'x';
    @memcpy(text[window_bytes - 6 ..], credential);
    try expectSummary(
        "{\"http_status\":\"400\",\"body\":\"text\",\"body_bytes\":\"4113\",\"excerpt\":\"x <redacted 6 bytes>\",\"truncated\":true}",
        400,
        &text,
    );
    var json: [window_bytes - 6 + credential.len]u8 = undefined;
    @memset(&json, ' ');
    @memcpy(json[0..12], "{\"detail\":\"x");
    @memcpy(json[window_bytes - 6 ..], credential);
    try expectSummary(
        "{\"http_status\":\"400\",\"body\":\"json\",\"body_bytes\":\"4113\",\"excerpt\":\"detail=x <redacted 6 bytes>\",\"truncated\":true}",
        400,
        &json,
    );
}

test "object keys longer than a frame are elided without overrunning it" {
    // Separators keep the name identifier-shaped rather than secret-shaped.
    const name = comptime blk: {
        var bytes: [100]u8 = undefined;
        for (&bytes, 0..) |*value, index| value.* = if (index % 4 == 3) '_' else 'k';
        break :blk bytes;
    };
    inline for (.{ 32, 33, 64, 100 }) |length| {
        const body = "{\"" ++ name[0..length] ++ "\":\"v\"}";
        var buffer: [max_bytes]u8 = undefined;
        const summary = summarize(400, body.len, body, &buffer);
        const expected = if (length == 32) name[0..32] ++ "=v" else "?=v";
        try std.testing.expect(std.mem.indexOf(u8, summary, "\"excerpt\":\"" ++ expected ++ "\"") != null);
    }
    try expectSummary(
        "{\"http_status\":\"400\",\"body\":\"json\",\"body_bytes\":\"12\",\"excerpt\":\"\",\"truncated\":true}",
        400,
        "{\"kkkkkkkkkk",
    );
}

test "non-JSON, binary, empty and malformed bodies stay bounded and safe" {
    try expectSummary(
        "{\"http_status\":\"502\",\"body\":\"text\",\"body_bytes\":\"57\",\"excerpt\":\"<html><title>502 Bad Gateway</title> cloudflare</html>\",\"truncated\":false}",
        502,
        "<html><title>502 Bad Gateway</title>\r\n\tcloudflare</html>\n",
    );
    try expectSummary(
        "{\"http_status\":\"400\",\"body\":\"binary\",\"body_bytes\":\"5\",\"excerpt\":\"\",\"truncated\":false}",
        400,
        "ab\x00\x1bc",
    );
    try expectSummary(
        "{\"http_status\":\"400\",\"body\":\"empty\",\"body_bytes\":\"0\",\"excerpt\":\"\",\"truncated\":false}",
        400,
        "",
    );
    // Unterminated JSON is a truncated excerpt, never a raw copy.
    try expectSummary(
        "{\"http_status\":\"400\",\"body\":\"json\",\"body_bytes\":\"46\",\"excerpt\":\"error.message=bad 'gpt-x', '<redacted 10 bytes>\",\"truncated\":true}",
        400,
        "{\"error\":{\"message\":\"bad 'gpt-x', \\\"abcdef ghi",
    );
    // Non-ASCII and terminal controls inside strings become placeholders.
    try expectSummary(
        "{\"http_status\":\"400\",\"body\":\"json\",\"body_bytes\":\"35\",\"excerpt\":\"detail=caf? ?[2J ?\",\"truncated\":false}",
        400,
        "{\"detail\":\"caf\xc3\xa9 \\u001b[2J \\u202e\"}",
    );
}

test "summaries of large bodies stay within the classification bound" {
    var body: [3 * window_bytes]u8 = undefined;
    for ([_]u8{ 'a', '{', '"', ' ' }) |fill| {
        @memset(&body, fill);
        @memcpy(body[0..10], "{\"detail\":");
        var buffer: [max_bytes]u8 = undefined;
        const summary = summarize(429, body.len, body[0..window_bytes], &buffer);
        try std.testing.expect(summary.len <= max_bytes);
        try std.testing.expect(std.mem.endsWith(u8, summary, "\"truncated\":true}"));
        const excerpt_start = std.mem.indexOf(u8, summary, "\"excerpt\":\"").? + "\"excerpt\":\"".len;
        const excerpt = summary[excerpt_start .. summary.len - "\",\"truncated\":true}".len];
        try std.testing.expect(excerpt.len <= max_excerpt_bytes);
        for (excerpt) |value| try std.testing.expect(value >= 0x20 and value < 0x7f and value != '"' and value != '\\');
    }
    // Deep nesting is bounded and marks omission.
    const deep = "{\"a\":{\"b\":{\"c\":{\"d\":{\"e\":\"hidden\"}}},\"f\":\"seen\"}}";
    var buffer: [max_bytes]u8 = undefined;
    const summary = summarize(400, deep.len, deep, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, summary, "hidden") == null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "a.f=seen") != null);
    try std.testing.expect(std.mem.endsWith(u8, summary, "\"truncated\":true}"));
}
