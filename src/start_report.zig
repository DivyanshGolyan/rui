//! Start failures as owned values, independent of document intake and I/O.
const std = @import("std");
const bounded = @import("bounded.zig");

pub const max_refusal_message_bytes = 256;
/// Every diagnostic byte may need a six-byte JSON escape.
pub const max_line_bytes = 6 * max_refusal_message_bytes + 128;
pub const Store = enum { sqlite, mysql };

/// A refusal at open, as `RuiStartError.code` names it (D136).
pub const StartError = enum {
    settings_invalid,
    invalid_preset,
    store_locked,
    store_schema_missing,
    store_schema_behind,
    mysql_version,
    mariadb,
    read_only_replica,
    durability_innodb_flush_log_at_trx_commit,
    durability_sync_binlog,
    binlog_statement,
    mysql_unreachable,
    mysql_login,
    store_fenced,
    runtime_dir_unusable,
    tool_name_collision,
};

/// Owns its message, including formatted startup scratch, across copies.
pub const Failure = struct {
    code: StartError,
    message: bounded.Bounded(max_refusal_message_bytes),

    /// Producers supply bounded UTF-8 diagnostics, never secrets or server text.
    pub fn init(code: StartError, message: []const u8) Failure {
        var failure: Failure = .{ .code = code, .message = .{ .len = 0 } };
        failure.message.set(message) catch unreachable;
        return failure;
    }
};

/// Renders into caller-owned storage; the returned slice borrows that buffer.
pub fn line(failure: *const Failure, buffer: *[max_line_bytes]u8) []const u8 {
    var out = std.Io.Writer.fixed(buffer);
    out.writeAll("{\"rui_start_error\":{\"code\":\"") catch unreachable;
    out.writeAll(@tagName(failure.code)) catch unreachable;
    out.writeAll("\",\"message\":") catch unreachable;
    std.json.Stringify.encodeJsonString(failure.message.slice(), .{}, &out) catch unreachable;
    out.writeAll("}}\n") catch unreachable;
    return out.buffered();
}

/// Only static messages cross the refusal boundary: never server text or URL.
pub fn classify(store: Store, err: anyerror) ?Failure {
    if (store == .mysql) if (mysqlRefusal(err)) |refusal| return refusal;
    return switch (err) {
        error.StoreAlreadyOwned => .init(.store_locked, "another Host owns this Store"),
        error.RuntimeDirectoryInUse => .init(.runtime_dir_unusable, "another Host owns this runtimeDir"),
        error.RuntimeDirectoryUnusable => .init(.runtime_dir_unusable, "runtimeDir must be a private (mode 0700) directory this Host can lock"),
        else => null,
    };
}

