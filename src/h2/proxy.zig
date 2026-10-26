//! The `http://` proxy `https://` origins tunnel through with CONNECT (RFC
//! 9110 section 9.3.6): the parts of its URL, which hosts bypass it, and
//! the tunnel's request and answer. A functional core: `Engine` reads the
//! settings and `Connection` does the I/O. Internal.
const std = @import("std");

pub const UrlError = error{ HttpsProxyInvalid, HttpsProxySchemeUnsupported };

/// A proxy URL's parts, slices of it.
pub const UrlParts = struct {
    /// `host[:port]`, for `h2.parseHostPort` with port 80 by default.
    authority: []const u8,
    /// Percent-encoded `user[:password]`; null when the URL carries none or
    /// an empty one.
    user_info: ?[]const u8,
};

/// `[http://][user[:password]@]host[:port][/]`. Without a scheme the URL
/// is an `http://` one, as proxy settings are commonly written. Any other
/// scheme, `https://` included, is refused: Rui does not speak TLS to a
/// proxy.
pub fn splitUrl(text: []const u8) UrlError!UrlParts {
    var rest = text;
    if (std.mem.indexOf(u8, rest, "://")) |end| {
        if (!std.ascii.eqlIgnoreCase(rest[0..end], "http")) return error.HttpsProxySchemeUnsupported;
        rest = rest[end + "://".len ..];
    }
    if (std.mem.endsWith(u8, rest, "/")) rest = rest[0 .. rest.len - 1];
    if (std.mem.indexOfAny(u8, rest, "/?#\\ \t\r\n") != null) return error.HttpsProxyInvalid;
    var user_info: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        if (at > 0) user_info = rest[0..at];
        rest = rest[at + 1 ..];
    }
    if (rest.len == 0) return error.HttpsProxyInvalid;
    return .{ .authority = rest, .user_info = user_info };
}

/// Longest user info, decoded, that credentials take.
pub const max_user_info_bytes = 512;

/// `Proxy-Authorization`'s value, `Basic` (RFC 7617), from a URL's
/// percent-encoded `user[:password]`.
pub fn basicCredentials(allocator: std.mem.Allocator, user_info: []const u8) (UrlError || error{OutOfMemory})![]u8 {
    const colon = std.mem.indexOfScalar(u8, user_info, ':');
    var decoded: [max_user_info_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &decoded);
    const user = percentDecode(user_info[0 .. colon orelse user_info.len], &decoded) orelse return error.HttpsProxyInvalid;
    // RFC 7617: the user-id cannot carry the separator.
    if (std.mem.indexOfScalar(u8, user, ':') != null) return error.HttpsProxyInvalid;
    var len = user.len;
    if (colon) |at| {
        if (len == decoded.len) return error.HttpsProxyInvalid;
        decoded[len] = ':';
        len += 1;
        len += (percentDecode(user_info[at + 1 ..], decoded[len..]) orelse return error.HttpsProxyInvalid).len;
    }
    const encoder = std.base64.standard.Encoder;
    const prefix = "Basic ";
    const value = try allocator.alloc(u8, prefix.len + encoder.calcSize(len));
    @memcpy(value[0..prefix.len], prefix);
    _ = encoder.encode(value[prefix.len..], decoded[0..len]);
    return value;
}

/// `%XX` escapes decoded into `out`; null when malformed, when it does not
/// fit, or when it decodes to a control byte, which no header may carry.
fn percentDecode(text: []const u8, out: []u8) ?[]u8 {
    var len: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (len += 1) {
        if (len == out.len) return null;
        var byte = text[index];
        if (byte == '%') {
            if (index + 3 > text.len) return null;
            byte = std.fmt.parseInt(u8, text[index + 1 .. index + 3], 16) catch return null;
            index += 3;
        } else index += 1;
        if (std.ascii.isControl(byte)) return null;
        out[len] = byte;
    }
    return out[0..len];
}

