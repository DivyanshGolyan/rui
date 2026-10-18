//! Fail-closed summary of a provider HTTP error body: the classification an
//! answered HTTP failure retains after its scratch capture is discarded.
//!
//! Providers can echo prompts, tool arguments or credentials, so only a parsed
//! provider error envelope contributes body text: `error.type`, `error.code`,
//! `error.param` and `error.message`, and a top-level `detail` string. Short
//! identifier-shaped type, code and param values are kept; any other value is
//! replaced by its length. Message and detail keep ordinary words and replace
//! quoted spans that are not one short identifier, credential- or
//! address-shaped words, and anything a cap cuts. Every other body, including
//! one longer than the examined window, records only its HTTP status, size and
//! media type. The result is printable-ASCII JSON with no `\` and no `"` inside
//! a value, so it is terminal-safe.
const std = @import("std");

/// The Operation classification bound, including the JSON frame.
pub const max_bytes = 512;
/// Leading bytes of the sealed capture that a summary examines.
pub const window_bytes = 4096;
const max_identifier_bytes = 64;
const max_prose_bytes = 320;

/// Parsing scratch: a parse that does not fit records no body text.
pub const Workspace = struct { bytes: [32 * 1024]u8 = undefined };

/// The response's Content-Type header, if any.
pub const ContentType = union(enum) {
    absent,
    value: []const u8,
    /// A header longer than the transfer retains.
    oversized: usize,
};

/// `window` is the first min(`body_length`, `window_bytes`) captured bytes.
pub fn summarize(
    http_status: u32,
    body_length: u64,
    window: []const u8,
    content_type: ContentType,
    workspace: *Workspace,
    buffer: *[max_bytes]u8,
) []const u8 {
    std.debug.assert(window.len == @min(body_length, window_bytes));
    var out: Out = .{ .bytes = buffer };
    out.print("{{\"http_status\":\"{d}\",\"body_bytes\":\"{d}\",\"content_type\":", .{ http_status, body_length });
    switch (content_type) {
        .absent => out.append("null"),
        .value => |value| if (mediaType(value)) |media| {
            out.append("\"");
            for (media) |byte| out.append(&.{std.ascii.toLower(byte)});
            out.append("\"");
        } else out.print("\"<redacted {d} bytes>\"", .{value.len}),
        .oversized => |length| out.print("\"<redacted {d} bytes>\"", .{length}),
    }
    // A cut body cannot be parsed, so it never contributes text.
    if (body_length == window.len) if (parseEnvelope(window, workspace)) |envelope| {
        if (envelope.type) |value| out.identifierField("type", value);
        if (envelope.code) |value| switch (value) {
            .text => |text| out.identifierField("code", text),
            .number => |number| out.print(",\"code\":\"{d}\"", .{number}),
        };
        if (envelope.param) |value| out.identifierField("param", value);
        if (envelope.message) |value| out.proseField("message", value);
        if (envelope.detail) |value| out.proseField("detail", value);
    };
    if (out.truncated) out.append(",\"truncated\":true");
    out.append("}");
    return buffer[0..out.len];
}

/// The media type before any parameters, when it is token/token.
fn mediaType(value: []const u8) ?[]const u8 {
    const media = std.mem.trim(u8, value[0 .. std.mem.indexOfScalar(u8, value, ';') orelse value.len], " \t");
    const slash = std.mem.indexOfScalar(u8, media, '/') orelse return null;
    if (slash == 0 or slash + 1 == media.len or media.len > max_identifier_bytes) return null;
    for (media, 0..) |byte, index| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '&', '^', '_', '.', '+', '-' => {},
        '/' => if (index != slash) return null,
        else => return null,
    };
    return media;
}

