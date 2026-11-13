//! Allocation-free MySQL URL values and validation.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const mysql = @import("store/wire/mysql.zig");

/// Caller-owned parsed fields. Slices borrow this storage until parse or wipe.
pub fn ValueWith(comptime ca_file_bytes: usize) type {
    return struct {
        const Value = @This();
        pub const default_port: u16 = 3306;
        user: Bounded(mysql.max_user_bytes) = .{},
        password: Bounded(mysql.max_password_bytes) = .{},
        host: Bounded(253) = .{},
        socket: Bounded(107) = .{},
        database: Bounded(64) = .{},
        // Same path bound as the provider launch frame and TLS loader.
        ca_file: Bounded(ca_file_bytes) = .{},
        port: u16 = default_port,

        /// Replace the previous value; an invalid URL leaves all fields wiped.
        pub fn parse(self: *Value, text: []const u8) error{InvalidMysqlUrl}!void {
            self.wipe();
            errdefer self.wipe();
            try parseInto(self, text);
        }

        /// Erase credentials and every other retained field, including unused bytes.
        pub fn wipe(self: *Value) void {
            std.crypto.secureZero(u8, std.mem.asBytes(self));
            self.port = default_port;
        }
    };
}

/// Parse into fresh, field-compatible storage owned by an adapter.
pub fn parseInto(self: anytype, text: []const u8) error{InvalidMysqlUrl}!void {
    if (!std.mem.startsWith(u8, text, "mysql://") or std.mem.indexOfAny(u8, text, "#\r\n\x00") != null) return error.InvalidMysqlUrl;
    const query_start = std.mem.indexOfScalar(u8, text, '?') orelse text.len;
    if (query_start != text.len) {
        const query = text[query_start + 1 ..];
        const key = "ssl-ca=";
        if (!std.mem.startsWith(u8, query, key) or std.mem.indexOfAny(u8, query, "&?") != null) return error.InvalidMysqlUrl;
        try decode(&self.ca_file, query[key.len..], true);
        if (self.ca_file.len == 0 or !std.fs.path.isAbsolute(self.ca_file.slice())) return error.InvalidMysqlUrl;
    }
    const rest = text["mysql://".len..query_start];
    const at = std.mem.indexOfScalar(u8, rest, '@') orelse return error.InvalidMysqlUrl;
    const colon = std.mem.indexOfScalar(u8, rest[0..at], ':') orelse return error.InvalidMysqlUrl;
    try decode(&self.user, rest[0..colon], false);
    try decode(&self.password, rest[colon + 1 .. at], false);
    if (self.user.len == 0) return error.InvalidMysqlUrl;
    const target = rest[at + 1 ..];
    const slash = std.mem.lastIndexOfScalar(u8, target, '/') orelse return error.InvalidMysqlUrl;
    const address = target[0..slash];
    try decode(&self.database, target[slash + 1 ..], false);
    if (address.len == 0 or self.database.len == 0 or std.mem.indexOfScalar(u8, self.database.slice(), '/') != null) return error.InvalidMysqlUrl;
    if (address[0] == '/' or std.mem.startsWith(u8, address, "%2F") or std.mem.startsWith(u8, address, "%2f")) {
        if (self.ca_file.len != 0) return error.InvalidMysqlUrl;
        try decode(&self.socket, address, true);
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
    try decode(&self.host, hostname, false);
    if (self.host.len == 0 or std.mem.indexOfAny(u8, self.host.slice(), "/@[] ") != null) return error.InvalidMysqlUrl;
    if (port) |digits| {
        if (digits.len == 0) return error.InvalidMysqlUrl;
        for (digits) |digit| if (!std.ascii.isDigit(digit)) return error.InvalidMysqlUrl;
        self.port = std.fmt.parseInt(u16, digits, 10) catch return error.InvalidMysqlUrl;
        if (self.port == 0) return error.InvalidMysqlUrl;
    }
}

fn decode(out: anytype, text: []const u8, comptime os_path: bool) error{InvalidMysqlUrl}!void {
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
        if (byte == 0 or (!os_path and (byte < 0x20 or byte == 0x7f)) or out.len == out.bytes.len) return error.InvalidMysqlUrl;
        out.bytes[out.len] = byte;
        out.len += 1;
        at += 1;
    }
    if (!os_path and !std.unicode.utf8ValidateSlice(out.slice())) return error.InvalidMysqlUrl;
}

