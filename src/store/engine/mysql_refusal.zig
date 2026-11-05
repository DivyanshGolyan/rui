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
pub const StartError = error{ UnsupportedMysqlVersion, MysqlReadOnly, MysqlDurabilityTooWeak, MysqlStatementBinlog };

pub fn refusal(facts: Facts) ?StartError {
    if (containsMaria(facts.server_version) or containsMaria(facts.version_comment)) return error.UnsupportedMysqlVersion;
    var parts = std.mem.splitScalar(u8, facts.server_version, '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse return error.UnsupportedMysqlVersion, 10) catch return error.UnsupportedMysqlVersion;
    const minor = std.fmt.parseInt(u32, parts.next() orelse return error.UnsupportedMysqlVersion, 10) catch return error.UnsupportedMysqlVersion;
    if (major < 8 or (major == 8 and minor < 4)) return error.UnsupportedMysqlVersion;
    if (facts.read_only or facts.super_read_only) return error.MysqlReadOnly;
    if (facts.innodb_flush_log_at_trx_commit != 1 or (facts.log_bin and facts.sync_binlog != 1)) return error.MysqlDurabilityTooWeak;
    if (std.ascii.eqlIgnoreCase(facts.binlog_format, "STATEMENT")) return error.MysqlStatementBinlog;
    return null;
}

fn containsMaria(text: []const u8) bool {
    const needle = "mariadb";
    if (text.len < needle.len) return false;
    for (0..text.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(text[i..][0..needle.len], needle)) return true;
    return false;
}

test "store.mysql refusal exhausts durability and replica combinations" {
    for (0..2) |read_only| for (0..2) |super_read_only| for (0..3) |flush| for (0..3) |sync| for (0..2) |bin| for ([_][]const u8{ "ROW", "MIXED", "STATEMENT" }) |format| {
        const facts: Facts = .{ .server_version = "8.4.3", .version_comment = "MySQL Community Server - GPL", .read_only = read_only != 0, .super_read_only = super_read_only != 0, .innodb_flush_log_at_trx_commit = flush, .sync_binlog = sync, .log_bin = bin != 0, .binlog_format = format };
        const expected: ?StartError = if (read_only != 0 or super_read_only != 0) error.MysqlReadOnly else if (flush != 1 or (bin != 0 and sync != 1)) error.MysqlDurabilityTooWeak else if (std.mem.eql(u8, format, "STATEMENT")) error.MysqlStatementBinlog else null;
        try std.testing.expectEqual(expected, refusal(facts));
    };
}

test "store.mysql refusal requires MySQL 8.4 and excludes MariaDB" {
    var facts: Facts = .{ .server_version = "8.4.0", .version_comment = "MySQL", .read_only = false, .super_read_only = false, .innodb_flush_log_at_trx_commit = 1, .sync_binlog = 1, .log_bin = true, .binlog_format = "ROW" };
    for ([_][]const u8{ "5.7.44", "8.0.40", "8.3.0", "garbage", "8", "10.11.0-MariaDB" }) |version| {
        facts.server_version = version;
        try std.testing.expectEqual(@as(?StartError, error.UnsupportedMysqlVersion), refusal(facts));
    }
    for ([_][]const u8{ "8.4.0", "8.4.3-commercial", "9.0.1" }) |version| {
        facts.server_version = version;
        try std.testing.expectEqual(@as(?StartError, null), refusal(facts));
    }
    facts.version_comment = "MariaDB Server";
    try std.testing.expectEqual(@as(?StartError, error.UnsupportedMysqlVersion), refusal(facts));
}

test "store.mysql doublewrite is diagnostic only" {
    for ([_][]const u8{ "ON", "OFF", "DETECT_ONLY", "DETECT_AND_RECOVER" }) |doublewrite| {
        const facts: Facts = .{ .server_version = "8.4.3", .version_comment = "MySQL", .read_only = false, .super_read_only = false, .innodb_flush_log_at_trx_commit = 1, .sync_binlog = 1, .log_bin = true, .binlog_format = "ROW", .doublewrite = doublewrite };
        try std.testing.expectEqual(@as(?StartError, null), refusal(facts));
    }
}
