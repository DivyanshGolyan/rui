//! A launch-only MySQL login. TCP always verifies TLS; a Unix socket may
//! be percent-encoded in the authority, or spelled as an absolute path.
//! TCP accepts only `ssl-ca=<absolute PEM path>` to replace system trust.
const std = @import("std");
pub const Value = @import("mysql_url_value.zig").ValueWith(@import("host_settings.zig").max_ca_file_bytes);
pub const parseInto = @import("mysql_url_value.zig").parseInto;
const wire = @import("store/wire/mysql_connection.zig");
const Url = @This();

allocator: std.mem.Allocator,
user: @FieldType(Value, "user") = .{},
password: @FieldType(Value, "password") = .{},
host: @FieldType(Value, "host") = .{},
socket: @FieldType(Value, "socket") = .{},
database: @FieldType(Value, "database") = .{},
ca_file: @FieldType(Value, "ca_file") = .{},
port: @FieldType(Value, "port") = Value.default_port,

pub fn create(allocator: std.mem.Allocator, text: []const u8) !*Url {
    const self = try allocator.create(Url);
    self.* = .{ .allocator = allocator };
    errdefer self.destroy();
    try self.parse(text);
    return self;
}

pub const parse = parseInto;

pub fn options(self: *Url) wire.Options {
    return .{
        .address = if (self.socket.len != 0) .{ .unix_socket = self.socket.slice() } else .{ .tcp_tls = .{ .host = self.host.slice(), .port = self.port, .trust = if (self.ca_file.len != 0) .{ .ca_file = self.ca_file.slice() } else .system } },
        .user = self.user.slice(),
        .password = self.password.slice(),
        .password_to_wipe = &self.password.bytes,
        .database = self.database.slice(),
    };
}

/// The connection only borrows the password during open. Keep the non-secret
/// address and CA path alive through open; reconnects use connection-owned
/// loaded trust, not the path. Never retain the launch password.
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

test "mysql launch URLs select an exclusive ssl-ca and preserve it when wiping" {
    for ([_][]const u8{
        "mysql://u:p@host/db?ssl-ca=/etc/rds/global-bundle.pem",
        "mysql://u:p@host/db?ssl-ca=%2Fetc%2Frds%2Fglobal-bundle.pem",
        "mysql://u:p@[::1]:3307/db?ssl-ca=/etc/rds/global-bundle.pem",
    }) |text| {
        const url = try create(std.testing.allocator, text);
        defer url.destroy();
        try std.testing.expectEqualStrings("db", url.options().database);
        try std.testing.expect(url.options().address.tcp_tls.trust == .ca_file);
        try std.testing.expectEqualStrings("/etc/rds/global-bundle.pem", url.options().address.tcp_tls.trust.ca_file);
        url.wipe();
        try std.testing.expectEqualStrings("/etc/rds/global-bundle.pem", url.options().address.tcp_tls.trust.ca_file);
        try std.testing.expectEqualStrings("", url.options().password);
    }
}

test "mysql launch URLs refuse every unsupported ssl-ca query shape" {
    for ([_][]const u8{
        "mysql://u:p@h/db?",
        "mysql://u:p@h/db?ssl-ca",
        "mysql://u:p@h/db?ssl-ca=",
        "mysql://u:p@h/db?ssl-ca=relative.pem",
        "mysql://u:p@h/db?ssl-ca=..%2Fca.pem",
        "mysql://u:p@h/db?ssl-ca=%252Fca.pem",
        "mysql://u:p@h/db?ssl-ca=/ca.pem&ssl-ca=/other.pem",
        "mysql://u:p@h/db?ssl-ca=/ca.pem&other=x",
        "mysql://u:p@h/db?other=x&ssl-ca=/ca.pem",
        "mysql://u:p@h/db?ssl-ca=/ca.pem&",
        "mysql://u:p@h/db?ssl-ca=/ca.pem?ssl-ca=/other.pem",
        "mysql://u:p@h/db?ssl-ca=/ca.pem#fragment",
        "mysql://u:p@h/db?ssl-ca=/ca%00.pem",
        "mysql://u:p@h/db?ssl-ca=/ca%gg.pem",
        "mysql://u:p@h/db?ssl-ca=/ca%.pem",
        "mysql://u:p@h/db?SSL-CA=/ca.pem",
        "mysql://u:p@h/db?ssl%2Dca=/ca.pem",
        "mysql://u:p@h/db?ssl-mode=DISABLED",
        "mysql://u:p@h/db?verify=false",
        "mysql://u:p@%2Ftmp%2Fmysql.sock/db?ssl-ca=/ca.pem",
        "mysql://u:p@/tmp/mysql.sock/db?ssl-ca=/ca.pem",
    }) |text| try std.testing.expectError(error.InvalidMysqlUrl, create(std.testing.allocator, text));
}

test "mysql launch URLs bound the decoded ssl-ca path to the TLS loader limit" {
    const prefix = "mysql://u:p@h/db?ssl-ca=/";
    const longest = prefix ++ @as([std.posix.PATH_MAX - 2]u8, @splat('a'));
    const url = try create(std.testing.allocator, longest);
    defer url.destroy();
    try std.testing.expectEqual(@as(usize, std.posix.PATH_MAX - 1), url.ca_file.len);
    try std.testing.expectError(error.InvalidMysqlUrl, create(std.testing.allocator, longest ++ "a"));
}

test "mysql launch URLs percent-decode ssl-ca filename punctuation only once" {
    const url = try create(std.testing.allocator, "mysql://u:p@h/db?ssl-ca=%2Fca%20%26%3F%23%25%3D.pem");
    defer url.destroy();
    try std.testing.expectEqualStrings("/ca &?#%=.pem", url.options().address.tcp_tls.trust.ca_file);
}

// The allocating adapter must preserve the core's OS-byte path domain all the
// way to the transport, including after login credentials have been wiped.
test "mysql launch URL transport paths preserve every non-NUL decoded byte" {
    inline for (.{ true, false }) |socket| {
        for (1..256) |number| {
            const byte: u8 = @intCast(number);
            const hex = std.fmt.bytesToHex([_]u8{byte}, .lower);
            var encoded: [128]u8 = undefined;
            const text = try std.fmt.bufPrint(&encoded, if (socket) "mysql://u:secret@%2Ftmp%2Fpath%{s}/db" else "mysql://u:secret@host/db?ssl-ca=%2Ftmp%2Fpath%{s}", .{hex});
            const url = try create(std.testing.allocator, text);
            defer url.destroy();
            var expected: [32]u8 = undefined;
            const path = try std.fmt.bufPrint(&expected, "/tmp/path{c}", .{byte});
            try std.testing.expectEqualStrings(path, if (socket) url.options().address.unix_socket else url.options().address.tcp_tls.trust.ca_file);
            url.wipe();
            try std.testing.expectEqualStrings(path, if (socket) url.options().address.unix_socket else url.options().address.tcp_tls.trust.ca_file);
            try std.testing.expectEqualStrings("", url.options().password);
            for (url.password.bytes) |secret_byte| try std.testing.expectEqual(@as(u8, 0), secret_byte);
        }
        try std.testing.expectError(error.InvalidMysqlUrl, create(std.testing.allocator, if (socket) "mysql://u:p@%2Ftmp%2Fpath%00/db" else "mysql://u:p@host/db?ssl-ca=%2Ftmp%2Fpath%00"));
    }
}
