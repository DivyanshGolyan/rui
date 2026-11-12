//! Pure admission policy. Doublewrite is diagnostic, not an admission gate.
const std = @import("std");

pub const Facts = struct {
    server_version: []const u8,
    version_comment: []const u8,
    read_only: bool,
    super_read_only: bool,
    innodb_flush_log_at_trx_commit: u64,
    sync_binlog: u64,
    log_bin: bool,
    binlog_format: []const u8,
    doublewrite: []const u8 = "ON",
};
const version_policy = @import("../../store/wire/mysql.zig");
pub const VersionError = version_policy.VersionError;
pub const StartError = VersionError || error{ MysqlReadOnly, MysqlFlushLogUnsafe, MysqlSyncBinlogUnsafe, MysqlStatementBinlog };

pub fn refusal(facts: Facts) ?StartError {
    if (version_policy.versionRefusal(facts.server_version, facts.version_comment)) |err| return err;
    // D222: version/MariaDB, replica, flush_log, sync_binlog, then format.
    if (facts.read_only or facts.super_read_only) return error.MysqlReadOnly;
    if (facts.innodb_flush_log_at_trx_commit != 1) return error.MysqlFlushLogUnsafe;
    if (facts.log_bin and facts.sync_binlog != 1) return error.MysqlSyncBinlogUnsafe;
    if (std.ascii.eqlIgnoreCase(facts.binlog_format, "STATEMENT")) return error.MysqlStatementBinlog;
    return null;
}

test "store.mysql refusal exhausts version, durability and replica combinations" {
    const versions = [_]struct { server_version: []const u8, comment: []const u8 = "MySQL", err: ?VersionError = null }{
        .{ .server_version = "8.4.0" },
        .{ .server_version = "8.4.13-commercial" },
        .{ .server_version = "9.0.1" },
        .{ .server_version = "5.7.44", .err = error.MysqlTooOld },
        .{ .server_version = "8.0.40", .err = error.MysqlTooOld },
        .{ .server_version = "8.3.0", .err = error.MysqlTooOld },
        .{ .server_version = "garbage", .err = error.MysqlTooOld },
        .{ .server_version = "8", .err = error.MysqlTooOld },
        .{ .server_version = "", .err = error.MysqlTooOld },
        .{ .server_version = "+9.1.0", .err = error.MysqlTooOld },
        .{ .server_version = "8.0_4.0", .err = error.MysqlTooOld },
        .{ .server_version = "8..0", .err = error.MysqlTooOld },
        .{ .server_version = "4294967296.4.0", .err = error.MysqlTooOld },
        .{ .server_version = "5.5.5-10.11.0-MariaDB", .err = error.MysqlIsMariadb },
        .{ .server_version = "10.11.0-mArIaDb", .err = error.MysqlIsMariadb },
        .{ .server_version = "8.4.0", .comment = "MariaDB Server", .err = error.MysqlIsMariadb },
        .{ .server_version = "garbage", .comment = "mariadb", .err = error.MysqlIsMariadb },
    };
    for (versions) |version| for (0..2) |read_only| for (0..2) |super_read_only| for (0..3) |flush| for (0..3) |sync| for (0..2) |bin| for ([_][]const u8{ "ROW", "MIXED", "STATEMENT", "statement" }) |format| {
        const facts: Facts = .{ .server_version = version.server_version, .version_comment = version.comment, .read_only = read_only != 0, .super_read_only = super_read_only != 0, .innodb_flush_log_at_trx_commit = flush, .sync_binlog = sync, .log_bin = bin != 0, .binlog_format = format };
        const expected: ?StartError = if (version.err) |err| err else if (read_only != 0 or super_read_only != 0) error.MysqlReadOnly else if (flush != 1) error.MysqlFlushLogUnsafe else if (bin != 0 and sync != 1) error.MysqlSyncBinlogUnsafe else if (std.ascii.eqlIgnoreCase(format, "STATEMENT")) error.MysqlStatementBinlog else null;
        try std.testing.expectEqual(expected, refusal(facts));
    };
}

test "store.mysql doublewrite is diagnostic only" {
    for ([_][]const u8{ "ON", "OFF", "DETECT_ONLY", "DETECT_AND_RECOVER" }) |doublewrite| {
        const facts: Facts = .{ .server_version = "8.4.3", .version_comment = "MySQL", .read_only = false, .super_read_only = false, .innodb_flush_log_at_trx_commit = 1, .sync_binlog = 1, .log_bin = true, .binlog_format = "ROW", .doublewrite = doublewrite };
        try std.testing.expectEqual(@as(?StartError, null), refusal(facts));
    }
}