/// Whether `host` (a URL host without brackets or trailing dot) is a
/// loopback name or address, which never goes through a proxy.
pub fn isLoopback(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost") or endsWithLabel(host, "localhost")) return true;
    const address = Address.parse(host) orelse return false;
    return switch (address.len) {
        4 => address.bytes[0] == 127,
        else => std.mem.allEqual(u8, address.bytes[0..15], 0) and address.bytes[15] == 1,
    };
}

/// Whether `no_proxy` exempts `host` (a URL host without brackets or
/// trailing dot) from the proxy. Entries are comma-separated, with spaces
/// around them ignored:
/// - `*` exempts every host;
/// - an IP address, or a CIDR range such as `10.0.0.0/8` or `fd00::/8`,
///   exempts the addresses it covers, when the host is an address;
/// - a name exempts itself and every name below it, with or without a
///   leading dot (`example.com` and `.example.com` both exempt
///   `api.example.com`). Names compare without case.
///
/// An entry that is none of these exempts nothing.
pub fn bypasses(no_proxy: []const u8, host: []const u8) bool {
    const address = Address.parse(host);
    var entries = std.mem.tokenizeScalar(u8, no_proxy, ',');
    while (entries.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        if (std.mem.eql(u8, entry, "*")) return true;
        if (Range.parse(entry)) |range| {
            if (address) |value| if (range.covers(value)) return true;
            continue;
        }
        if (address != null) continue;
        var name = std.mem.trimStart(u8, entry, ".");
        name = std.mem.trimEnd(u8, name, ".");
        if (name.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(host, name) or endsWithLabel(host, name)) return true;
    }
    return false;
}

/// Whether `host` ends with `.suffix`, without case.
fn endsWithLabel(host: []const u8, suffix: []const u8) bool {
    return host.len > suffix.len and host[host.len - suffix.len - 1] == '.' and
        std.ascii.eqlIgnoreCase(host[host.len - suffix.len ..], suffix);
}

/// An IPv4 or IPv6 address, parsed here so this core needs no network
/// API.
pub const Address = struct {
    bytes: [16]u8,
    /// 4 or 16.
    len: u8,

    /// Dotted-quad IPv4 or RFC 4291 text IPv6 (`::` compression and a
    /// trailing dotted quad), without brackets or zone; null otherwise.
    pub fn parse(text: []const u8) ?Address {
        if (parse4(text)) |bytes| {
            var address: Address = .{ .bytes = @splat(0), .len = 4 };
            @memcpy(address.bytes[0..4], &bytes);
            return address;
        }
        return .{ .bytes = parse6(text) orelse return null, .len = 16 };
    }

    fn parse4(text: []const u8) ?[4]u8 {
        var bytes: [4]u8 = undefined;
        var parts = std.mem.splitScalar(u8, text, '.');
        for (&bytes) |*byte| {
            const part = parts.next() orelse return null;
            // Decimal only: no empty part, sign or leading zero.
            if (part.len == 0 or part.len > 3 or (part.len > 1 and part[0] == '0')) return null;
            for (part) |digit| if (!std.ascii.isDigit(digit)) return null;
            byte.* = std.fmt.parseInt(u8, part, 10) catch return null;
        }
        return if (parts.next() == null) bytes else null;
    }

    fn parse6(text: []const u8) ?[16]u8 {
        var head: [16]u8 = undefined;
        var head_len: usize = 0;
        var tail: [16]u8 = undefined;
        var tail_len: usize = 0;
        const gap = std.mem.indexOf(u8, text, "::");
        if (gap) |at| if (std.mem.indexOfPos(u8, text, at + 1, "::") != null) return null;
        const before = if (gap) |at| text[0..at] else text;
        if (!groups(before, &head, &head_len)) return null;
        if (gap) |at| if (!groups(text[at + 2 ..], &tail, &tail_len)) return null;
        if (gap == null and head_len != 16) return null;
        if (gap != null and head_len + tail_len > 14) return null;
        var bytes: [16]u8 = @splat(0);
        @memcpy(bytes[0..head_len], head[0..head_len]);
        @memcpy(bytes[16 - tail_len ..], tail[0..tail_len]);
        return bytes;
    }

    /// Colon-separated hex groups, the last of which may be a dotted quad.
    fn groups(text: []const u8, out: *[16]u8, len: *usize) bool {
        if (text.len == 0) return true;
        var parts = std.mem.splitScalar(u8, text, ':');
        while (parts.next()) |part| {
            if (parts.peek() == null and std.mem.indexOfScalar(u8, part, '.') != null) {
                const quad = parse4(part) orelse return false;
                if (len.* + 4 > 16) return false;
                @memcpy(out[len.*..][0..4], &quad);
                len.* += 4;
                return true;
            }
            if (part.len == 0 or part.len > 4 or len.* + 2 > 16) return false;
            const group = std.fmt.parseInt(u16, part, 16) catch return false;
            out[len.*] = @intCast(group >> 8);
            out[len.* + 1] = @truncate(group);
            len.* += 2;
        }
        return true;
    }
};