const Envelope = struct {
    type: ?[]const u8 = null,
    code: ?union(enum) { text: []const u8, number: i64 } = null,
    param: ?[]const u8 = null,
    message: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

/// A complete JSON object with an `error` object or a top-level `detail`
/// string; any other shape, parse failure or exhausted scratch is not one.
fn parseEnvelope(body: []const u8, workspace: *Workspace) ?Envelope {
    var scratch = std.heap.FixedBufferAllocator.init(&workspace.bytes);
    const value = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), body, .{}) catch return null;
    if (value != .object) return null;
    var envelope: Envelope = .{};
    if (value.object.get("error")) |provider_error| if (provider_error == .object) {
        const fields = provider_error.object;
        envelope.type = string(fields.get("type"));
        envelope.param = string(fields.get("param"));
        envelope.message = string(fields.get("message"));
        if (fields.get("code")) |code| switch (code) {
            .string => |text| envelope.code = .{ .text = text },
            .integer => |number| envelope.code = .{ .number = number },
            else => {},
        };
    };
    envelope.detail = string(value.object.get("detail"));
    if (envelope.type == null and envelope.code == null and envelope.param == null and
        envelope.message == null and envelope.detail == null) return null;
    return envelope;
}

fn string(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return if (present == .string) present.string else null;
}

const Out = struct {
    bytes: *[max_bytes]u8,
    len: usize = 0,
    truncated: bool = false,
    /// The frame's tail: an optional truncation member and the closing brace.
    const reserve = ",\"truncated\":true}".len;

    fn room(self: *const Out) usize {
        return self.bytes.len - reserve - self.len;
    }

    fn append(self: *Out, text: []const u8) void {
        std.debug.assert(text.len <= self.bytes.len - self.len);
        @memcpy(self.bytes[self.len..][0..text.len], text);
        self.len += text.len;
    }

    fn print(self: *Out, comptime format: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(self.bytes[self.len..], format, args) catch unreachable;
        self.len += text.len;
    }

    fn identifierField(self: *Out, comptime name: []const u8, value: []const u8) void {
        var redaction: [32]u8 = undefined;
        const shown = if (identifier(value)) value else std.fmt.bufPrint(&redaction, "<redacted {d} bytes>", .{value.len}) catch unreachable;
        const frame = ",\"" ++ name ++ "\":\"\"";
        if (frame.len + shown.len > self.room()) {
            self.truncated = true;
            return;
        }
        self.append(frame[0 .. frame.len - 1]);
        self.append(shown);
        self.append("\"");
    }

    fn proseField(self: *Out, comptime name: []const u8, value: []const u8) void {
        const frame = ",\"" ++ name ++ "\":\"\"";
        // A field with no room for even one redaction marker is omitted.
        if (frame.len + 24 > self.room()) {
            self.truncated = true;
            return;
        }
        var excerpt: Excerpt = .{ .capacity = @min(max_prose_bytes, self.room() - frame.len) };
        var prose: Prose = .{ .out = &excerpt };
        var index: usize = 0;
        while (index < value.len) : (index += 1) {
            if (value[index] >= 0x80) {
                // One placeholder per UTF-8 sequence.
                while (index + 1 < value.len and value[index + 1] & 0xc0 == 0x80) index += 1;
                prose.feed('?');
            } else prose.feed(value[index]);
            if (excerpt.full) break;
        }
        prose.finish(index < value.len);
        if (excerpt.full) self.truncated = true;
        self.append(frame[0 .. frame.len - 1]);
        self.append(excerpt.slice());
        self.append("\"");
    }
};

const Excerpt = struct {
    bytes: [max_prose_bytes]u8 = undefined,
    len: usize = 0,
    capacity: usize,
    full: bool = false,

    fn slice(self: *const Excerpt) []const u8 {
        return self.bytes[0..self.len];
    }

    /// Text lands whole or not at all, so no word is ever cut into a prefix.
    fn append(self: *Excerpt, text: []const u8) void {
        if (self.full) return;
        if (text.len > self.capacity - self.len) {
            self.full = true;
            return;
        }
        for (text) |value| {
            self.bytes[self.len] = switch (value) {
                '"' => '\'',
                '\\' => '/',
                0x20...0x21, 0x23...0x5b, 0x5d...0x7e => value,
                else => '?',
            };
            self.len += 1;
        }
    }
};

/// A short value safe to keep verbatim: a model name, error code or path.
fn identifier(token: []const u8) bool {
    if (token.len == 0 or token.len > max_identifier_bytes or secret(token)) return false;
    for (token) |value| switch (value) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', ':', '/', '[', ']' => {},
        else => return false,
    };
    return true;
}

