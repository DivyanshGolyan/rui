//! MySQL admission and ownership acquisition. The caller connects first;
//! admission never performs DDL. On failure we close, releasing GET_LOCK
//! and rolling back any unfinished metadata/epoch transaction.
const std = @import("std");
const wire = @import("../wire/mysql_connection.zig");
const rows = @import("../mysql_row.zig");
const literal = @import("../mysql_literal.zig");
const schema = @import("../schema.zig");
const protocol = @import("../../protocol.zig");
const policy = @import("mysql_refusal.zig");

pub const Options = struct {
    database: []const u8,
    found_schema_version: ?*u32 = null,
};
pub const State = struct {
    epoch: u64,
    commit_seq: u64,
    doublewrite: protocol.Bounded(32),
};
const FactsRow = struct {
    version: protocol.Bounded(128),
    version_comment: protocol.Bounded(256),
    read_only: bool,
    super_read_only: bool,
    flush: u64,
    sync: u64,
    bin: bool,
    bin_format: protocol.Bounded(32),
    doublewrite: protocol.Bounded(32),
    database: protocol.Bounded(64),
};

pub fn open(conn: *wire.Connection, io: std.Io, options: Options, selector: []const u8) !State {
    errdefer conn.close();
    // The database name is also MySQL's connection-owned lock name.
    // GET_LOCK accepts at most 64 characters; do not truncate and collide.
    if (options.database.len == 0 or options.database.len > 64) return error.WrongStoreIdentity;
    if (selector.len > protocol.max_store_bytes) return error.WrongStoreIdentity;
    const w = conn.batch();
    for (schema.mysql_session) |sql| {
        try w.writeAll(sql);
        try w.writeByte(';');
    }
    try w.writeAll("SELECT @@version,@@version_comment,@@global.read_only,@@global.super_read_only,@@global.innodb_flush_log_at_trx_commit,@@global.sync_binlog,@@global.log_bin,@@global.binlog_format,@@global.innodb_doublewrite,DATABASE();SELECT GET_LOCK(");
    try text(w, options.database);
    try w.writeAll(",0)");
    try conn.sendBatch();
    for (schema.mysql_session) |_| try expectOk(conn);
    const facts = try one(FactsRow, conn);
    const lock = try one(struct { acquired: ?u64 }, conn);
    if (!facts.database.eql(options.database)) return error.WrongStoreIdentity;
    const acquired = lock.acquired orelse return error.StoreConnectionLost;
    if (acquired == 0) return error.StoreLocked;
    if (acquired != 1) return error.CorruptStore;
    if (policy.refusal(.{
        .server_version = facts.version.slice(),
        .version_comment = facts.version_comment.slice(),
        .read_only = facts.read_only,
        .super_read_only = facts.super_read_only,
        .innodb_flush_log_at_trx_commit = facts.flush,
        .sync_binlog = facts.sync,
        .log_bin = facts.bin,
        .binlog_format = facts.bin_format.slice(),
        .doublewrite = facts.doublewrite.slice(),
    })) |failure| return failure;

    try conn.query("SELECT meta_key,meta_value FROM store_meta;" ++ comptime schema.catalogSql("DATABASE()"));
    const Meta = struct { key: protocol.Bounded(32), value: protocol.Bounded(protocol.max_store_bytes) };
    var meta_columns = try columns(Meta, conn);
    var seen: packed struct { format: bool = false, wire_version: bool = false, selector: bool = false, store_id: bool = false } = .{};
    while (try nextRow(conn)) {
        var meta: Meta = undefined;
        try rows.decodeRow(Meta, &meta_columns, conn, &meta);
        const key = meta.key.slice();
        const value = meta.value.slice();
        if (std.mem.eql(u8, key, "format")) {
            const found = std.fmt.parseInt(u32, value, 10) catch return error.WrongStoreVersion;
            if (options.found_schema_version) |out| out.* = found;
            if (found != schema.schema_version) return error.StoreSchemaBehind;
            seen.format = true;
        } else if (std.mem.eql(u8, key, "wire_version")) {
            if (!std.mem.eql(u8, value, protocol.wire_version)) return error.WrongStoreVersion;
            seen.wire_version = true;
        } else if (std.mem.eql(u8, key, "store_selector")) {
            if (!std.mem.eql(u8, value, selector)) return error.WrongStoreIdentity;
            seen.selector = true;
        } else if (std.mem.eql(u8, key, "store_id")) {
            if (!schema.isStoreId(value)) return error.WrongStoreIdentity;
            seen.store_id = true;
        } else return error.WrongStoreSchema;
    }
    const Catalog = struct { line: protocol.Bounded(2048) };
    var catalog_columns = try columns(Catalog, conn);
    var digest: u64 = 0;
    while (try nextRow(conn)) {
        var entry: Catalog = undefined;
        try rows.decodeRow(Catalog, &catalog_columns, conn, &entry);
        digest +%= schema.catalogLineDigest(entry.line.slice());
    }
    if (digest != comptime schema.catalogDigest()) return error.StoreSchemaBehind;

    // All existing identity and schema state is validated before any write.
    // Repair missing metadata atomically with ownership and the sender sweep.
    const batch = conn.batch();
    try batch.writeAll("START TRANSACTION;");
    if (!seen.format) try insertMeta(batch, "format", std.fmt.comptimePrint("{d}", .{schema.schema_version}));
    if (!seen.wire_version) try insertMeta(batch, "wire_version", protocol.wire_version);
    if (!seen.selector) try insertMeta(batch, "store_selector", selector);
    if (!seen.store_id) {
        var random: [schema.store_id_bytes]u8 = undefined;
        io.random(&random);
        var id: [2 * schema.store_id_bytes]u8 = undefined;
        const digits = "0123456789abcdef";
        for (random, 0..) |byte, i| {
            id[2 * i] = digits[byte >> 4];
            id[2 * i + 1] = digits[byte & 15];
        }
        try insertMeta(batch, "store_id", &id);
    }
    try batch.writeAll("INSERT INTO store_owner(owner_key,epoch,commit_seq) SELECT 1,0,0 WHERE NOT EXISTS(SELECT 1 FROM store_owner WHERE owner_key=1);UPDATE store_owner SET epoch=epoch+1 WHERE owner_key=1;UPDATE action_operation SET sender_handle=NULL WHERE sender_handle IS NOT NULL;SELECT epoch,commit_seq FROM store_owner WHERE owner_key=1;COMMIT");
    try conn.sendBatch();
    try expectOk(conn); // START TRANSACTION
    if (!seen.format) try expectOk(conn);
    if (!seen.wire_version) try expectOk(conn);
    if (!seen.selector) try expectOk(conn);
    if (!seen.store_id) try expectOk(conn);
    try expectOk(conn); // missing owner row
    const updated = try expectOkCount(conn);
    if (updated != 1) return error.OwnershipLost;
    try expectOk(conn); // sender sweep
    const owner = try one(struct { epoch: u64, commit_seq: u64 }, conn);
    if (owner.epoch == 0) return error.CorruptStore;
    // A missing acknowledgement is never reported as a successful open.
    expectOk(conn) catch return error.CommitOutcomeUnknown;
    if (!conn.isReady()) return error.ProtocolViolation;
    return .{ .epoch = owner.epoch, .commit_seq = owner.commit_seq, .doublewrite = facts.doublewrite };
}