const Range = struct {
    base: Address,
    prefix_bits: u8,

    fn parse(entry: []const u8) ?Range {
        const slash = std.mem.indexOfScalar(u8, entry, '/');
        var text = entry[0 .. slash orelse entry.len];
        if (text.len > 2 and text[0] == '[' and text[text.len - 1] == ']') text = text[1 .. text.len - 1];
        const base = Address.parse(text) orelse return null;
        const prefix_bits = if (slash) |at| std.fmt.parseInt(u8, entry[at + 1 ..], 10) catch return null else base.len * 8;
        if (prefix_bits > base.len * 8) return null;
        return .{ .base = base, .prefix_bits = prefix_bits };
    }

    fn covers(self: Range, address: Address) bool {
        if (address.len != self.base.len) return false;
        const whole = self.prefix_bits / 8;
        if (!std.mem.eql(u8, address.bytes[0..whole], self.base.bytes[0..whole])) return false;
        const rest: u3 = @intCast(self.prefix_bits % 8);
        if (rest == 0) return true;
        const mask = ~(@as(u8, 0xff) >> rest);
        return address.bytes[whole] & mask == self.base.bytes[whole] & mask;
    }
};

/// A URL host's longest form, as `h2.max_host_bytes`.
pub const max_host_bytes = 253;

/// Room for the longest CONNECT request: two `host:port` targets and the
/// largest credentials.
pub const max_request_bytes = 2 * (max_host_bytes + "[]:65535".len) + 64 +
    "Proxy-Authorization: Basic \r\n".len + std.base64.standard.Encoder.calcSize(max_user_info_bytes);

/// The tunnel request for `host:port`, with `Host` as HTTP/1.1 requires,
/// and the proxy credentials when there are any.
pub fn connectRequest(buffer: *[max_request_bytes]u8, host: []const u8, port: u16, credentials: ?[]const u8) []const u8 {
    const open, const close = if (std.mem.indexOfScalar(u8, host, ':') != null) .{ "[", "]" } else .{ "", "" };
    var writer: std.Io.Writer = .fixed(buffer);
    writer.print("CONNECT {s}{s}{s}:{d} HTTP/1.1\r\nHost: {s}{s}{s}:{d}\r\n", .{ open, host, close, port, open, host, close, port }) catch unreachable;
    if (credentials) |value| writer.print("Proxy-Authorization: {s}\r\n", .{value}) catch unreachable;
    writer.writeAll("\r\n") catch unreachable;
    return writer.buffered();
}

