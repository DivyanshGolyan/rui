//! Runs the Store check statements against a SQLite Store file and says which rules its rows break.
//!
//! The file is opened read-only, so a check can never change a Store, and only when it holds this build's format:
//! another format has other tables, and a statement over them would fail or lie.
const std = @import("std");
const schema = @import("schema.zig");
const sqlite = @import("sqlite.zig");
const store_check = @import("store_check.zig");
const c = sqlite.c;

pub const Result = struct {
    /// Statements run: one per rule and reference.
    checked: usize = 0,
    /// Statements that counted at least one violating row.
    breaking: usize = 0,
    /// Violating rows over all statements; a row that breaks two rules counts twice.
    rows: u64 = 0,
};

pub const Error = error{ StoreOpenFailed, StoreFormatMismatch, CheckFailed, WriteFailed };

/// Writes `name<TAB>rows` for every rule or reference that has violators, in the catalog's order, to `out`.
pub fn checkSqlite(database_path: [:0]const u8, out: *std.Io.Writer, refusal: *std.Io.Writer) Error!Result {
    var raw: ?*c.sqlite3 = null;
    defer _ = c.sqlite3_close(raw);
    if (c.sqlite3_open_v2(database_path, &raw, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_NOMUTEX, null) != c.SQLITE_OK) return error.StoreOpenFailed;
    const database = raw.?;
    const found = sqlite.pragmaInt(database, "PRAGMA user_version") catch return error.StoreOpenFailed;
    if (found != schema.schema_version) {
        refusal.print("the Store is format {d} and this build checks format {d}; start the Host from this build to upgrade it first\n", .{ found, schema.schema_version }) catch return error.WriteFailed;
        return error.StoreFormatMismatch;
    }
    var result: Result = .{};
    for (comptime store_check.checks(.sqlite)) |check| {
        const statement = sqlite.prepare(database, check.sql) catch return error.CheckFailed;
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CheckFailed;
        const rows = sqlite.readCount(statement, 0) catch return error.CheckFailed;
        result.checked += 1;
        if (rows == 0) continue;
        result.breaking += 1;
        result.rows += rows;
        out.print("{s}\t{d}\n", .{ check.name, rows }) catch return error.WriteFailed;
    }
    return result;
}

const test_broken_row = "INSERT INTO content_part(content_id,ordinal,part_content_id) VALUES(5,-1,5)";

fn writeStore(tmp: *std.testing.TmpDir, io: std.Io, name: []const u8, version: u32, broken: bool) ![:0]u8 {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_length = try tmp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/{s}", .{ path_buffer[0..dir_length], name }, 0);
    errdefer std.testing.allocator.free(path);
    var raw: ?*c.sqlite3 = null;
    defer _ = c.sqlite3_close(raw);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(path, &raw));
    try sqlite.exec(raw.?, schema.ddlIn(.sqlite, .plain));
    var pragma: [48]u8 = undefined;
    try sqlite.exec(raw.?, try std.fmt.bufPrintSentinel(&pragma, "PRAGMA user_version={d}", .{version}, 0));
    if (broken) try sqlite.exec(raw.?, test_broken_row);
    return path;
}

test "SH-185 store check on a SQLite file reports each broken rule, refuses another format and leaves the file as it was" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buffer: [1024]u8 = undefined;
    var refusal_buffer: [512]u8 = undefined;

    const clean = try writeStore(&tmp, io, "clean.sqlite3", schema.schema_version, false);
    defer std.testing.allocator.free(clean);
    var out: std.Io.Writer = .fixed(&out_buffer);
    var refusal: std.Io.Writer = .fixed(&refusal_buffer);
    const none = try checkSqlite(clean, &out, &refusal);
    try std.testing.expectEqual(comptime store_check.checks(.sqlite).len, none.checked);
    try std.testing.expectEqual(@as(usize, 0), none.breaking);
    try std.testing.expectEqualStrings("", out.buffered());

    const broken = try writeStore(&tmp, io, "broken.sqlite3", schema.schema_version, true);
    defer std.testing.allocator.free(broken);
    out = .fixed(&out_buffer);
    const found = try checkSqlite(broken, &out, &refusal);
    try std.testing.expectEqual(@as(usize, 4), found.breaking);
    try std.testing.expectEqual(@as(u64, 4), found.rows);
    try std.testing.expectEqualStrings(
        "content_part.ordinal\t1\ncontent_part#0\t1\ncontent_part(content_id)->content\t1\ncontent_part(part_content_id)->content\t1\n",
        out.buffered(),
    );
    const before = try tmp.dir.readFileAlloc(io, "broken.sqlite3", std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(before);
    out = .fixed(&out_buffer);
    _ = try checkSqlite(broken, &out, &refusal);
    const after = try tmp.dir.readFileAlloc(io, "broken.sqlite3", std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);

    const older = try writeStore(&tmp, io, "older.sqlite3", schema.schema_version - 1, true);
    defer std.testing.allocator.free(older);
    out = .fixed(&out_buffer);
    try std.testing.expectError(error.StoreFormatMismatch, checkSqlite(older, &out, &refusal));
    try std.testing.expectEqualStrings("", out.buffered());
    try std.testing.expect(std.mem.indexOf(u8, refusal.buffered(), "format") != null);

    try std.testing.expectError(error.StoreOpenFailed, checkSqlite("/nonexistent/dir/none.sqlite3", &out, &refusal));
}