fn text(w: *std.Io.Writer, value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.WrongStoreIdentity;
    try w.writeAll("_utf8mb4 X'");
    try literal.writeHex(w, value);
    try w.writeAll("' COLLATE utf8mb4_0900_bin");
}

fn insertMeta(w: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try w.writeAll("INSERT INTO store_meta(meta_key,meta_value) VALUES(");
    try text(w, key);
    try w.writeByte(',');
    try text(w, value);
    try w.writeAll(");");
}

fn serverError(code: u16) anyerror {
    return switch (code) {
        1146 => error.StoreSchemaMissing,
        1114, 1021 => error.CanonicalStorageFull,
        else => error.StatementFailed,
    };
}

fn columns(comptime Row: type, conn: *wire.Connection) !rows.Columns(Row) {
    return switch (try conn.next()) {
        .columns => |n| try rows.readColumns(Row, conn, n),
        .err => |err| serverError(err.code),
        else => error.ProtocolViolation,
    };
}

fn nextRow(conn: *wire.Connection) !bool {
    return switch (try conn.next()) {
        .row => true,
        .rows_end => false,
        .err => |err| serverError(err.code),
        else => error.ProtocolViolation,
    };
}

fn one(comptime Row: type, conn: *wire.Connection) !Row {
    const cols = try columns(Row, conn);
    if (!try nextRow(conn)) return error.CorruptStore;
    var row: Row = undefined;
    try rows.decodeRow(Row, &cols, conn, &row);
    if (try nextRow(conn)) return error.CorruptStore;
    return row;
}

fn expectOkCount(conn: *wire.Connection) !u64 {
    return switch (try conn.next()) {
        .ok => |ok| ok.affected_rows,
        .err => |err| serverError(err.code),
        else => error.ProtocolViolation,
    };
}

fn expectOk(conn: *wire.Connection) !void {
    _ = try expectOkCount(conn);
}
