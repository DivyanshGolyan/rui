//! URL values and transport admission, without sockets or TLS.
const std = @import("std");

pub const max_url_bytes = 2048;
/// The longest DNS name; IP literals are shorter.
pub const max_host_bytes = 253;

pub const UrlError = error{ InvalidUrl, CleartextNotLoopback };

pub const Scheme = enum(u8) { https, http };

pub const Url = struct {
    scheme: Scheme,
    /// Without brackets for an IPv6 literal. Name lookup uses it as written.
    host: []const u8,
    /// What SNI carries and the certificate must match: `host` without a
    /// fully qualified name's trailing dot (RFC 6066 section 3).
    server_name: []const u8,
    port: u16,
    /// `host[:port]` as written, for `:authority`.
    authority: []const u8,
    /// Path and query; "/" when the URL has none.
    path: []const u8,
};

/// The transport's safety rule: `https://` to any host, `http://` (h2c by
/// prior knowledge) only to the loopback literals 127.0.0.1 and [::1]. No
/// userinfo, no fragment, valid UTF-8, at most `max_url_bytes`. The parts
/// are slices of `url`.
pub fn parseUrl(url: []const u8) UrlError!Url {
    if (url.len > max_url_bytes or !std.unicode.utf8ValidateSlice(url)) return error.InvalidUrl;
    if (std.mem.indexOfAny(u8, url, "#\\ \t\r\n") != null) return error.InvalidUrl;
    const scheme: Scheme, const rest = if (std.mem.startsWith(u8, url, "https://"))
        .{ .https, url["https://".len..] }
    else if (std.mem.startsWith(u8, url, "http://"))
        .{ .http, url["http://".len..] }
    else
        return error.InvalidUrl;
    const authority_end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const authority = rest[0..authority_end];
    const path = if (authority_end == rest.len) "/" else rest[authority_end..];
    if (path[0] != '/') return error.InvalidUrl;
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidUrl;

    const host, const port = try parseHostPort(authority, switch (scheme) {
        .https => 443,
        .http => 80,
    });
    if (scheme == .http and !std.mem.eql(u8, host, "127.0.0.1") and !std.mem.eql(u8, host, "::1"))
        return error.CleartextNotLoopback;
    const server_name = if (host.len > 1 and host[host.len - 1] == '.') host[0 .. host.len - 1] else host;
    return .{ .scheme = scheme, .host = host, .server_name = server_name, .port = port, .authority = authority, .path = path };
}

/// `host[:port]`, or `[ipv6][:port]`, with `default_port` when it names
/// none. The host is a slice of `authority`, without brackets.
pub fn parseHostPort(authority: []const u8, default_port: u16) UrlError!struct { []const u8, u16 } {
    if (authority.len == 0) return error.InvalidUrl;
    var host: []const u8 = authority;
    var port_text: ?[]const u8 = null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidUrl;
        host = authority[1..close];
        const after = authority[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return error.InvalidUrl;
            port_text = after[1..];
        }
        _ = std.Io.net.Ip6Address.parse(host, 0) catch return error.InvalidUrl;
    } else {
        if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
            host = authority[0..colon];
            port_text = authority[colon + 1 ..];
        }
        if (host.len == 0 or host.len > max_host_bytes) return error.InvalidUrl;
        for (host) |byte| switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-' => {},
            else => return error.InvalidUrl,
        };
    }
    const port: u16 = if (port_text) |text| blk: {
        if (text.len == 0) return error.InvalidUrl;
        const value = std.fmt.parseInt(u16, text, 10) catch return error.InvalidUrl;
        if (value == 0) return error.InvalidUrl;
        break :blk value;
    } else default_port;
    return .{ host, port };
}

/// How a percent-decoded text reads `+`: as itself, or as a space (a form
/// or query value).
pub const Plus = enum { literal, space };

/// `%XX` escapes in `text` decoded into `out`; null when an escape is
/// malformed or the result does not fit. What the decoded bytes may hold is
/// the caller's policy.
pub fn percentDecode(text: []const u8, out: []u8, plus: Plus) ?[]u8 {
    var len: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (len += 1) {
        if (len == out.len) return null;
        var byte = text[index];
        if (byte == '%') {
            if (index + 3 > text.len) return null;
            // Digit by digit: a number parser would also take a sign.
            const high = std.fmt.charToDigit(text[index + 1], 16) catch return null;
            const low = std.fmt.charToDigit(text[index + 2], 16) catch return null;
            byte = high * 16 + low;
            index += 3;
        } else {
            if (plus == .space and byte == '+') byte = ' ';
            index += 1;
        }
        out[len] = byte;
    }
    return out[0..len];
}

test "percentDecode decodes escapes and reads plus as asked" {
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("a b+c", percentDecode("a%20b+c", &out, .literal).?);
    try std.testing.expectEqualStrings("a b c", percentDecode("a%20b+c", &out, .space).?);
    try std.testing.expectEqualStrings("", percentDecode("", &out, .literal).?);
    try std.testing.expectEqualStrings("A\xff", percentDecode("%41%fF", &out, .literal).?);
    for ([_][]const u8{ "%", "%2", "%4", "%zz", "%G0", "%+1", "%-0", "%0+", "123456789" }) |bad|
        try std.testing.expectEqual(@as(?[]u8, null), percentDecode(bad, &out, .literal));
}

test "URLs: https anywhere, cleartext only to loopback literals" {
    const parsed = try parseUrl("https://chatgpt.com/backend-api/codex/responses");
    try std.testing.expectEqual(Scheme.https, parsed.scheme);
    try std.testing.expectEqualStrings("chatgpt.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
    try std.testing.expectEqualStrings("chatgpt.com", parsed.authority);
    try std.testing.expectEqualStrings("/backend-api/codex/responses", parsed.path);
    try std.testing.expectEqualStrings("chatgpt.com", parsed.server_name);
    const qualified = try parseUrl("https://chatgpt.com./x");
    try std.testing.expectEqualStrings("chatgpt.com.", qualified.host);
    try std.testing.expectEqualStrings("chatgpt.com", qualified.server_name);
    try std.testing.expectEqualStrings("chatgpt.com.", qualified.authority);

    const loopback = try parseUrl("http://127.0.0.1:8080/v1?x=1");
    try std.testing.expectEqual(@as(u16, 8080), loopback.port);
    try std.testing.expectEqualStrings("127.0.0.1:8080", loopback.authority);
    try std.testing.expectEqualStrings("/v1?x=1", loopback.path);
    const six = try parseUrl("http://[::1]:9/v1");
    try std.testing.expectEqualStrings("::1", six.host);
    try std.testing.expectEqualStrings("[::1]:9", six.authority);

    try std.testing.expectError(error.CleartextNotLoopback, parseUrl("http://localhost:80/"));
    try std.testing.expectError(error.CleartextNotLoopback, parseUrl("http://10.0.0.1/"));
    for ([_][]const u8{
        "ftp://example.com/",
        "https://user@example.com/",
        "https://example.com/#top",
        "https:///path",
        "https://example.com:0/",
        "https://example.com:65536/",
        "https://example.com:/",
        "https://example.com?q=1",
        "https://exa mple.com/",
        "https://[::1/",
        "https://[not-ip]/",
        "https://example.com\xff/",
        comptime long: {
            var name: [max_host_bytes + 1]u8 = undefined;
            @memset(&name, 'a');
            const url = "https://" ++ name ++ "/";
            break :long url;
        },
    }) |url| try std.testing.expectError(error.InvalidUrl, parseUrl(url));
}