/// Credential- or identifier-shaped: an address, a long letter-digit run, or
/// a long word mixing letters and digits across separators.
fn secret(token: []const u8) bool {
    var run: usize = 0;
    var run_digits: usize = 0;
    var letters = false;
    var digits = false;
    for (token) |value| {
        switch (value) {
            'a'...'z', 'A'...'Z' => {
                run += 1;
                letters = true;
            },
            '0'...'9' => {
                run += 1;
                run_digits += 1;
                digits = true;
            },
            '@' => return true,
            else => {
                run = 0;
                run_digits = 0;
            },
        }
        if (run >= 24 or (run >= 16 and run_digits != 0)) return true;
    }
    return token.len >= 20 and letters and digits;
}

/// Ordinary words pass; quoted spans and secret-shaped words do not.
const Prose = struct {
    out: *Excerpt,
    token: [max_identifier_bytes]u8 = undefined,
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
            self.emitRedacted(self.seen);
            self.token_len = 0;
            self.seen = 0;
        } else self.flushWord();
    }

    /// The pending separator travels with its text, never alone.
    fn emit(self: *Prose, text: []const u8) void {
        var bytes: [1 + max_identifier_bytes + 2]u8 = undefined;
        const start: usize = if (self.space) 1 else 0;
        bytes[0] = ' ';
        @memcpy(bytes[start..][0..text.len], text);
        self.out.append(bytes[0 .. start + text.len]);
        self.space = false;
    }

    fn emitRedacted(self: *Prose, length: usize) void {
        var text: [32]u8 = undefined;
        self.emit(std.fmt.bufPrint(&text, "<redacted {d} bytes>", .{length}) catch unreachable);
    }

    fn keep(self: *Prose, value: u8) void {
        if (self.token_len < self.token.len) {
            self.token[self.token_len] = value;
            self.token_len += 1;
        }
        self.seen += 1;
    }

    fn flushWord(self: *Prose) void {
        if (self.seen == 0) return;
        const word = self.token[0..self.token_len];
        if (self.seen > self.token.len or secret(word)) self.emitRedacted(self.seen) else self.emit(word);
        self.token_len = 0;
        self.seen = 0;
    }

    fn closeSpan(self: *Prose, closed: bool, cut: bool) void {
        const quote: u8 = if (self.quote.? == '"') '\'' else self.quote.?;
        const span = self.token[0..self.token_len];
        var text: [max_identifier_bytes + 2]u8 = undefined;
        var redaction: [32]u8 = undefined;
        const inner = if (!cut and self.seen <= self.token.len and identifier(span))
            span
        else
            std.fmt.bufPrint(&redaction, "<redacted {d} bytes>", .{self.seen}) catch unreachable;
        // The span lands whole, with its quotes, or not at all.
        text[0] = quote;
        @memcpy(text[1..][0..inner.len], inner);
        var length = 1 + inner.len;
        if (closed) {
            text[length] = quote;
            length += 1;
        }
        self.emit(text[0..length]);
        self.quote = null;
        self.closing = false;
        self.token_len = 0;
        self.seen = 0;
    }
};

fn repeat(comptime text: []const u8, comptime count: usize) *const [text.len * count]u8 {
    const result = comptime blk: {
        var bytes: [text.len * count]u8 = undefined;
        for (0..count) |index| @memcpy(bytes[index * text.len ..][0..text.len], text);
        break :blk bytes;
    };
    return &result;
}

fn expectSummary(expected: []const u8, http_status: u32, content_type: ContentType, body: []const u8) !void {
    var workspace: Workspace = .{};
    var buffer: [max_bytes]u8 = undefined;
    const window = body[0..@min(body.len, window_bytes)];
    try std.testing.expectEqualStrings(expected, summarize(http_status, body.len, window, content_type, &workspace, &buffer));
}

fn expectNoLeak(summary: []const u8, comptime sentinels: anytype) !void {
    inline for (sentinels) |sentinel| {
        try std.testing.expect(std.mem.indexOf(u8, summary, sentinel) == null);
    }
}

const json: ContentType = .{ .value = "application/json" };

