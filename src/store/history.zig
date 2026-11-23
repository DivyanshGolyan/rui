//! The owner of a test Store at a frozen format N. A Start names N, the rows
//! written in format N's shape, and build() makes that Store the way the
//! shipped migrations did: the format-51 baseline, the baseline rows, and the
//! shipped steps below N. Test code never rewinds a current Store.
//! upgrade() then runs the product's own migration path (schema.openExisting).
//! Design: #2114 (candidate 2). This file holds the SQLite path only; MySQL is
//! not implemented here.

const std = @import("std");
const platform = @import("../store_path.zig");
const protocol = @import("../protocol.zig");
const schema = @import("schema.zig");
const sqlite = @import("sqlite.zig");
const store_testing = @import("testing.zig");
const c = sqlite.c;
const Engine = store_testing.Engine;

/// Rows (SQL) written in one frozen format's shape.
pub const FormatSql = union(enum) {
    /// Runs unchanged on both engines. Built through `neutral`, which refuses engine-only forms.
    portable: Portable,
    /// Only when the two engines' format-N shapes differ in what the statement must name.
    per_engine: struct { sqlite: [:0]const u8, mysql: [:0]const u8 },

    pub fn neutral(comptime sql: [:0]const u8) FormatSql {
        return .{ .portable = Portable.of(sql) };
    }

    fn text(self: FormatSql, engine: Engine) [:0]const u8 {
        return switch (self) {
            .portable => |p| p.text,
            .per_engine => |p| if (engine == .mysql) p.mysql else p.sqlite,
        };
    }
};

/// SQL text that is the same on both engines. Checked at comptime.
pub const Portable = struct {
    text: [:0]const u8,

    pub fn of(comptime text: [:0]const u8) Portable {
        comptime {
            const refused = [_][]const u8{ "zeroblob", "randomblob", "unixepoch", "RANDOM_BYTES", "REPEAT(", "||", "`", "INSERT OR", "ON CONFLICT", "PRAGMA" };
            for (refused) |token| if (std.mem.indexOf(u8, text, token) != null)
                @compileError("history: portable format SQL uses the engine-only form " ++ token ++ "; use per_engine or a portable literal");
        }
        return .{ .text = text };
    }
};

/// Where an upgrade test starts. Comptime-known; one per scenario, beside its test.
pub const Start = struct {
    /// schema.migration_baseline (51) .. schema.schema_version.
    format: u32,
    /// Rows (and, rarely, DDL) in `format`'s shape, run after the shipped steps reach `format`,
    /// with foreign keys enforced: a row the format cannot hold fails here.
    sql: FormatSql = FormatSql.neutral(""),
    /// Load migration_baseline_rows at 51 and let the shipped steps carry them to `format`.
    baseline_rows: bool = true,
};

/// A raw database at `start.format`, not yet upgraded. Owns its SQLite connection.
pub const Built = struct {
    io: std.Io,
    engine: Engine,
    format: u32,
    raw: ?*c.sqlite3,
    upgraded: bool = false,
    /// The Store directory (the tmp dir's realpath). Its own storage so a Built can be returned by value.
    root_storage: [protocol.max_store_bytes]u8,
    root_len: usize,
    /// `<root>/store.sqlite3`: migrate's backup needs the .sqlite3 suffix.
    path_storage: [platform.max_database_path_bytes]u8,
    path_len: usize,

    pub fn root(self: *const Built) []const u8 {
        return self.root_storage[0..self.root_len];
    }

    pub fn path(self: *const Built) []const u8 {
        return self.path_storage[0..self.path_len];
    }

    /// Raw statement against the format-N (before upgrade) or current (after) database.
    pub fn exec(self: *Built, sql: [:0]const u8) !void {
        try sqlite.exec(self.raw orelse return error.HistoryClosed, sql);
    }

    /// The operator's upgrade, exactly once. SQLite: schema.openExisting on the raw handle
    /// (backup, foreign keys off, shipped steps from N, foreign_key_check, validateCurrent).
    pub fn upgrade(self: *Built) !void {
        if (self.upgraded) return;
        if (self.engine == .mysql) return error.HistoryMysqlNotImplemented;
        try schema.openExisting(self.io, self.raw orelse return error.HistoryClosed, self.root(), null, null);
        self.upgraded = true;
    }

    pub fn deinit(self: *Built) void {
        if (self.raw) |raw| _ = c.sqlite3_close(raw);
        self.raw = null;
    }
};

/// The shipped steps a Store at `format` has not yet taken: exactly those below it.
/// build() replays these and nothing else.
fn stepsBelow(format: u32) []const schema.Migration {
    std.debug.assert(format >= schema.migration_baseline and format <= schema.schema_version);
    return schema.migrations[0 .. format - schema.migration_baseline];
}

