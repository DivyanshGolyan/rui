//! MySQL admission and ownership acquisition. The caller connects first;
//! admission never performs DDL. On failure we close, releasing GET_LOCK
//! and rolling back any unfinished metadata/epoch transaction.
const std = @import("std");
const wire = @import("../wire/mysql_connection.zig");
const rows = @import("../mysql_row.zig");
const literal = @import("../mysql_literal.zig");
const schema = @import("../schema.zig");
const store_path = @import("../../store_path.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const wire_version = @import("../../wire_version.zig").wire_version;
const policy = @import("mysql_refusal.zig");

pub const Options = struct {
    database: []const u8,
    found_schema_version: ?*u32 = null,
};
pub const State = struct {
    epoch: u64,
    commit_seq: u64,
    /// The server session holding GET_LOCK, which `reclaim` ends.
    connection_id: u64,
    doublewrite: Bounded(32),
    store_id: [2 * schema.store_id_bytes]u8,
};
const FactsRow = struct {
    version: Bounded(128),
    version_comment: Bounded(256),
    read_only: bool,
    super_read_only: bool,
    flush: u64,
    sync: u64,
    bin: bool,
    bin_format: Bounded(32),
    doublewrite: Bounded(32),
    max_allowed_packet: u64,
    database: Bounded(64),
    connection_id: u64,
};

const session_settings = blk: {
    var all: []const u8 = "";
    for (schema.mysql_session) |sql| all = all ++ sql ++ ";";
    break :blk all;
};

pub fn open(conn: *wire.Connection, io: std.Io, options: Options, selector: []const u8) !State {
    errdefer conn.close();
    // The database name is also MySQL's connection-owned lock name.
    // GET_LOCK accepts at most 64 characters; do not truncate and collide.
    if (options.database.len == 0 or options.database.len > 64) return error.WrongStoreIdentity;
    if (selector.len > store_path.max_bytes) return error.WrongStoreIdentity;
    // Every message carries the settings, so none relies on the server
    // connection a proxy sent the last one on.
    conn.useSettings(session_settings, schema.mysql_session.len);
    const w = conn.batch();
    try w.writeAll(facts_sql ++ ";SELECT GET_LOCK(");
    try text(w, options.database);
    try w.writeAll(",0)");
    try conn.sendBatch();
    const facts = try one(FactsRow, conn);
    const lock = try one(struct { acquired: ?u64 }, conn);
    if (!facts.database.eql(options.database)) return error.WrongStoreIdentity;
    const acquired = lock.acquired orelse return error.StoreConnectionLost;
    if (acquired == 0) return error.StoreLocked;
    if (acquired != 1) return error.CorruptStore;
    conn.limitBatch(facts.max_allowed_packet);
    if (refusal(&facts)) |failure| return failure;

    // Never decode the obsolete selector's value: even its old path bound
    // has no authority over admission after a restore under another name.
    try conn.query("SELECT meta_key,CASE WHEN meta_key='store_selector' THEN '' ELSE meta_value END FROM store_meta;" ++ comptime schema.catalogSql("DATABASE()"));
    const Meta = struct { key: Bounded(32), value: Bounded(store_path.max_bytes) };
    var meta_columns = try columns(Meta, conn);
    var store_id: [2 * schema.store_id_bytes]u8 = undefined;
    var seen: schema.MetaPresence = .empty;
    while (try nextRow(conn)) {
        var meta: Meta = undefined;
        // The decoder fills fields in order. Preserve the key if its value
        // exceeds the bound (or is otherwise malformed), so that refusal is
        // still attributed to that metadata, not an unclassified row error.
        meta.key.len = 0;
        rows.decodeRow(Meta, &meta_columns, conn, &meta) catch |err| switch (err) {
            error.CorruptStore => return switch (std.meta.stringToEnum(schema.MetaKey, meta.key.slice()) orelse return error.WrongStoreSchema) {
                .format => error.MalformedStoreFormat,
                .wire_version => error.WrongStoreVersion,
                .store_id => error.WrongStoreIdentity,
                .store_selector => error.WrongStoreSchema, // CASE supplies empty text.
            },
            else => return err,
        };
        const key = meta.key.slice();
        const value = meta.value.slice();
        const meta_key = std.meta.stringToEnum(schema.MetaKey, key) orelse return error.WrongStoreSchema;
        switch (meta_key) {
            .format => {
                const found = std.fmt.parseInt(u32, value, 10) catch return error.MalformedStoreFormat;
                if (options.found_schema_version) |out| out.* = found;
                if (found < schema.schema_version) return error.StoreSchemaBehind;
                if (found > schema.schema_version) return error.StoreSchemaAhead;
            },
            .wire_version => if (!std.mem.eql(u8, value, wire_version)) return error.WrongStoreVersion,
            // A legacy database name is not this Store's durable identity.
            .store_selector => {},
            .store_id => {
                if (!schema.isStoreId(value)) return error.WrongStoreIdentity;
                store_id = value[0..store_id.len].*;
            },
        }
        seen.insert(meta_key);
    }
    const Catalog = struct { line: Bounded(2048) };
    var catalog_columns = try columns(Catalog, conn);
    var digest: u64 = 0;
    while (try nextRow(conn)) {
        var entry: Catalog = undefined;
        try rows.decodeRow(Catalog, &catalog_columns, conn, &entry);
        digest +%= schema.catalogLineDigest(entry.line.slice());
    }
    if (digest != comptime schema.catalogDigest()) return error.StoreCatalogMismatch;

    // All existing identity and schema state is validated before any write.
    // Repair missing metadata atomically with ownership and the sender sweep.
    const batch = conn.batch();
    try batch.writeAll("START TRANSACTION;");
    if (!seen.contains(.store_id)) store_id = schema.drawStoreId(io);
    try schema.writeMissingMeta(batch, seen, &store_id);
    try batch.writeAll("INSERT INTO store_owner(owner_key,epoch,commit_seq) SELECT 1,0,0 WHERE NOT EXISTS(SELECT 1 FROM store_owner WHERE owner_key=1);UPDATE store_owner SET epoch=epoch+1 WHERE owner_key=1;UPDATE action_operation SET sender_handle=NULL WHERE sender_handle IS NOT NULL;SELECT epoch,commit_seq FROM store_owner WHERE owner_key=1;COMMIT");
    try conn.sendBatch();
    try expectOk(conn); // START TRANSACTION
    for (comptime schema.metaSeed(.mysql)) |entry| {
        if (!seen.contains(entry.key)) try expectOk(conn);
    }
    try expectOk(conn); // missing owner row
    const updated = try expectOkCount(conn);
    if (updated != 1) return error.OwnershipLost;
    try expectOk(conn); // sender sweep
    const owner = try one(struct { epoch: u64, commit_seq: u64 }, conn);
    if (owner.epoch == 0) return error.CorruptStore;
    // A missing acknowledgement is never reported as a successful open.
    expectOk(conn) catch return error.CommitOutcomeUnknown;
    if (!conn.isReady()) return error.ProtocolViolation;
    return .{ .epoch = owner.epoch, .commit_seq = owner.commit_seq, .connection_id = facts.connection_id, .doublewrite = facts.doublewrite, .store_id = store_id };
}

/// The server facts admission checks, and the session's id.
const facts_sql = "SELECT @@version,@@version_comment,@@global.read_only,@@global.super_read_only,@@global.innodb_flush_log_at_trx_commit,@@global.sync_binlog,@@global.log_bin,@@global.binlog_format,@@global.innodb_doublewrite,@@max_allowed_packet,DATABASE(),CONNECTION_ID()";

fn refusal(facts: *const FactsRow) ?policy.StartError {
    return policy.refusal(.{
        .server_version = facts.version.slice(),
        .version_comment = facts.version_comment.slice(),
        .read_only = facts.read_only,
        .super_read_only = facts.super_read_only,
        .innodb_flush_log_at_trx_commit = facts.flush,
        .sync_binlog = facts.sync,
        .log_bin = facts.bin,
        .binlog_format = facts.bin_format.slice(),
        .doublewrite = facts.doublewrite.slice(),
    });
}

/// Releases the Store's GET_LOCK before the connection closes. COM_QUIT
/// alone frees it only once the server has ended the session, after close
/// returns, so a Host reopening the Store at once could find it locked.
pub fn releaseLock(conn: *wire.Connection) void {
    conn.batch().writeAll("DO RELEASE_ALL_LOCKS()") catch return;
    conn.sendBatch() catch return;
    _ = conn.next() catch {};
}

pub const Reclaimed = struct { epoch: u64, commit_seq: u64, connection_id: u64 };

/// On a fresh connection after the last was lost: checks the server and
/// the Store first, since a failover may reach another server; ends the
/// session the Store's GET_LOCK was taken on only when that session still
/// holds the lock and no Host has opened the Store since (`epoch`), so a
/// reused connection id never ends someone else's session; then takes the
/// lock again once that session is gone and reads the ownership row. With
/// the old session gone, no statement it was sent can still commit, so
/// `commit_seq` is final.
pub fn reclaim(conn: *wire.Connection, database: []const u8, store_id: *const [2 * schema.store_id_bytes]u8, epoch: u64, old_connection_id: u64) !Reclaimed {
    // The kept trust serves the next attempt.
    errdefer conn.disconnect();
    conn.useSettings(session_settings, schema.mysql_session.len);
    var w = conn.batch();
    try w.writeAll(facts_sql ++ ";SELECT IS_USED_LOCK(");
    try text(w, database);
    try w.writeAll(");SELECT epoch FROM store_owner WHERE owner_key=1;SELECT meta_value FROM store_meta WHERE meta_key='store_id'");
    try conn.sendBatch();
    const facts = try one(FactsRow, conn);
    const holder = try one(struct { id: ?u64 }, conn);
    const before = try one(struct { epoch: u64 }, conn);
    const id = try one(struct { value: Bounded(2 * schema.store_id_bytes) }, conn);
    if (!facts.database.eql(database) or !std.mem.eql(u8, id.value.slice(), store_id)) return error.WrongStoreIdentity;
    if (refusal(&facts)) |failure| return failure;
    if (before.epoch != epoch) return error.OwnershipLost;
    if (holder.id) |session| {
        // Another session holds the Store's lock: never ours to end.
        if (session != old_connection_id) return error.StoreLocked;
        // Alone: a session that ended meanwhile fails KILL, which would stop a batch.
        try conn.batch().print("KILL {d}", .{old_connection_id});
        try conn.sendBatch();
        switch (try conn.next()) {
            .ok, .err => {},
            else => return error.ProtocolViolation,
        }
    }
    w = conn.batch();
    // KILL returns before the session ends; the lock waits for its end.
    try w.writeAll("SELECT @@max_allowed_packet,CONNECTION_ID(),GET_LOCK(");
    try text(w, database);
    try w.print(",{d});SELECT epoch,commit_seq FROM store_owner WHERE owner_key=1", .{reclaim_lock_wait_s});
    try conn.sendBatch();
    const lock = try one(struct { max_allowed_packet: u64, connection_id: u64, acquired: ?u64 }, conn);
    const owner = try one(struct { epoch: u64, commit_seq: u64 }, conn);
    const acquired = lock.acquired orelse return error.StoreConnectionLost;
    if (acquired == 0) return error.StoreLocked;
    if (acquired != 1) return error.CorruptStore;
    conn.limitBatch(lock.max_allowed_packet);
    return .{ .epoch = owner.epoch, .commit_seq = owner.commit_seq, .connection_id = lock.connection_id };
}

/// How long `reclaim` waits for the old session to end, well inside the
/// round deadline.
const reclaim_lock_wait_s = 10;

fn text(w: *std.Io.Writer, value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.WrongStoreIdentity;
    try w.writeAll("_utf8mb4 X'");
    try literal.writeHex(w, value);
    try w.writeAll("' COLLATE utf8mb4_0900_bin");
}

fn serverError(code: u16) anyerror {
    return switch (code) {
        1044, 1045 => error.LoginRefused,
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

test "store.mysql open access denials keep the login refusal" {
    try std.testing.expectEqual(error.LoginRefused, serverError(1044));
    try std.testing.expectEqual(error.LoginRefused, serverError(1045));
    try std.testing.expectEqual(error.StoreSchemaMissing, serverError(1146));
    try std.testing.expectEqual(error.StatementFailed, serverError(9999));
}
