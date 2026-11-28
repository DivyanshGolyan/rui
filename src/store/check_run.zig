//! Runs the Store check statements against a SQLite Store file and says which rules its rows break.
//!
//! The file is opened read-only, so a check can never change a Store, and only when it holds this build's format:
//! another format has other tables, and a statement over them would fail or lie.
const std = @import("std");
const schema = @import("schema.zig");
const sqlite = @import("sqlite.zig");
const store_check = @import("store_check.zig");
const history = @import("history.zig");
const c = sqlite.c;

pub const Result = struct {
    /// Statements run: one per rule and reference.
    checked: usize = 0,
    /// Statements that counted at least one violating row.
    breaking: usize = 0,
    /// Violating rows over all statements; a row that breaks two rules counts twice.
    rows: u64 = 0,
};

/// How a check ended. Only a failed write to `out` or `refusal` is an error: everything about the Store is an outcome.
pub const Outcome = union(enum) {
    checked: Result,
    /// The file could not be opened read-only (missing, locked by a running Host, or needing WAL recovery).
    open_failed,
    /// The Store holds another format; `refusal` says which.
    format_mismatch,
    /// A statement did not run: the file is damaged or not a Rui Store.
    check_failed,
};

/// Writes `name<TAB>rows` for every rule or reference that has violators, in the catalog's order, to `out`.
pub fn checkSqlite(database_path: [:0]const u8, out: *std.Io.Writer, refusal: *std.Io.Writer) error{WriteFailed}!Outcome {
    var raw: ?*c.sqlite3 = null;
    defer _ = c.sqlite3_close(raw);
    if (c.sqlite3_open_v2(database_path, &raw, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_NOMUTEX, null) != c.SQLITE_OK) return .open_failed;
    const database = raw.?;
    const found = sqlite.pragmaInt(database, "PRAGMA user_version") catch return .open_failed;
    if (found != schema.schema_version) {
        try refusal.print("the Store is format {d} and this build checks format {d}; start the Host from this build to upgrade it first\n", .{ found, schema.schema_version });
        return .format_mismatch;
    }
    var result: Result = .{};
    for (comptime store_check.checks(.sqlite)) |check| {
        const statement = sqlite.prepare(database, check.sql) catch return .check_failed;
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return .check_failed;
        const rows = sqlite.readCount(statement, 0) catch return .check_failed;
        result.checked += 1;
        if (rows == 0) continue;
        result.breaking += 1;
        result.rows += rows;
        try out.print("{s}\t{d}\n", .{ check.name, rows });
    }
    return .{ .checked = result };
}

/// Every check statement of `dialect`, each under a `-- name` comment line, for a database team to run read-only through
/// its own client: the Host never connects to a MySQL Store for the check.
pub fn writeStatements(comptime dialect: @import("rsql.zig").Dialect, out: *std.Io.Writer) error{WriteFailed}!void {
    for (comptime store_check.checks(dialect)) |check| try out.print("-- {s}\n{s};\n", .{ check.name, check.sql });
}

pub const broken_row_lines = "content_part.ordinal\t1\ncontent_part#0\t1\ncontent_part(content_id)->content\t1\ncontent_part(part_content_id)->content\t1\n";
const test_broken_row = "PRAGMA ignore_check_constraints=ON;PRAGMA foreign_keys=OFF;INSERT INTO content_part(content_id,ordinal,part_content_id) VALUES(5,-1,5)";

/// A Store file of `format` in `tmp`, with the row the check's tests break four rules with when `broken`.
pub fn storeFileForTesting(tmp: *std.testing.TmpDir, io: std.Io, format: u32, broken: bool) ![:0]u8 {
    var built = try history.build(io, .sqlite, tmp, &.{ .format = format, .baseline_rows = false });
    defer built.deinit();
    if (broken) try built.exec(test_broken_row);
    return std.fmt.allocPrintSentinel(std.testing.allocator, "{s}", .{built.path()}, 0);
}

test "SH-185 store check on a SQLite file reports each broken rule, refuses another format and leaves the file as it was" {
    const io = std.testing.io;
    var out_buffer: [1024]u8 = undefined;
    var refusal_buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    var refusal: std.Io.Writer = .fixed(&refusal_buffer);

    var clean_tmp = std.testing.tmpDir(.{});
    defer clean_tmp.cleanup();
    const clean = try storeFileForTesting(&clean_tmp, io, schema.schema_version, false);
    defer std.testing.allocator.free(clean);
    const none = (try checkSqlite(clean, &out, &refusal)).checked;
    try std.testing.expectEqual(comptime store_check.checks(.sqlite).len, none.checked);
    try std.testing.expectEqual(@as(usize, 0), none.breaking);
    try std.testing.expectEqualStrings("", out.buffered());

    var broken_tmp = std.testing.tmpDir(.{});
    defer broken_tmp.cleanup();
    const broken = try storeFileForTesting(&broken_tmp, io, schema.schema_version, true);
    defer std.testing.allocator.free(broken);
    out = .fixed(&out_buffer);
    const found = (try checkSqlite(broken, &out, &refusal)).checked;
    try std.testing.expectEqual(@as(usize, 4), found.breaking);
    try std.testing.expectEqual(@as(u64, 4), found.rows);
    try std.testing.expectEqualStrings(broken_row_lines, out.buffered());
    const before = try std.Io.Dir.cwd().readFileAlloc(io, broken, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(before);
    out = .fixed(&out_buffer);
    _ = try checkSqlite(broken, &out, &refusal);
    const after = try std.Io.Dir.cwd().readFileAlloc(io, broken, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);

    var older_tmp = std.testing.tmpDir(.{});
    defer older_tmp.cleanup();
    const older = try storeFileForTesting(&older_tmp, io, schema.schema_version - 1, true);
    defer std.testing.allocator.free(older);
    out = .fixed(&out_buffer);
    try std.testing.expectEqual(Outcome.format_mismatch, try checkSqlite(older, &out, &refusal));
    try std.testing.expectEqualStrings("", out.buffered());
    try std.testing.expect(std.mem.indexOf(u8, refusal.buffered(), "format") != null);

    try std.testing.expectEqual(Outcome.open_failed, try checkSqlite("/nonexistent/dir/none.sqlite3", &out, &refusal));
}

test "SH-187 store check for MySQL prints every statement under its rule's name and opens nothing" {
    var buffer: [512 * 1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try writeStatements(.mysql, &out);
    const text = out.buffered();
    const all = comptime store_check.checks(.mysql);
    var position: usize = 0;
    for (all) |check| {
        const header = std.mem.indexOfPos(u8, text, position, "-- ") orelse return error.TestUnexpectedResult;
        const line_end = std.mem.indexOfScalarPos(u8, text, header, '\n').?;
        try std.testing.expectEqualStrings(check.name, text[header + 3 .. line_end]);
        const statement_end = line_end + 1 + check.sql.len;
        try std.testing.expectEqualStrings(check.sql, text[line_end + 1 .. statement_end]);
        try std.testing.expectEqual(@as(u8, ';'), text[statement_end]);
        position = statement_end + 2;
    }
    try std.testing.expectEqual(text.len, position);
}
