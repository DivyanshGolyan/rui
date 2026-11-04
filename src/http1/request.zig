//! What an HTTP/1.1 request is before it reaches a socket, as values: the
//! loopback target a URL names, and the head that asks it for one response.
//!
//! Plain HTTP reaches loopback only (D120), so a target is an IP literal on
//! the machine itself and never needs a name lookup. Every request carries
//! `Connection: close`: one connection per request, so closing it is the
//! cancel and the response may end with the connection.
const std = @import("std");
const Parser = @import("Parser.zig");

pub const max_url_bytes = 2048;

pub const Error = error{
    /// Not `http://`: TLS and other schemes are refused.
    UnsupportedScheme,
    /// The host is not 127.0.0.0/8 or [::1]. `localhost` is refused too:
    /// which address it names depends on the machine.
    NotLoopback,
    InvalidUrl,
    UrlTooLong,
};

pub const Family = enum { ipv4, ipv6 };

pub const Target = struct {
    family: Family,
    /// The address in network order; an IPv4 one uses the first 4 bytes.
    address: [16]u8,
    port: u16,
    /// `host[:port]` as the URL wrote it, for the Host field. Borrowed from
    /// the URL.
    authority: []const u8,
    /// The path and query, `/` when the URL has none. Borrowed from the URL.
    path: []const u8,
};

/// Reads `http://host[:port][/path[?query]]`, where host is an IPv4
/// loopback literal or `[::1]`. A URL with userinfo or a fragment is
/// refused, since neither belongs on the wire, and so is a query with no
/// path before it.
pub fn parseTarget(url: []const u8) Error!Target {
    if (url.len > max_url_bytes) return error.UrlTooLong;
    const scheme = "http://";
    if (url.len < scheme.len or !std.ascii.eqlIgnoreCase(url[0..scheme.len], scheme)) {
        return if (std.mem.indexOf(u8, url, "://") != null) error.UnsupportedScheme else error.InvalidUrl;
    }
    const rest = url[scheme.len..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_end];
    var path = rest[authority_end..];
    if (std.mem.indexOfScalar(u8, path, '#') != null) return error.InvalidUrl;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidUrl;
    for (path) |byte| if (byte <= ' ' or byte >= 0x7f) return error.InvalidUrl;
    if (path.len == 0) path = "/";
    if (path[0] == '?') return error.InvalidUrl;

    var target: Target = .{ .family = .ipv4, .address = @splat(0), .port = 80, .authority = authority, .path = path };
    var host = authority;
    var port_text: ?[]const u8 = null;
    if (std.mem.startsWith(u8, authority, "[")) {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidUrl;
        host = authority[1..close];
        const after = authority[close + 1 ..];
        if (after.len != 0) {
            if (after[0] != ':') return error.InvalidUrl;
            port_text = after[1..];
        }
        if (!std.mem.eql(u8, host, "::1")) return error.NotLoopback;
        target.family = .ipv6;
        target.address[15] = 1;
    } else {
        if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
            host = authority[0..colon];
            port_text = authority[colon + 1 ..];
        }
        if (host.len == 0) return error.InvalidUrl;
        target.address[0..4].* = ipv4(host) orelse return error.NotLoopback;
        if (target.address[0] != 127) return error.NotLoopback;
    }
    if (port_text) |text| target.port = port(text) orelse return error.InvalidUrl;
    return target;
}

fn ipv4(text: []const u8) ?[4]u8 {
    var octets: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, text, '.');
    for (&octets) |*octet| {
        const part = parts.next() orelse return null;
        if (part.len == 0 or part.len > 3 or (part.len > 1 and part[0] == '0')) return null;
        var value: u16 = 0;
        for (part) |digit| {
            if (!std.ascii.isDigit(digit)) return null;
            value = value * 10 + (digit - '0');
        }
        if (value > 255) return null;
        octet.* = @intCast(value);
    }
    if (parts.next() != null) return null;
    return octets;
}