fn mysqlRefusal(err: anyerror) ?Failure {
    return switch (err) {
        error.StoreLocked => .init(.store_locked, "another Host owns this Store"),
        error.StoreSchemaMissing => .init(.store_schema_missing, "apply this build's MySQL schema before starting the Host"),
        error.StoreSchemaBehind => .init(.store_schema_behind, "the MySQL Store format is older than this build; apply its forward migrations"),
        error.StoreSchemaAhead => .init(.store_schema_behind, "the MySQL Store format is newer than this build; use a compatible build"),
        error.MalformedStoreFormat => .init(.store_schema_behind, "the MySQL Store format metadata is not a valid number"),
        error.WrongStoreSchema => .init(.store_schema_behind, "the MySQL Store metadata contains an unexpected key"),
        error.StoreCatalogMismatch => .init(.store_schema_behind, "the MySQL Store catalog does not match this build"),
        error.WrongStoreIdentity => .init(.store_schema_behind, "the MySQL Store identity metadata or connection target is invalid"),
        error.MysqlTooOld, error.UnsupportedServer => .init(.mysql_version, "MySQL 8.4 or newer is required"),
        error.MysqlIsMariadb => .init(.mariadb, "MariaDB is not supported; use MySQL 8.4 or newer"),
        error.MysqlReadOnly => .init(.read_only_replica, "MySQL requires read_only=OFF and super_read_only=OFF"),
        error.MysqlFlushLogUnsafe => .init(.durability_innodb_flush_log_at_trx_commit, "MySQL requires innodb_flush_log_at_trx_commit=1"),
        error.MysqlSyncBinlogUnsafe => .init(.durability_sync_binlog, "MySQL requires sync_binlog=1 when binlogging is enabled"),
        error.MysqlStatementBinlog => .init(.binlog_statement, "MySQL STATEMENT binlogging is not supported; use ROW or MIXED"),
        error.ServerRefused => .init(.mysql_unreachable, "the MySQL server refused the connection before login"),
        error.ConnectFailed => .init(.mysql_unreachable, "could not connect to the MySQL server"),
        error.HostNotFound => .init(.mysql_unreachable, "could not resolve the MySQL host"),
        error.InvalidHost => .init(.mysql_unreachable, "the MySQL host address is invalid"),
        error.InvalidCaFile => .init(.mysql_unreachable, "could not load the MySQL ssl-ca file"),
        error.TrustUnavailable, error.InvalidSslCertFile, error.InvalidSslCertDir => .init(.mysql_unreachable, "could not load MySQL system TLS trust"),
        error.TlsRefused => .init(.mysql_unreachable, "the MySQL server does not offer TLS"),
        error.TlsFailed => .init(.mysql_unreachable, "the MySQL server's TLS handshake failed"),
        error.UntrustedPeer => .init(.mysql_unreachable, "the MySQL server's TLS certificate is not trusted"),
        error.PeerFailed => .init(.mysql_unreachable, "could not verify the MySQL server's TLS certificate"),
        error.DeadlineExceeded => .init(.mysql_unreachable, "timed out connecting to the MySQL server"),
        error.ConnectionLost => .init(.mysql_unreachable, "the MySQL connection was lost during startup"),
        error.LoginRefused, error.AuthMethodRefused => .init(.mysql_login, "the MySQL server refused the login or the login lacks a privilege the Store needs; check credentials and SELECT, INSERT, UPDATE privileges on the database"),
        else => null,
    };
}