/// The proxy's answer to CONNECT, read as it arrives: a status line and
/// header fields, at most `max_bytes` in all, after any interim (1xx)
/// answers, which a client reads past (RFC 9110 section 15.2). Only the
/// final status is kept.
pub const Answer = struct {
    consumed: u16 = 0,
    status: u16 = 0,
    phase: enum(u8) { version, status, reason, fields } = .version,
    /// Bytes of the status line's version, or of the status, read so far.
    part: u8 = 0,
    /// Of the CR LF CR LF that ends the fields, the bytes just matched.
    ending: u8 = 0,

    pub const max_bytes = 8192;

    pub const Step = union(enum) {
        /// The answer goes on past these bytes.
        more,
        /// The answer ended `used` bytes into these.
        done: struct { status: u16, used: usize },
        malformed,
    };

    pub fn feed(self: *Answer, bytes: []const u8) Step {
        for (bytes, 0..) |byte, index| {
            if (self.consumed == max_bytes) return .malformed;
            self.consumed += 1;
            switch (self.phase) {
                // "HTTP/1." and one digit, then a space.
                .version => {
                    const prefix = "HTTP/1.";
                    if (self.part < prefix.len) {
                        if (byte != prefix[self.part]) return .malformed;
                    } else if (self.part == prefix.len) {
                        if (!std.ascii.isDigit(byte)) return .malformed;
                    } else {
                        if (byte != ' ') return .malformed;
                        self.phase = .status;
                        self.part = 0;
                        continue;
                    }
                    self.part += 1;
                },
                // Three digits, then a space or the line's end.
                .status => if (self.part < 3) {
                    if (!std.ascii.isDigit(byte)) return .malformed;
                    self.status = self.status * 10 + (byte - '0');
                    self.part += 1;
                } else switch (byte) {
                    ' ' => self.phase = .reason,
                    '\r' => {
                        self.phase = .reason;
                        self.ending = 1;
                    },
                    else => return .malformed,
                },
                .reason, .fields => {
                    self.ending = switch (byte) {
                        '\r' => if (self.ending == 2) 3 else 1,
                        '\n' => switch (self.ending) {
                            1 => 2,
                            3 => {
                                // 101 switches protocols, which a tunnel cannot.
                                if (self.status >= 200 or self.status == 101)
                                    return .{ .done = .{ .status = self.status, .used = index + 1 } };
                                self.* = .{ .consumed = self.consumed };
                                continue;
                            },
                            else => return .malformed,
                        },
                        // A CR stands only before LF.
                        else => if (self.ending == 1 or self.ending == 3) return .malformed else 0,
                    };
                    // A line ended: what follows is a field, or the end.
                    if (self.ending == 2) self.phase = .fields;
                },
            }
        }
        return .more;
    }
};

test "proxy URLs: http or no scheme, credentials, and no other scheme" {
    const plain = try splitUrl("http://proxy.example:3128");
    try std.testing.expectEqualStrings("proxy.example:3128", plain.authority);
    try std.testing.expect(plain.user_info == null);
    try std.testing.expectEqualStrings("proxy.example", (try splitUrl("proxy.example")).authority);
    try std.testing.expectEqualStrings("proxy.example", (try splitUrl("HTTP://proxy.example/")).authority);

    const credentials = try splitUrl("http://us%40er:p@ss@[::1]:8080/");
    try std.testing.expectEqualStrings("[::1]:8080", credentials.authority);
    try std.testing.expectEqualStrings("us%40er:p@ss", credentials.user_info.?);
    // An empty user info carries no credentials.
    try std.testing.expect((try splitUrl("http://@proxy.example")).user_info == null);

    try std.testing.expectError(error.HttpsProxySchemeUnsupported, splitUrl("https://proxy.example:443"));
    try std.testing.expectError(error.HttpsProxySchemeUnsupported, splitUrl("socks5://proxy.example:1080"));
    for ([_][]const u8{ "", "http://", "http://user@", "http://proxy.example/path", "http://proxy .example" }) |text| {
        try std.testing.expectError(error.HttpsProxyInvalid, splitUrl(text));
    }
}