fn port(text: []const u8) ?u16 {
    if (text.len == 0 or text.len > 5) return null;
    var value: u32 = 0;
    for (text) |digit| {
        if (!std.ascii.isDigit(digit)) return null;
        value = value * 10 + (digit - '0');
    }
    if (value == 0 or value > 65535) return null;
    return @intCast(value);
}

pub const Field = struct { name: []const u8, value: []const u8 };

/// Fields the head writes itself or that would change the framing; a
/// caller's field may not use one.
pub const owned_fields = [_][]const u8{ "host", "content-length", "connection", "transfer-encoding", "te", "upgrade", "keep-alive", "trailer", "expect" };

pub const FieldError = error{
    /// A name that is not a token or that the head owns, or a value with a
    /// control byte, a byte outside ASCII, or whitespace at either end.
    InvalidField,
};

/// A POST head is written in three parts: `beginPost`, any number of
/// `writeField`, then `endPost` with the body's length. A failed
/// `writeField` has written nothing.
pub fn beginPost(writer: *std.Io.Writer, target: Target) std.Io.Writer.Error!void {
    try writer.print("POST {s} HTTP/1.1\r\nHost: {s}\r\n", .{ target.path, target.authority });
}

pub fn writeField(writer: *std.Io.Writer, field: Field) (FieldError || std.Io.Writer.Error)!void {
    try checkField(field);
    try writer.print("{s}: {s}\r\n", .{ field.name, field.value });
}

pub fn endPost(writer: *std.Io.Writer, body_len: usize) std.Io.Writer.Error!void {
    try writer.print("Content-Length: {d}\r\nConnection: close\r\n\r\n", .{body_len});
}

/// A whole POST head with `fields` in order.
pub fn writePost(writer: *std.Io.Writer, target: Target, fields: []const Field, body_len: usize) (FieldError || std.Io.Writer.Error)!void {
    for (fields) |field| try checkField(field);
    try beginPost(writer, target);
    for (fields) |field| try writeField(writer, field);
    try endPost(writer, body_len);
}

pub fn checkField(field: Field) FieldError!void {
    if (!Parser.isToken(field.name)) return error.InvalidField;
    for (owned_fields) |owned| if (std.ascii.eqlIgnoreCase(field.name, owned)) return error.InvalidField;
    if (!isFieldValue(field.value)) return error.InvalidField;
}

/// RFC 9110 field-value restricted to ASCII: visible bytes, with spaces and
/// tabs only between them.
pub fn isFieldValue(value: []const u8) bool {
    for (value) |byte| {
        if (byte != ' ' and byte != '\t' and (byte < 0x21 or byte > 0x7e)) return false;
    }
    if (value.len == 0) return true;
    const first = value[0];
    const last = value[value.len - 1];
    return first != ' ' and first != '\t' and last != ' ' and last != '\t';
}

test "loopback targets are read from http URLs" {
    const plain = try parseTarget("http://127.0.0.1:3000/api/mcp");
    try std.testing.expectEqual(Family.ipv4, plain.family);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, plain.address[0..4]);
    try std.testing.expectEqual(@as(u16, 3000), plain.port);
    try std.testing.expectEqualStrings("127.0.0.1:3000", plain.authority);
    try std.testing.expectEqualStrings("/api/mcp", plain.path);

    const bare = try parseTarget("HTTP://127.1.2.3");
    try std.testing.expectEqual(@as(u16, 80), bare.port);
    try std.testing.expectEqualStrings("/", bare.path);

    const query = try parseTarget("http://127.0.0.1:9/?x=1");
    try std.testing.expectEqualStrings("/?x=1", query.path);

    const six = try parseTarget("http://[::1]:8080/mcp?x=1");
    try std.testing.expectEqual(Family.ipv6, six.family);
    try std.testing.expectEqualSlices(u8, &(@as([15]u8, @splat(0)) ++ [_]u8{1}), &six.address);
    try std.testing.expectEqual(@as(u16, 8080), six.port);
    try std.testing.expectEqualStrings("[::1]:8080", six.authority);
    try std.testing.expectEqualStrings("/mcp?x=1", six.path);
}