test "a launched Host's start failure is refused with its Store's codes only" {
    const cases = [_]struct { store: Store, err: anyerror, code: ?StartError }{
        .{ .store = .sqlite, .err = error.StoreAlreadyOwned, .code = .store_locked },
        .{ .store = .mysql, .err = error.StoreAlreadyOwned, .code = .store_locked },
        .{ .store = .mysql, .err = error.StoreLocked, .code = .store_locked },
        .{ .store = .sqlite, .err = error.StoreLocked, .code = null },
        .{ .store = .mysql, .err = error.StoreSchemaMissing, .code = .store_schema_missing },
        .{ .store = .sqlite, .err = error.StoreSchemaMissing, .code = null },
        .{ .store = .sqlite, .err = error.RuntimeDirectoryInUse, .code = .runtime_dir_unusable },
        .{ .store = .mysql, .err = error.RuntimeDirectoryUnusable, .code = .runtime_dir_unusable },
        .{ .store = .sqlite, .err = error.OutOfMemory, .code = null },
    };
    for (cases) |case| {
        const refusal = classify(case.store, case.err);
        try std.testing.expectEqual(case.code, if (refusal) |value| value.code else null);
    }
    try std.testing.expect(!std.mem.eql(u8, classify(.sqlite, error.RuntimeDirectoryInUse).?.message.slice(), classify(.sqlite, error.RuntimeDirectoryUnusable).?.message.slice()));
    const mysql_cases = [_]struct { err: anyerror, code: StartError }{
        .{ .err = error.MysqlTooOld, .code = .mysql_version },
        .{ .err = error.UnsupportedServer, .code = .mysql_version },
        .{ .err = error.MysqlIsMariadb, .code = .mariadb },
        .{ .err = error.MysqlReadOnly, .code = .read_only_replica },
        .{ .err = error.MysqlFlushLogUnsafe, .code = .durability_innodb_flush_log_at_trx_commit },
        .{ .err = error.MysqlSyncBinlogUnsafe, .code = .durability_sync_binlog },
        .{ .err = error.MysqlStatementBinlog, .code = .binlog_statement },
        .{ .err = error.ServerRefused, .code = .mysql_unreachable },
        .{ .err = error.ConnectFailed, .code = .mysql_unreachable },
        .{ .err = error.HostNotFound, .code = .mysql_unreachable },
        .{ .err = error.InvalidHost, .code = .mysql_unreachable },
        .{ .err = error.InvalidCaFile, .code = .mysql_unreachable },
        .{ .err = error.TrustUnavailable, .code = .mysql_unreachable },
        .{ .err = error.InvalidSslCertFile, .code = .mysql_unreachable },
        .{ .err = error.InvalidSslCertDir, .code = .mysql_unreachable },
        .{ .err = error.TlsRefused, .code = .mysql_unreachable },
        .{ .err = error.TlsFailed, .code = .mysql_unreachable },
        .{ .err = error.UntrustedPeer, .code = .mysql_unreachable },
        .{ .err = error.PeerFailed, .code = .mysql_unreachable },
        .{ .err = error.DeadlineExceeded, .code = .mysql_unreachable },
        .{ .err = error.ConnectionLost, .code = .mysql_unreachable },
        .{ .err = error.LoginRefused, .code = .mysql_login },
        .{ .err = error.AuthMethodRefused, .code = .mysql_login },
    };
    for (mysql_cases) |case| {
        try std.testing.expect(classify(.mysql, case.err) != null);
        const refusal = classify(.mysql, case.err).?;
        try std.testing.expectEqual(case.code, refusal.code);
        try std.testing.expect(refusal.message.slice().len > 0 and refusal.message.slice().len <= max_refusal_message_bytes);
        try std.testing.expect(classify(.sqlite, case.err) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, mysqlRefusal(error.MysqlFlushLogUnsafe).?.message.slice(), "innodb_flush_log_at_trx_commit=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, mysqlRefusal(error.MysqlSyncBinlogUnsafe).?.message.slice(), "sync_binlog=1") != null);
    try std.testing.expectEqualStrings("the MySQL server refused the connection before login", mysqlRefusal(error.ServerRefused).?.message.slice());
    try std.testing.expect(std.mem.indexOf(u8, mysqlRefusal(error.LoginRefused).?.message.slice(), "SELECT, INSERT, UPDATE") != null);
    try std.testing.expect(!std.mem.eql(u8, mysqlRefusal(error.HostNotFound).?.message.slice(), mysqlRefusal(error.ConnectFailed).?.message.slice()));
    try std.testing.expect(!std.mem.eql(u8, mysqlRefusal(error.UntrustedPeer).?.message.slice(), mysqlRefusal(error.TlsFailed).?.message.slice()));
}

test "MySQL metadata admission failures have distinct bounded static diagnostics" {
    const cases = .{
        .{ error.StoreSchemaBehind, "the MySQL Store format is older than this build; apply its forward migrations" },
        .{ error.StoreSchemaAhead, "the MySQL Store format is newer than this build; use a compatible build" },
        .{ error.MalformedStoreFormat, "the MySQL Store format metadata is not a valid number" },
        .{ error.WrongStoreSchema, "the MySQL Store metadata contains an unexpected key" },
        .{ error.StoreCatalogMismatch, "the MySQL Store catalog does not match this build" },
        .{ error.WrongStoreIdentity, "the MySQL Store identity metadata or connection target is invalid" },
    };
    inline for (cases) |case| {
        const refusal = classify(.mysql, case[0]).?;
        try std.testing.expectEqual(StartError.store_schema_behind, refusal.code);
        try std.testing.expectEqualStrings(case[1], refusal.message.slice());
        try std.testing.expect(refusal.message.slice().len <= max_refusal_message_bytes);
        try std.testing.expect(classify(.sqlite, case[0]) == null);
    }
}

test "start report renders every StartError as the exact JSON line" {
    inline for (comptime std.meta.tags(StartError)) |code| {
        const failure: Failure = .init(code, "message");
        var buffer: [max_line_bytes]u8 = undefined;
        const rendered = line(&failure, &buffer);
        try std.testing.expectEqualStrings("{\"rui_start_error\":{\"code\":\"" ++ @tagName(code) ++ "\",\"message\":\"message\"}}\n", rendered);
        const parsed = try std.json.parseFromSlice(struct {
            rui_start_error: struct { code: []const u8, message: []const u8 },
        }, std.testing.allocator, rendered, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(@tagName(code), parsed.value.rui_start_error.code);
        try std.testing.expectEqualStrings("message", parsed.value.rui_start_error.message);
    }
}

test "start report owns formatted bytes across source and value mutation" {
    var source: [max_refusal_message_bytes]u8 = undefined;
    const message = try std.fmt.bufPrint(&source, "tool name {s} is offered by {s} and by {s}", .{ "bash", "Rui", "docs" });
    var original: Failure = .init(.tool_name_collision, message);
    const copied = original;
    @memset(&source, 'x');
    original = .init(.settings_invalid, "changed");
    var buffer: [max_line_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("{\"rui_start_error\":{\"code\":\"tool_name_collision\",\"message\":\"tool name bash is offered by Rui and by docs\"}}\n", line(&copied, &buffer));
}

test "start report preserves JSON escaping and the maximum message" {
    const escaped: Failure = .init(.invalid_preset, "preset \"x\"\\\n\t\r\x00: café");
    var buffer: [max_line_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("{\"rui_start_error\":{\"code\":\"invalid_preset\",\"message\":\"preset \\\"x\\\"\\\\\\n\\t\\r\\u0000: café\"}}\n", line(&escaped, &buffer));
    // Every byte needs the longest JSON escape, with the longest code.
    const full: Failure = .init(.durability_innodb_flush_log_at_trx_commit, &@as([max_refusal_message_bytes]u8, @splat(0)));
    const rendered = line(&full, &buffer);
    const prefix = "{\"rui_start_error\":{\"code\":\"durability_innodb_flush_log_at_trx_commit\",\"message\":\"";
    try std.testing.expect(std.mem.startsWith(u8, rendered, prefix));
    try std.testing.expectEqualStrings("\"}}\n", rendered[prefix.len + 6 * max_refusal_message_bytes ..]);
    for (0..max_refusal_message_bytes) |i| try std.testing.expectEqualStrings("\\u0000", rendered[prefix.len + 6 * i ..][0..6]);
}

// Independent expectations from the original startup classifier at the merge.
test "start report classifier preserves every refusal code and message byte" {
    const cases = .{
        .{ error.StoreAlreadyOwned, StartError.store_locked, "another Host owns this Store", false },
        .{ error.RuntimeDirectoryInUse, StartError.runtime_dir_unusable, "another Host owns this runtimeDir", false },
        .{ error.RuntimeDirectoryUnusable, StartError.runtime_dir_unusable, "runtimeDir must be a private (mode 0700) directory this Host can lock", false },
        .{ error.StoreLocked, StartError.store_locked, "another Host owns this Store", true },
        .{ error.StoreSchemaMissing, StartError.store_schema_missing, "apply this build's MySQL schema before starting the Host", true },
        .{ error.StoreSchemaBehind, StartError.store_schema_behind, "the MySQL Store format is older than this build; apply its forward migrations", true },
        .{ error.StoreSchemaAhead, StartError.store_schema_behind, "the MySQL Store format is newer than this build; use a compatible build", true },
        .{ error.MalformedStoreFormat, StartError.store_schema_behind, "the MySQL Store format metadata is not a valid number", true },
        .{ error.WrongStoreSchema, StartError.store_schema_behind, "the MySQL Store metadata contains an unexpected key", true },
        .{ error.StoreCatalogMismatch, StartError.store_schema_behind, "the MySQL Store catalog does not match this build", true },
        .{ error.WrongStoreIdentity, StartError.store_schema_behind, "the MySQL Store identity metadata or connection target is invalid", true },
        .{ error.MysqlTooOld, StartError.mysql_version, "MySQL 8.4 or newer is required", true },
        .{ error.UnsupportedServer, StartError.mysql_version, "MySQL 8.4 or newer is required", true },
        .{ error.MysqlIsMariadb, StartError.mariadb, "MariaDB is not supported; use MySQL 8.4 or newer", true },
        .{ error.MysqlReadOnly, StartError.read_only_replica, "MySQL requires read_only=OFF and super_read_only=OFF", true },
        .{ error.MysqlFlushLogUnsafe, StartError.durability_innodb_flush_log_at_trx_commit, "MySQL requires innodb_flush_log_at_trx_commit=1", true },
        .{ error.MysqlSyncBinlogUnsafe, StartError.durability_sync_binlog, "MySQL requires sync_binlog=1 when binlogging is enabled", true },
        .{ error.MysqlStatementBinlog, StartError.binlog_statement, "MySQL STATEMENT binlogging is not supported; use ROW or MIXED", true },
        .{ error.ServerRefused, StartError.mysql_unreachable, "the MySQL server refused the connection before login", true },
        .{ error.ConnectFailed, StartError.mysql_unreachable, "could not connect to the MySQL server", true },
        .{ error.HostNotFound, StartError.mysql_unreachable, "could not resolve the MySQL host", true },
        .{ error.InvalidHost, StartError.mysql_unreachable, "the MySQL host address is invalid", true },
        .{ error.InvalidCaFile, StartError.mysql_unreachable, "could not load the MySQL ssl-ca file", true },
        .{ error.TrustUnavailable, StartError.mysql_unreachable, "could not load MySQL system TLS trust", true },
        .{ error.InvalidSslCertFile, StartError.mysql_unreachable, "could not load MySQL system TLS trust", true },
        .{ error.InvalidSslCertDir, StartError.mysql_unreachable, "could not load MySQL system TLS trust", true },
        .{ error.TlsRefused, StartError.mysql_unreachable, "the MySQL server does not offer TLS", true },
        .{ error.TlsFailed, StartError.mysql_unreachable, "the MySQL server's TLS handshake failed", true },
        .{ error.UntrustedPeer, StartError.mysql_unreachable, "the MySQL server's TLS certificate is not trusted", true },
        .{ error.PeerFailed, StartError.mysql_unreachable, "could not verify the MySQL server's TLS certificate", true },
        .{ error.DeadlineExceeded, StartError.mysql_unreachable, "timed out connecting to the MySQL server", true },
        .{ error.ConnectionLost, StartError.mysql_unreachable, "the MySQL connection was lost during startup", true },
        .{ error.LoginRefused, StartError.mysql_login, "the MySQL server refused the login or the login lacks a privilege the Store needs; check credentials and SELECT, INSERT, UPDATE privileges on the database", true },
        .{ error.AuthMethodRefused, StartError.mysql_login, "the MySQL server refused the login or the login lacks a privilege the Store needs; check credentials and SELECT, INSERT, UPDATE privileges on the database", true },
    };
    inline for (cases) |case| {
        inline for (.{ Store.sqlite, Store.mysql }) |store| {
            const refusal = classify(store, case[0]);
            if (case[3] and store == .sqlite) {
                try std.testing.expect(refusal == null);
            } else {
                try std.testing.expectEqual(case[1], refusal.?.code);
                try std.testing.expectEqualStrings(case[2], refusal.?.message.slice());
            }
        }
    }
    inline for (.{ Store.sqlite, Store.mysql }) |store| {
        try std.testing.expect(classify(store, error.OutOfMemory) == null);
    }
}