test "addresses: dotted quads and IPv6 text, nothing else" {
    try std.testing.expectEqualSlices(u8, &.{ 10, 1, 2, 255 }, Address.parse("10.1.2.255").?.bytes[0..4]);
    try std.testing.expectEqual(@as(u8, 4), Address.parse("0.0.0.0").?.len);
    const cases = [_]struct { text: []const u8, bytes: [16]u8 }{
        .{ .text = "::1", .bytes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } },
        .{ .text = "::", .bytes = @splat(0) },
        .{ .text = "fd00::", .bytes = .{ 0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .text = "2001:db8::8:800:200c:417a", .bytes = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 8, 8, 0, 0x20, 0x0c, 0x41, 0x7a } },
        .{ .text = "1:2:3:4:5:6:7:8", .bytes = .{ 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8 } },
        .{ .text = "::ffff:10.0.0.1", .bytes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1 } },
    };
    for (cases) |case| {
        const address = Address.parse(case.text) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u8, 16), address.len);
        try std.testing.expectEqualSlices(u8, &case.bytes, &address.bytes);
    }
    for ([_][]const u8{ "", "1.2.3", "1.2.3.4.5", "256.1.1.1", "01.1.1.1", "1.2.3.-4", "1::2::3", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7", "12345::", "::g", ":1", "1:", "1:2:3:4:5:6:7::8:9", "example.com", "[::1]" }) |text| {
        if (Address.parse(text) != null) {
            std.debug.print("parsed {s}\n", .{text});
            return error.TestUnexpectedResult;
        }
    }
}

test "credentials are Basic over the decoded user and password" {
    const allocator = std.testing.allocator;
    const value = try basicCredentials(allocator, "us%40er:p%3Ass");
    defer allocator.free(value);
    // base64("us@er:p:ss")
    try std.testing.expectEqualStrings("Basic dXNAZXI6cDpzcw==", value);
    const user_only = try basicCredentials(allocator, "user");
    defer allocator.free(user_only);
    try std.testing.expectEqualStrings("Basic dXNlcg==", user_only);
    try std.testing.expectError(error.HttpsProxyInvalid, basicCredentials(allocator, "a%3Ab:c"));
    try std.testing.expectError(error.HttpsProxyInvalid, basicCredentials(allocator, "user:%0d%0a"));
    try std.testing.expectError(error.HttpsProxyInvalid, basicCredentials(allocator, "user:%4"));
    const long: [max_user_info_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.HttpsProxyInvalid, basicCredentials(allocator, &long));
}

test "loopback names and addresses never use the proxy" {
    for ([_][]const u8{ "localhost", "LOCALHOST", "api.localhost", "127.0.0.1", "127.8.9.10", "::1" }) |host| {
        try std.testing.expect(isLoopback(host));
    }
    for ([_][]const u8{ "localhost.example", "128.0.0.1", "::2", "example.com" }) |host| {
        try std.testing.expect(!isLoopback(host));
    }
}

test "NO_PROXY: everything, names and the names below them, addresses and ranges" {
    const Case = struct { no_proxy: []const u8, host: []const u8, bypass: bool };
    const cases = [_]Case{
        .{ .no_proxy = "*", .host = "api.openai.com", .bypass = true },
        .{ .no_proxy = "", .host = "api.openai.com", .bypass = false },
        .{ .no_proxy = "openai.com", .host = "api.openai.com", .bypass = true },
        .{ .no_proxy = ".openai.com", .host = "api.openai.com", .bypass = true },
        .{ .no_proxy = ".openai.com", .host = "openai.com", .bypass = true },
        .{ .no_proxy = "OpenAI.COM.", .host = "api.openai.com", .bypass = true },
        .{ .no_proxy = "ai.com", .host = "api.openai.com", .bypass = false },
        .{ .no_proxy = "api.openai.com", .host = "openai.com", .bypass = false },
        .{ .no_proxy = " example.com , openai.com ", .host = "chatgpt.openai.com", .bypass = true },
        .{ .no_proxy = ",,", .host = "openai.com", .bypass = false },
        .{ .no_proxy = "10.1.2.3", .host = "10.1.2.3", .bypass = true },
        .{ .no_proxy = "10.0.0.0/8", .host = "10.200.0.1", .bypass = true },
        .{ .no_proxy = "10.0.0.0/8", .host = "11.0.0.1", .bypass = false },
        .{ .no_proxy = "192.168.4.0/22", .host = "192.168.7.255", .bypass = true },
        .{ .no_proxy = "192.168.4.0/22", .host = "192.168.8.0", .bypass = false },
        .{ .no_proxy = "fd00::/8", .host = "fd12::1", .bypass = true },
        .{ .no_proxy = "[2001:db8::1]", .host = "2001:db8::1", .bypass = true },
        .{ .no_proxy = "10.0.0.0/8", .host = "fd12::1", .bypass = false },
        .{ .no_proxy = "10.0.0.0/33", .host = "10.0.0.1", .bypass = false },
        // A name entry does not cover an address, nor an address a name.
        .{ .no_proxy = "10.1.2.3", .host = "host.10.1.2.3", .bypass = false },
    };
    for (cases) |case| {
        if (bypasses(case.no_proxy, case.host) != case.bypass) {
            std.debug.print("no_proxy={s} host={s}\n", .{ case.no_proxy, case.host });
            return error.TestUnexpectedResult;
        }
    }
}