test "mysql URL value parses TLS and socket targets and replaces prior fields" {
    const Value = ValueWith(@import("host_settings.zig").max_ca_file_bytes);
    var value: Value = .{};
    defer value.wipe();
    try value.parse("mysql://u%40ser:p%3Ass@[::1]:3307/db?ssl-ca=%2Fca.pem");
    try std.testing.expectEqualStrings("u@ser", value.user.slice());
    try std.testing.expectEqualStrings("p:ss", value.password.slice());
    try std.testing.expectEqualStrings("::1", value.host.slice());
    try std.testing.expectEqualStrings("/ca.pem", value.ca_file.slice());
    try std.testing.expectEqual(@as(u16, 3307), value.port);
    try value.parse("mysql://u:@%2Ftmp%2Fmysql.sock/db");
    try std.testing.expectEqualStrings("/tmp/mysql.sock", value.socket.slice());
    try std.testing.expectEqual(@as(usize, 0), value.host.len);
    try std.testing.expectEqual(@as(usize, 0), value.ca_file.len);
    try std.testing.expectEqual(@as(u16, 3306), value.port);
}

test "mysql URL value rejects malformed values and wipes partial secrets" {
    const Value = ValueWith(@import("host_settings.zig").max_ca_file_bytes);
    var value: Value = .{};
    for ([_][]const u8{
        "",                        "https://u:p@h/d",                 "mysql://u:p@h",                 "mysql://:p@h/d",
        "mysql://u:p@h:0/d",       "mysql://u:p@h:65536/d",           "mysql://u:p@h:+1/d",            "mysql://u:p@[::1/d",
        "mysql://u:p@h/d%2Fother", "mysql://u:p@h/d#x",               "mysql://u:%00@h/d",             "mysql://u:%ff@h/d",
        "mysql://u:%gg@h/d",       "mysql://u:p@h/d?ssl-ca=relative", "mysql://u:p@h/d?ssl-ca=/a&x=y", "mysql://u:p@/tmp/mysql.sock/d?ssl-ca=/a",
    }) |text| {
        try std.testing.expectError(error.InvalidMysqlUrl, value.parse(text));
        for (value.password.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        try std.testing.expectEqual(@as(usize, 0), value.password.len);
        try std.testing.expectEqual(@as(usize, 0), value.user.len);
    }
}

test "mysql URL value enforces every decoded field bound" {
    const Value = ValueWith(@import("host_settings.zig").max_ca_file_bytes);
    var value: Value = .{};
    defer value.wipe();
    inline for (.{ "user", "password", "host", "socket", "database", "ca_file" }) |field| {
        const capacity = @typeInfo(@FieldType(@FieldType(Value, field), "bytes")).array.len;
        const prefix, const suffix = comptime if (std.mem.eql(u8, field, "user"))
            .{ "mysql://", ":p@h/d" }
        else if (std.mem.eql(u8, field, "password"))
            .{ "mysql://u:", "@h/d" }
        else if (std.mem.eql(u8, field, "host"))
            .{ "mysql://u:p@", "/d" }
        else if (std.mem.eql(u8, field, "socket"))
            .{ "mysql://u:p@/", "/d" }
        else if (std.mem.eql(u8, field, "database"))
            .{ "mysql://u:p@h/", "" }
        else
            .{ "mysql://u:p@h/d?ssl-ca=/", "" };
        const leading_slash = comptime std.mem.eql(u8, field, "socket") or std.mem.eql(u8, field, "ca_file");
        const text = prefix ++ @as([capacity - @as(usize, @intFromBool(leading_slash))]u8, @splat('a')) ++ suffix;
        try value.parse(text);
        try std.testing.expectEqual(capacity, @field(value, field).len);
        const too_long = prefix ++ @as([capacity + 1 - @as(usize, @intFromBool(leading_slash))]u8, @splat('a')) ++ suffix;
        try std.testing.expectError(error.InvalidMysqlUrl, value.parse(too_long));
    }
}

test "mysql URL value wipe erases every field buffer" {
    const Value = ValueWith(@import("host_settings.zig").max_ca_file_bytes);
    var value: Value = .{};
    try value.parse("mysql://user:secret@host/db?ssl-ca=/ca.pem");
    value.wipe();
    inline for (.{ "user", "password", "host", "socket", "database", "ca_file" }) |field| {
        try std.testing.expectEqual(@as(usize, 0), @field(value, field).len);
        for (@field(value, field).bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
    try std.testing.expectEqual(@as(u16, 3306), value.port);
}

test "mysql URL OS paths carry non-NUL bytes while names remain text" {
    var value: ValueWith(4095) = .{};
    defer value.wipe();
    try value.parse("mysql://u:p@/tmp/mysql%FF%0A.sock/db");
    try std.testing.expectEqualStrings("/tmp/mysql\xff\n.sock", value.socket.slice());
    try value.parse("mysql://u:p@localhost/db?ssl-ca=/tmp/ca%FF.pem");
    try std.testing.expectEqualStrings("/tmp/ca\xff.pem", value.ca_file.slice());
    try std.testing.expectError(error.InvalidMysqlUrl, value.parse("mysql://u:p@/tmp/socket%00/db"));
    try std.testing.expectError(error.InvalidMysqlUrl, value.parse("mysql://u:p@local%FFhost/db"));
}