test "the incident's top-level detail survives with its quoted model name" {
    try expectSummary(
        "{\"http_status\":\"400\",\"body_bytes\":\"94\",\"content_type\":\"application/json\",\"detail\":\"The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account.\"}",
        400,
        json,
        "{\"detail\":\"The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account.\"}",
    );
}

test "an error envelope keeps type, code and param and redacts echoed input" {
    try expectSummary(
        "{\"http_status\":\"400\",\"body_bytes\":\"172\",\"content_type\":\"application/json\",\"type\":\"invalid_request_error\",\"param\":\"input[0].content\",\"message\":\"Invalid value: '<redacted 30 bytes>'. Supported values are: 'auto'.\"}",
        400,
        .{ .value = "Application/JSON; charset=utf-8" },
        "{\"error\":{\"message\":\"Invalid value: 'my private plan for the merger'. Supported values are: 'auto'.\",\"type\":\"invalid_request_error\",\"param\":\"input[0].content\",\"code\":null}}",
    );
    try expectSummary(
        "{\"http_status\":\"429\",\"body_bytes\":\"57\",\"content_type\":null,\"type\":\"<redacted 13 bytes>\",\"code\":\"429\"}",
        429,
        .absent,
        "{\"error\":{\"type\":\"rate limited!\",\"code\":429,\"extra\":\"x\"}}",
    );
}

test "secret-shaped and echoed content never reaches the summary" {
    const body =
        "{\"error\":{\"message\":\"Bearer sk-proj-abcDEF0123456789xyz rejected for user@example.com: \\\"tell me the launch codes\\\" " ++
        "input='LEAKPROMPT do not keep' args=(`cat LEAKARGS`) key Zm9vYmFy+YmF6cXV4/cXV1eA9==\"," ++
        "\"code\":\"eyJhbGciOiJIUzI1NiJ9abcdefghijkl\",\"param\":\"cmd=cat secrets\"}," ++
        "\"detail\":\"token ghp_A1b2C3d4E5f6G7h8I9j0\"}";
    var workspace: Workspace = .{};
    var buffer: [max_bytes]u8 = undefined;
    const summary = summarize(400, body.len, body, json, &workspace, &buffer);
    try expectNoLeak(summary, .{ "sk-proj", "0123456789", "example.com", "launch", "LEAKPROMPT", "LEAKARGS", "Zm9v", "eyJ", "secrets", "ghp_", "A1b2" });
    try std.testing.expectEqualStrings(
        "{\"http_status\":\"400\",\"body_bytes\":\"" ++ std.fmt.comptimePrint("{d}", .{body.len}) ++ "\",\"content_type\":\"application/json\"," ++
            "\"code\":\"<redacted 32 bytes>\",\"param\":\"<redacted 15 bytes>\"," ++
            "\"message\":\"Bearer <redacted 27 bytes> rejected for <redacted 17 bytes> '<redacted 24 bytes>' input='<redacted 22 bytes>' args=(`<redacted 12 bytes>`) key <redacted 27 bytes>\"," ++
            "\"detail\":\"token <redacted 24 bytes>\"}",
        summary,
    );
}