/// Build a raw Store at `start.format` in `tmp`. SQLite only for now.
pub fn build(io: std.Io, engine: Engine, tmp: *std.testing.TmpDir, start: *const Start) !Built {
    if (engine == .mysql) return error.HistoryMysqlNotImplemented;
    if (start.format < schema.migration_baseline or start.format > schema.schema_version) return error.StartFormatOutOfRange;
    var built: Built = .{
        .io = io,
        .engine = engine,
        .format = start.format,
        .raw = null,
        .root_storage = undefined,
        .root_len = 0,
        .path_storage = undefined,
        .path_len = 0,
    };
    built.root_len = try tmp.dir.realPath(io, &built.root_storage);
    built.path_len = (try std.fmt.bufPrint(&built.path_storage, "{s}/store.sqlite3", .{built.root()})).len;

    var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
    var raw: ?*c.sqlite3 = null;
    if (c.sqlite3_open(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{built.path()}, 0), &raw) != c.SQLITE_OK) {
        if (raw) |database| _ = c.sqlite3_close(database);
        return error.StoreOpenFailed;
    }
    built.raw = raw.?;
    errdefer built.deinit();
    const database = built.raw.?;

    try sqlite.exec(database, store_testing.baseline_sqlite_ddl);
    try sqlite.exec(database, std.fmt.comptimePrint("PRAGMA application_id={d};PRAGMA user_version={d}", .{ schema.application_id, schema.migration_baseline }));
    try insertBaselineMeta(database, built.root());
    try sqlite.exec(database, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
    if (start.baseline_rows) try sqlite.exec(database, store_testing.baseline_rows);
    for (stepsBelow(start.format)) |step| for (step.sqlite) |statement| try sqlite.exec(database, statement);
    try sqlite.exec(database, "PRAGMA foreign_keys=ON;PRAGMA legacy_alter_table=OFF");

    var format_buffer: [256]u8 = undefined;
    try sqlite.exec(database, try std.fmt.bufPrintSentinel(&format_buffer, "PRAGMA user_version={d};UPDATE store_meta SET meta_value='{d}' WHERE meta_key='format'", .{ start.format, start.format }, 0));

    try sqlite.exec(database, start.sql.text(engine));
    try expectNoForeignKeyViolations(database);
    return built;
}

/// What a 51 Store held: its selector, a wire version, and format 51 (the steps then carry it on).
fn insertBaselineMeta(database: *c.sqlite3, root: []const u8) !void {
    const statement = try sqlite.prepare(database, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version','7'),('store_selector',?1),('format','51')");
    defer _ = c.sqlite3_finalize(statement);
    try sqlite.bindText(statement, 1, root);
    try sqlite.expectDone(statement);
}

fn expectNoForeignKeyViolations(database: *c.sqlite3) !void {
    const statement = try sqlite.prepare(database, "PRAGMA foreign_key_check");
    defer _ = c.sqlite3_finalize(statement);
    switch (c.sqlite3_step(statement)) {
        c.SQLITE_DONE => {},
        c.SQLITE_ROW => return error.HistoryRowBreaksForeignKey,
        else => return error.StatementFailed,
    }
}

test "a Store built at every format from the baseline to the current one upgrades to a current Store" {
    var format: u32 = schema.migration_baseline;
    while (format <= schema.schema_version) : (format += 1) {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const start: Start = .{ .format = format };
        var built = try build(std.testing.io, .sqlite, &tmp, &start);
        defer built.deinit();
        try std.testing.expectEqual(format, try sqlite.pragmaInt(built.raw.?, "PRAGMA user_version"));
        try built.upgrade();
        // A current Store reopens through the same path, which validates its shape.
        try schema.openExisting(std.testing.io, built.raw.?, built.root(), null, null);
        try std.testing.expectEqual(schema.schema_version, try sqlite.pragmaInt(built.raw.?, "PRAGMA user_version"));
    }
}

test "build at a format reads only the shipped steps whose from is below that format" {
    var format: u32 = schema.migration_baseline;
    while (format <= schema.schema_version) : (format += 1) {
        const steps = stepsBelow(format);
        var below: usize = 0;
        for (schema.migrations) |step| {
            if (step.from < format) below += 1;
        }
        try std.testing.expectEqual(below, steps.len);
        for (steps) |step| try std.testing.expect(step.from < format);
        for (steps, 0..) |step, index| try std.testing.expectEqual(schema.migration_baseline + @as(u32, @intCast(index)), step.from);
    }
}