test "the CONNECT request names the target twice, bracketing IPv6, with any credentials" {
    var buffer: [max_request_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "CONNECT api.openai.com:443 HTTP/1.1\r\nHost: api.openai.com:443\r\n\r\n",
        connectRequest(&buffer, "api.openai.com", 443, null),
    );
    try std.testing.expectEqualStrings(
        "CONNECT [2001:db8::1]:8443 HTTP/1.1\r\nHost: [2001:db8::1]:8443\r\nProxy-Authorization: Basic dXNlcg==\r\n\r\n",
        connectRequest(&buffer, "2001:db8::1", 8443, "Basic dXNlcg=="),
    );
    var longest: [max_host_bytes]u8 = @splat('a');
    const credentials: [6 + std.base64.standard.Encoder.calcSize(max_user_info_bytes)]u8 = @splat('b');
    _ = connectRequest(&buffer, &longest, 65535, &credentials);
}

test "the proxy's answer: its status once the fields end, in any split" {
    const answer = "HTTP/1.1 200 Connection established\r\nProxy-Agent: test\r\n\r\n";
    for (0..answer.len) |split| {
        var reader: Answer = .{};
        const first = reader.feed(answer[0..split]);
        if (split > 0) try std.testing.expectEqual(Answer.Step.more, first);
        const second = reader.feed(answer[split..]);
        try std.testing.expectEqual(@as(u16, 200), second.done.status);
        try std.testing.expectEqual(answer.len - split, second.done.used);
    }
    var bare: Answer = .{};
    try std.testing.expectEqual(@as(u16, 407), bare.feed("HTTP/1.0 407\r\n\r\nafter").done.status);
    // Interim answers come first and are read past; 101 is final.
    const interim = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </>\r\n\r\nHTTP/1.1 200 OK\r\n\r\n";
    var past: Answer = .{};
    const step = past.feed(interim);
    try std.testing.expectEqual(@as(u16, 200), step.done.status);
    try std.testing.expectEqual(interim.len, step.done.used);
    var switching: Answer = .{};
    try std.testing.expectEqual(@as(u16, 101), switching.feed("HTTP/1.1 101 Switching\r\n\r\n").done.status);
    var trailing: Answer = .{};
    try std.testing.expectEqual(@as(usize, 19), trailing.feed("HTTP/1.1 200 OK\r\n\r\nTLS").done.used);

    for ([_][]const u8{ "HTTP/2 200 OK\r\n\r\n", "HTTP/1.1 20 OK\r\n\r\n", "HTTP/1.1 2000\r\n\r\n", "HTTP/1.1 200 OK\n\n", "HTTP/1.1 200 OK\r\nA: b\rc\r\n\r\n", "SSH-2.0\r\n" }) |text| {
        var reader: Answer = .{};
        try std.testing.expectEqual(Answer.Step.malformed, reader.feed(text));
    }
    var endless: Answer = .{};
    const field: [Answer.max_bytes]u8 = @splat('x');
    try std.testing.expectEqual(Answer.Step.more, endless.feed("HTTP/1.1 200 OK\r\nX: "));
    try std.testing.expectEqual(Answer.Step.malformed, endless.feed(&field));
}