test "bodies other than a provider envelope keep only status, size and media type" {
    const sentinel = "LEAKBODY";
    const cases = [_]struct { content_type: ContentType, body: []const u8 }{
        .{ .content_type = .{ .value = "text/html" }, .body = "<html><title>502 " ++ sentinel ++ "</title></html>" },
        .{ .content_type = json, .body = "{\"message\":\"" ++ sentinel ++ "\",\"note\":\"x\"}" },
        .{ .content_type = json, .body = "{\"error\":\"" ++ sentinel ++ "\"}" },
        .{ .content_type = json, .body = "{\"detail\":[{\"msg\":\"" ++ sentinel ++ "\"}]}" },
        .{ .content_type = json, .body = "{\"detail\":42}" },
        .{ .content_type = json, .body = "{\"message\":Bearer " ++ sentinel ++ "}" },
        .{ .content_type = json, .body = "[{\"detail\":\"" ++ sentinel ++ "\"}]" },
        .{ .content_type = .{ .value = "application/octet-stream" }, .body = "ab\x00\x1b" ++ sentinel },
        .{ .content_type = .absent, .body = "" },
    };
    for (cases) |case| {
        var workspace: Workspace = .{};
        var buffer: [max_bytes]u8 = undefined;
        const summary = summarize(400, case.body.len, case.body, case.content_type, &workspace, &buffer);
        try expectNoLeak(summary, .{sentinel});
        try std.testing.expect(std.mem.endsWith(u8, summary, "\"}") or std.mem.endsWith(u8, summary, "null}"));
        try std.testing.expect(std.mem.indexOf(u8, summary, "\"detail\"") == null and std.mem.indexOf(u8, summary, "\"message\"") == null);
    }
    try expectSummary(
        "{\"http_status\":\"502\",\"body_bytes\":\"40\",\"content_type\":\"text/html\"}",
        502,
        .{ .value = "text/html; charset=UTF-8" },
        "<html><title>502 " ++ sentinel ++ "</title></html>",
    );
    // A malformed or oversized Content-Type is only its length.
    try expectSummary(
        "{\"http_status\":\"400\",\"body_bytes\":\"0\",\"content_type\":\"<redacted 19 bytes>\"}",
        400,
        .{ .value = "text/" ++ sentinel ++ " x=\"y\"" },
        "",
    );
    try expectSummary(
        "{\"http_status\":\"400\",\"body_bytes\":\"0\",\"content_type\":\"<redacted 900 bytes>\"}",
        400,
        .{ .oversized = 900 },
        "",
    );
}

test "a body longer than the window records no text, even a valid envelope prefix" {
    var body: [window_bytes + 10]u8 = undefined;
    @memset(&body, ' ');
    @memcpy(body[0..30], "{\"detail\":\"LEAKBODY visible \"}");
    try expectSummary(
        "{\"http_status\":\"400\",\"body_bytes\":\"4106\",\"content_type\":\"application/json\"}",
        400,
        json,
        &body,
    );
}

test "escaped, capped and non-ASCII detail stays bounded, printable and uncut" {
    try expectSummary(
        "{\"http_status\":\"400\",\"body_bytes\":\"61\",\"content_type\":\"application/json\",\"detail\":\"caf? ?[2J ? 'quoted' a/b line two\"}",
        400,
        json,
        "{\"detail\":\"caf\xc3\xa9 \\u001b[2J \\u202e \\\"quoted\\\" a\\\\b line\\ntwo\"}",
    );
    // Many short words fill the cap; the excerpt ends on a whole word.
    var body: [3000]u8 = undefined;
    @memcpy(body[0..11], "{\"detail\":\"");
    var index: usize = 11;
    while (index + 5 < body.len - 2) : (index += 5) @memcpy(body[index..][0..5], "word ");
    @memcpy(body[index..][0..2], "\"}");
    const text = body[0 .. index + 2];
    var workspace: Workspace = .{};
    var buffer: [max_bytes]u8 = undefined;
    const summary = summarize(400, text.len, text, json, &workspace, &buffer);
    try std.testing.expect(summary.len <= max_bytes);
    try std.testing.expect(std.mem.endsWith(u8, summary, "word\",\"truncated\":true}"));
    for (summary) |value| try std.testing.expect(value >= 0x20 and value < 0x7f and value != '\\');
}

test "every field at its worst stays within the classification bound" {
    const long_value = repeat("v", 200);
    const body = "{\"error\":{\"type\":\"" ++ long_value ++ "\",\"code\":\"" ++ long_value ++ "\",\"param\":\"" ++ long_value ++
        "\",\"message\":\"" ++ repeat("w", 200) ++ " " ++ repeat("ab ", 300) ++ "\"},\"detail\":\"" ++ repeat("cd ", 300) ++ "\"}";
    var workspace: Workspace = .{};
    var buffer: [max_bytes]u8 = undefined;
    const summary = summarize(std.math.maxInt(u32), body.len, body[0..@min(body.len, window_bytes)], .{ .oversized = std.math.maxInt(usize) }, &workspace, &buffer);
    try std.testing.expect(summary.len <= max_bytes);
    try std.testing.expect(std.mem.endsWith(u8, summary, ",\"truncated\":true}"));
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, summary, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("http_status") != null);
}