test "a target that is not plain loopback HTTP is refused" {
    const cases = [_]struct { []const u8, Error }{
        .{ "https://127.0.0.1/mcp", error.UnsupportedScheme },
        .{ "ftp://127.0.0.1/", error.UnsupportedScheme },
        .{ "127.0.0.1:3000/mcp", error.InvalidUrl },
        .{ "http://localhost:3000/mcp", error.NotLoopback },
        .{ "http://10.0.0.1/mcp", error.NotLoopback },
        .{ "http://128.0.0.1/", error.NotLoopback },
        .{ "http://[::2]/", error.NotLoopback },
        .{ "http://[0:0:0:0:0:0:0:1]/", error.NotLoopback },
        .{ "http://127.0.0.01/", error.NotLoopback },
        .{ "http://127.0.0/", error.NotLoopback },
        .{ "http://127.0.0.1.1/", error.NotLoopback },
        .{ "http://127.0.0.256/", error.NotLoopback },
        .{ "http:///mcp", error.InvalidUrl },
        .{ "http://127.0.0.1?x=1", error.InvalidUrl },
        .{ "http://user@127.0.0.1/", error.InvalidUrl },
        .{ "http://127.0.0.1/a#frag", error.InvalidUrl },
        .{ "http://127.0.0.1/a b", error.InvalidUrl },
        .{ "http://127.0.0.1/\x7f", error.InvalidUrl },
        .{ "http://127.0.0.1:/", error.InvalidUrl },
        .{ "http://127.0.0.1:0/", error.InvalidUrl },
        .{ "http://127.0.0.1:65536/", error.InvalidUrl },
        .{ "http://127.0.0.1:12a/", error.InvalidUrl },
        .{ "http://[::1/", error.InvalidUrl },
        .{ "http://[::1]x/", error.InvalidUrl },
    };
    for (cases) |case| try std.testing.expectError(case[1], parseTarget(case[0]));
    const long = "http://127.0.0.1/" ++ @as([max_url_bytes]u8, @splat('a'));
    try std.testing.expectError(error.UrlTooLong, parseTarget(long));
}

test "a POST head carries the caller's fields between Host and the framing" {
    const target = try parseTarget("http://127.0.0.1:3000/api/mcp");
    const fields = [_]Field{
        .{ .name = "Accept", .value = "application/json, text/event-stream" },
        .{ .name = "Mcp-Method", .value = "tools/list" },
    };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writePost(&writer, target, &fields, 42);
    const expected = "POST /api/mcp HTTP/1.1\r\nHost: 127.0.0.1:3000\r\n" ++
        "Accept: application/json, text/event-stream\r\nMcp-Method: tools/list\r\n" ++
        "Content-Length: 42\r\nConnection: close\r\n\r\n";
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "a field the head owns or cannot carry is refused" {
    const target = try parseTarget("http://127.0.0.1/");
    const bad = [_]Field{
        .{ .name = "Content-Length", .value = "1" },
        .{ .name = "HOST", .value = "x" },
        .{ .name = "connection", .value = "keep-alive" },
        .{ .name = "Transfer-Encoding", .value = "chunked" },
        .{ .name = "Bad Name", .value = "x" },
        .{ .name = "", .value = "x" },
        .{ .name = "X", .value = "a\r\nInjected: 1" },
        .{ .name = "X", .value = " padded" },
        .{ .name = "X", .value = "padded\t" },
        .{ .name = "X", .value = "caf\xc3\xa9" },
        .{ .name = "X", .value = "nul\x00" },
    };
    var buffer: [256]u8 = undefined;
    for (bad) |field| {
        var writer: std.Io.Writer = .fixed(&buffer);
        try std.testing.expectError(error.InvalidField, writePost(&writer, target, &.{field}, 0));
        try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }
    try checkField(.{ .name = "Authorization", .value = "Bearer abc.def" });
    try checkField(.{ .name = "X-Empty", .value = "" });
}
