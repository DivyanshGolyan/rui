//! A launch-only MySQL login. TCP always verifies TLS; a Unix socket may
//! be percent-encoded in the authority, or spelled as an absolute path.
const std = @import("std");
const protocol = @import("protocol.zig");
const wire = @import("store/wire/mysql_connection.zig");
const Url = @This();

allocator: std.mem.Allocator,
user: protocol.Bounded(256) = .{},
password: protocol.Bounded(1024) = .{},
host: protocol.Bounded(253) = .{},
socket: protocol.Bounded(107) = .{},
database: protocol.Bounded(64) = .{},
port: u16 = 3306,

pub fn create(allocator: std.mem.Allocator, text: []const u8) !*Url {
    const self = try allocator.create(Url);
    self.* = .{ .allocator = allocator };
    errdefer self.destroy();
    try self.parse(text);
    return self;
}

fn parse(self: *Url, text: []const u8) !void {
    if (!std.mem.startsWith(u8, text, "mysql://") or std.mem.indexOfAny(u8, text, "?#\r\n\x00") != null) return error.InvalidMysqlUrl;
    const rest = text["mysql://".len..];
    const at = std.mem.indexOfScalar(u8, rest, '@') orelse return error.InvalidMysqlUrl;
    const colon = std.mem.indexOfScalar(u8, rest[0..at], ':') orelse return error.InvalidMysqlUrl;
    try decode(&self.user, rest[0..colon]);
    try decode(&self.password, rest[colon + 1 .. at]);
    if (self.user.len == 0) return error.InvalidMysqlUrl;
    const target = rest[at + 1 ..];
    const slash = std.mem.lastIndexOfScalar(u8, target, '/') orelse return error.InvalidMysqlUrl;
    const address = target[0..slash];
    try decode(&self.database, target[slash + 1 ..]);
    if (address.len == 0 or self.database.len == 0 or std.mem.indexOfScalar(u8, self.database.slice(), '/') != null) return error.InvalidMysqlUrl;
    if (address[0] == '/' or std.mem.startsWith(u8, address, "%2F") or std.mem.startsWith(u8, address, "%2f")) {
        try decode(&self.socket, address);
        if (!std.fs.path.isAbsolute(self.socket.slice())) return error.InvalidMysqlUrl;
        return;
    }
    var hostname = address;
    var port: ?[]const u8 = null;
    if (address[0] == '[') {
        const end = std.mem.indexOfScalar(u8, address, ']') orelse return error.InvalidMysqlUrl;
        hostname = address[1..end];
        if (end + 1 != address.len) {
            if (address[end + 1] != ':') return error.InvalidMysqlUrl;
            port = address[end + 2 ..];
        }
    } else if (std.mem.indexOfScalar(u8, address, ':')) |end| {
        hostname = address[0..end];
        port = address[end + 1 ..];
    }
    try decode(&self.host, hostname);
    if (self.host.len == 0 or std.mem.indexOfAny(u8, self.host.slice(), "/@[] ") != null) return error.InvalidMysqlUrl;
    if (port) |digits| {
        if (digits.len == 0) return error.InvalidMysqlUrl;
        for (digits) |digit| if (!std.ascii.isDigit(digit)) return error.InvalidMysqlUrl;
        self.port = std.fmt.parseInt(u16, digits, 10) catch return error.InvalidMysqlUrl;
        if (self.port == 0) return error.InvalidMysqlUrl;
    }
}

fn decode(out: anytype, text: []const u8) !void {
    var at: usize = 0;
    while (at < text.len) {
        var byte = text[at];
        if (byte == '%') {
            if (text.len - at < 3) return error.InvalidMysqlUrl;
            const hi = std.fmt.charToDigit(text[at + 1], 16) catch return error.InvalidMysqlUrl;
            const lo = std.fmt.charToDigit(text[at + 2], 16) catch return error.InvalidMysqlUrl;
            byte = @as(u8, hi) * 16 + lo;
            at += 2;
        }
        if (byte < 0x20 or byte == 0x7f or out.len == out.bytes.len) return error.InvalidMysqlUrl;
        out.bytes[out.len] = byte;
        out.len += 1;
        at += 1;
    }
    if (!std.unicode.utf8ValidateSlice(out.slice())) return error.InvalidMysqlUrl;
}

pub fn options(self: *Url) wire.Options {
    return .{
        .address = if (self.socket.len != 0) .{ .unix_socket = self.socket.slice() } else .{ .tcp_tls = .{ .host = self.host.slice(), .port = self.port, .trust = .system } },
        .user = self.user.slice(),
        .password = self.password.slice(),
        .password_to_wipe = &self.password.bytes,
        .database = self.database.slice(),
    };
}

/// The connection only borrows the password during open. Keep the non-secret
/// address alive until admission finishes, but never retain the password.
pub fn wipe(self: *Url) void {
    std.crypto.secureZero(u8, &self.password.bytes);
    self.password.len = 0;
}

pub fn destroy(self: *Url) void {
    const allocator = self.allocator;
    std.crypto.secureZero(u8, std.mem.asBytes(self));
    allocator.destroy(self);
}

test "mysql launch URLs decode credentials and select verified TLS or a socket" {
    const tls = try create(std.testing.allocator, "mysql://u%40ser:p%3Ass@localhost:3307/my_db");
    defer tls.destroy();
    try std.testing.expectEqualStrings("u@ser", tls.options().user);
    try std.testing.expectEqualStrings("p:ss", tls.options().password);
    try std.testing.expectEqual(@as(u16, 3307), tls.options().address.tcp_tls.port);
    try std.testing.expect(tls.options().address.tcp_tls.trust == .system);
    tls.wipe();
    for (tls.password.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for ([_][]const u8{ "mysql://u:p@%2Ftmp%2Fmysql.sock/db", "mysql://u:p@/tmp/mysql.sock/db" }) |text| {
        const socket = try create(std.testing.allocator, text);
        defer socket.destroy();
        try std.testing.expectEqualStrings("/tmp/mysql.sock", socket.options().address.unix_socket);
        try std.testing.expectEqualStrings("db", socket.options().database);
    }
    const ipv6 = try create(std.testing.allocator, "mysql://u:p@[::1]/db");
    defer ipv6.destroy();
    try std.testing.expectEqualStrings("::1", ipv6.options().address.tcp_tls.host);
}

test "mysql launch URLs refuse malformed logins without echoing input" {
    for ([_][]const u8{ "mysql://u:p@h", "mysql://u:p@h/", "mysql://:p@h/d", "mysql://u@h/d", "mysql://u:p@h:0/d", "mysql://u:p@h:65536/d", "mysql://u:p@h/d?password=x", "mysql://u:%00@h/d", "mysql://u:%gg@h/d", "mysql://u:p@h/path/db", "mysql://u:p@/db", "mysql://u:p@h/d#x" }) |text|
        try std.testing.expectError(error.InvalidMysqlUrl, create(std.testing.allocator, text));
}
