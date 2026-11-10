//! MySQL's single-owner, blocking Store connection. Large buffers live out of line.
const std = @import("std");
const engine = @import("../engine.zig");
const Store = @import("../Store.zig");
const provider_route = @import("../../provider_route.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const rsql = @import("../rsql.zig");
const wire = @import("../wire/mysql_connection.zig");
const row_decoder = @import("../mysql_row.zig");
const literal = @import("../mysql_literal.zig");
const content = @import("mysql_content.zig");
const mysql_open = @import("mysql_open.zig");
const Mysql = @This();
const Failure = engine.Failure;
const allocator = std.heap.page_allocator;
const is_test = @import("builtin").is_test;

/// Semantic query causes, independently counted from the wire sends.
pub const QueryShape = struct {
    controls: u64 = 0,
    prefix_only: u64 = 0,
    access_passes: u64 = 0,
    identity_passes: u64 = 0,
    content_queries: u64 = 0,
    reconnects: u64 = 0,
};

state: *State,

pub const State = struct {
    connection: wire.Connection,
    testing_shape: if (is_test) QueryShape else void = if (is_test) .{} else {},
    served: *const provider_route.Routes = &unserved,
    epoch: u64 = 0,
    commit_seq: u64 = 0,
    changes: i64 = 0,
    failure: ?Failure = null,
    pass_failure: ?Failure = null,
    kinds: []row_decoder.Kind = &.{},
    column_count: usize = 0,
    statement_done: bool = false,
    long_query: bool = false,
    begin: Begin = .none,
    replacement: Replacement = .none,
    prefix_results: u8 = 0,
    committing: bool = false,
    sink: content.SinkState = .{},
    doublewrite: Bounded(32) = .{},
    store_id: [32]u8 = undefined,
    testing_database: if (is_test) [40]u8 else void = if (is_test) @splat(0) else {},
    fence_result: u8 = 0,
    /// The login a lost connection reconnects with, kept for the Host's
    /// life; null when it cannot be kept, and then a loss stays final.
    login: ?Login = null,
    /// The server session holding the Store's GET_LOCK.
    connection_id: u64 = 0,
    io: std.Io = undefined,
    /// Tests: where the next COMMIT loses its connection.
    testing_drop: if (is_test) enum { none, before_commit, after_commit } else void = if (is_test) .none else {},

    /// Commit, rollback or a server abort ends the transaction, and with
    /// it every savepoint and any control not yet sent.
    fn endTransaction(s: *State) void {
        s.begin = .none;
        s.replacement = .none;
    }
};

/// The open transaction's BEGIN, which is the transaction itself: none
/// once it commits, rolls back or the server aborts it.
const Begin = union(enum) {
    none,
    /// Requested; appended ahead of the next statement or control.
    pending,
    /// In the unsent batch. A discard returns it to pending.
    buffered,
    /// Sent, so ROLLBACK needs the server. `savepoint` records that a
    /// SAVEPOINT rui_write was sent after it too.
    sent: struct { savepoint: bool = false },
};

/// A new SAVEPOINT rui_write not yet sent. An older one already sent
/// stays independent of it (`Begin.sent.savepoint`).
const Replacement = enum { none, pending, buffered };
const unserved = provider_route.all(.unserved);

/// A copy of the open-time login, so a reconnect needs nothing the caller
/// wiped. Only system TLS trust is kept: a CA file path is not.
const Login = struct {
    address: enum { unix_socket, tcp_tls, tcp },
    host: Bounded(253) = .{ .len = 0 },
    port: u16 = 0,
    user: Bounded(wire.mysql.max_user_bytes) = .{ .len = 0 },
    password: Bounded(wire.mysql.max_password_bytes) = .{ .len = 0 },
    database: Bounded(64) = .{ .len = 0 },
    deadline_ms: u32,

    fn of(given: wire.Options) ?Login {
        var login: Login = .{ .address = undefined, .deadline_ms = given.deadline_ms };
        switch (given.address) {
            .unix_socket => |path| {
                login.address = .unix_socket;
                login.host.set(path) catch return null;
            },
            .tcp_tls => |t| {
                if (t.trust != .system) return null;
                login.address = .tcp_tls;
                login.host.set(t.host) catch return null;
                login.port = t.port;
            },
            .tcp => |t| {
                login.address = .tcp;
                login.host.set(t.host) catch return null;
                login.port = t.port;
            },
        }
        login.user.set(given.user) catch return null;
        login.password.set(given.password) catch return null;
        login.database.set(given.database) catch return null;
        return login;
    }

    fn options(self: *const Login) wire.Options {
        return .{
            .address = switch (self.address) {
                .unix_socket => .{ .unix_socket = self.host.slice() },
                .tcp_tls => .{ .tcp_tls = .{ .host = self.host.slice(), .port = self.port, .trust = .system } },
                .tcp => .{ .tcp = .{ .host = self.host.slice(), .port = self.port } },
            },
            .user = self.user.slice(),
            .password = self.password.slice(),
            .database = self.database.slice(),
            .deadline_ms = self.deadline_ms,
        };
    }
};

/// Reconnects a lost connection tries, a second apart, before the loss
/// stays final.
const reconnect_attempts = 3;
pub const ContentSink = content.ContentSink;
pub const ContentHost = content.Host;
pub const insert_chunk = rsql.Write(.{
    .sql = "INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES(?1,?2,?3)",
    .Args = struct { content_id: u64, chunk_index: u64, bytes: rsql.Bytes },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

pub fn open(io: std.Io, options: wire.Options, selector: []const u8, store_options: Store.OpenOptions) !Mysql {
    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    state.* = .{ .connection = undefined, .login = Login.of(options), .io = io };
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(state));
    var refusal_buffer: [1024]u8 = undefined;
    var refusal = std.Io.Writer.fixed(&refusal_buffer);
    try state.connection.open(options, &refusal);
    const opened = try @import("mysql_open.zig").open(&state.connection, io, .{ .database = options.database, .found_schema_version = store_options.found_schema_version }, selector);
    state.doublewrite = opened.doublewrite;
    state.store_id = opened.store_id;
    state.epoch = opened.epoch;
    state.commit_seq = opened.commit_seq;
    state.connection_id = opened.connection_id;
    return .{ .state = state };
}

pub fn close(self: *Mysql) error{StoreCloseFailed}!void {
    self.state.sink.close();
    const failed = self.state.failure != null;
    self.state.connection.close();
    allocator.free(self.state.kinds);
    std.crypto.secureZero(u8, std.mem.asBytes(&self.state.login));
    allocator.destroy(self.state);
    if (failed) return error.StoreCloseFailed;
}

fn fences(err: Failure) bool {
    return switch (err) {
        error.StoreConnectionLost, error.CommitOutcomeUnknown, error.OwnershipLost => true,
        else => false,
    };
}

/// Sink-close errors are delivered once; a lost owner/connection stays fenced.
pub fn check(self: *Mysql) Failure!void {
    if (self.state.failure) |err| {
        if (!fences(err)) self.state.failure = null;
        return err;
    }
}

fn lost(self: *Mysql) Failure {
    const err: Failure = if (self.state.committing) error.CommitOutcomeUnknown else error.StoreConnectionLost;
    self.state.failure = err;
    return err;
}

pub fn next(self: *Mysql) Failure!wire.mysql.Event {
    return self.state.connection.next() catch return self.lost();
}

fn serverError(self: *Mysql, code: u16) Failure {
    // The server rolled the transaction back whole: nothing is left to roll back.
    if (code == 1213 or code == 1305) self.state.endTransaction();
    return switch (code) {
        1114, 1021 => error.CanonicalStorageFull,
        else => error.StatementFailed,
    };
}

/// The observer borrows the stable heap state, never the movable engine value.
pub fn contentObserver(self: *Mysql) content.Observer {
    return .{ .context = self.state, .server_error = observeServerError, .content_query = observeContentQuery };
}

fn observeServerError(context: *anyopaque, code: u16) void {
    var mysql: Mysql = .{ .state = @ptrCast(@alignCast(context)) };
    const mapped = mysql.serverError(code);
    _ = @errorName(mapped);
}

fn observeContentQuery(context: *anyopaque) void {
    if (is_test) {
        const state: *State = @ptrCast(@alignCast(context));
        state.testing_shape.content_queries += 1;
    }
}

pub fn fits(self: *Mysql, comptime S: type, args: *const S.Args, now: i64) Failure!bool {
    try self.check();
    const n = try literal.length(S.mysql, S.Args, args, .{ .now = now, .served = self.state.served });
    if (self.state.long_query) return false;
    return self.state.connection.batchLen() == 0 or n + 1 <= self.state.connection.batchRoom();
}

pub fn bind(self: *Mysql, comptime S: type, args: *const S.Args, now: i64) Failure!void {
    try self.check();
    if (comptime S.kind == .read) {
        const n = comptime row_decoder.columnCount(S.Row);
        if (n > self.state.kinds.len) {
            const kinds = allocator.alloc(row_decoder.Kind, n) catch return error.OutOfMemory;
            allocator.free(self.state.kinds);
            self.state.kinds = kinds;
        }
    }
    try self.appendControls();
    const bound: literal.Bound = .{ .now = now, .served = self.state.served };
    const n = try literal.length(S.mysql, S.Args, args, bound);
    if (n + 1 > self.state.connection.batchRoom()) {
        // Prefix controls must complete before a streamed statement starts.
        if (self.state.connection.batchLen() != 0) {
            if (is_test) self.state.testing_shape.prefix_only += 1;
            try self.startPass();
            try self.finishPass();
        }
        const w = self.state.connection.beginQuery(n) catch return self.lost();
        literal.write(S.mysql, S.Args, args, bound, w) catch return self.lost();
        self.state.connection.endQuery() catch return self.lost();
        self.state.long_query = true;
    } else {
        const w = self.state.connection.batch();
        literal.write(S.mysql, S.Args, args, bound, w) catch return error.BindFailed;
        w.writeByte(';') catch return error.BindFailed;
    }
}

fn appendControls(self: *Mysql) Failure!void {
    const s = self.state;
    if (s.begin == .pending) {
        s.connection.batch().print("START TRANSACTION;UPDATE store_owner SET commit_seq=commit_seq+1 WHERE owner_key=1 AND epoch={d} AND commit_seq={d};", .{ s.epoch, s.commit_seq }) catch return error.BindFailed;
        s.prefix_results += 2;
        s.fence_result = 2;
        s.begin = .buffered;
    }
    if (s.replacement == .pending) {
        s.connection.batch().writeAll("SAVEPOINT rui_write;") catch return error.BindFailed;
        s.prefix_results += 1;
        s.replacement = .buffered;
    }
}

pub fn startPass(self: *Mysql) Failure!void {
    try self.check();
    if (!self.state.long_query and self.state.connection.batchLen() != 0) {
        self.state.connection.sendBatch() catch return self.lost();
        if (self.state.begin == .buffered) self.state.begin = .{ .sent = .{} };
        if (self.state.replacement == .buffered) {
            self.state.replacement = .none;
            self.state.begin.sent.savepoint = true;
        }
    }
    while (self.state.prefix_results != 0) {
        const fence = self.state.fence_result == 1;
        const changed = try self.stepWrite();
        self.state.prefix_results -= 1;
        self.state.fence_result -|= 1;
        if (fence and changed != 1) {
            self.state.failure = error.OwnershipLost;
            return error.OwnershipLost;
        }
    }
    self.state.statement_done = false;
}

pub fn drain(self: *Mysql) Failure!void {
    while (!self.state.connection.isReady()) {
        switch (try self.next()) {
            .ok => |ok| self.state.changes +|= @intCast(@min(ok.affected_rows, std.math.maxInt(i64))),
            .err => |err| return self.serverError(err.code),
            else => {},
        }
    }
}
pub fn finishPass(self: *Mysql) Failure!void {
    defer {
        self.state.long_query = false;
        self.state.prefix_results = 0;
        self.state.fence_result = 0;
    }
    const prior = self.state.pass_failure;
    self.state.pass_failure = null;
    self.drain() catch |err| {
        if (fences(err)) return err;
        return prior orelse err;
    };
    try self.check();
    if (prior) |err| return err;
}
pub fn discardBatch(self: *Mysql) Failure!void {
    if (self.state.long_query) self.finishPass() catch |err| {
        // The discarded statement's ordinary failure must not block rollback,
        // but an unresolved connection/ownership failure cannot be discarded.
        if (fences(err)) return err;
    };
    // Revert only controls appended but never sent. In particular, an older
    // server-side savepoint must not be mistaken for the dropped new one.
    if (self.state.replacement == .buffered) self.state.replacement = .pending;
    if (self.state.begin == .buffered) self.state.begin = .pending;
    self.state.connection.writer.end = 0;
    self.state.long_query = false;
    self.state.prefix_results = 0;
    self.state.fence_result = 0;
}
pub fn discard(_: *Mysql, _: ?engine.Statement) void {}

pub fn nextRow(self: *Mysql) Failure!bool {
    try self.check();
    if (self.state.statement_done) return false;
    while (true) switch (try self.next()) {
        .columns => |n| {
            if (n > self.state.kinds.len) return error.CorruptStore;
            self.state.column_count = n;
            for (self.state.kinds[0..n]) |*kind| switch (try self.next()) {
                .column => |column| kind.* = row_decoder.kindOf(column),
                else => return error.CorruptStore,
            };
        },
        .row => return true,
        .rows_end => {
            self.state.statement_done = true;
            return false;
        },
        .err => |err| return self.serverError(err.code),
        else => return error.CorruptStore,
    };
}
pub fn decodeRow(self: *Mysql, comptime Row: type, row: *Row) Failure!void {
    var columns: row_decoder.Columns(Row) = undefined;
    if (self.state.column_count != columns.kinds.len) return error.CorruptStore;
    @memcpy(&columns.kinds, self.state.kinds[0..columns.kinds.len]);
    row_decoder.decodeRow(Row, &columns, self, row) catch |err| switch (err) {
        error.StoreConnectionLost => return error.StoreConnectionLost,
        else => return error.CorruptStore,
    };
}
pub fn stepWrite(self: *Mysql) Failure!u64 {
    switch (try self.next()) {
        .ok => |ok| {
            self.state.statement_done = true;
            self.state.changes +|= @intCast(@min(ok.affected_rows, std.math.maxInt(i64)));
            return ok.affected_rows;
        },
        .err => |err| return self.serverError(err.code),
        else => return error.CorruptStore,
    }
}
pub fn endStatement(self: *Mysql) void {
    if (!self.state.statement_done) {
        while (!self.state.connection.isReady()) {
            const event = self.next() catch |err| {
                self.state.failure = err;
                break;
            };
            switch (event) {
                .rows_end => break,
                .ok => |ok| {
                    self.state.changes +|= @intCast(@min(ok.affected_rows, std.math.maxInt(i64)));
                    break;
                },
                .err => |err| {
                    if (self.state.pass_failure == null) self.state.pass_failure = self.serverError(err.code);
                    break;
                },
                else => {},
            }
        }
    }
    self.state.statement_done = false;
}

pub fn control(self: *Mysql, comptime which: engine.Control) Failure!void {
    if (comptime which == .rollback or which == .rollback_to) {
        if (self.state.failure) |err| {
            if (fences(err)) return err;
            self.state.failure = null;
        }
        self.state.pass_failure = null;
        try self.discardBatch();
    } else try self.check();
    switch (which) {
        .begin => {
            self.state.begin = .pending;
            return;
        },
        .savepoint => {
            self.state.replacement = .pending;
            return;
        },
        .release => return,
        // discardBatch returned anything buffered to pending.
        .rollback => if (self.state.begin != .sent) {
            self.state.endTransaction();
            return;
        },
        .rollback_to => {
            const sent = self.state.begin == .sent and self.state.begin.sent.savepoint;
            if (self.state.replacement != .none or !sent) {
                self.state.replacement = .none;
                return;
            }
        },
        else => {},
    }
    try self.appendControls();
    if (self.state.connection.batchLen() != 0) {
        try self.startPass();
        try self.finishPass();
    }
    const text = comptime switch (which) {
        .commit => "COMMIT",
        .rollback => "ROLLBACK",
        .rollback_to => "ROLLBACK TO SAVEPOINT rui_write",
        else => unreachable,
    };
    self.state.committing = which == .commit;
    defer self.state.committing = false;
    if (is_test) self.state.testing_shape.controls += 1;
    if (is_test and which == .commit and self.state.testing_drop == .before_commit) self.state.connection.disconnect();
    self.state.connection.query(text) catch {
        const err = self.lost();
        return if (which == .commit) self.settleLostCommit() else err;
    };
    if (is_test and which == .commit and self.state.testing_drop == .after_commit) {
        // Once COMMIT's OK is readable, the server has committed: the
        // drop then loses only the acknowledgement.
        var ready = [1]std.posix.pollfd{.{ .fd = self.state.connection.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&ready, 60_000) catch 0;
        self.state.connection.disconnect();
    }
    if (is_test and which == .commit) self.state.testing_drop = .none;
    _ = self.stepWrite() catch |err| {
        if (which == .rollback or which == .rollback_to) return error.CanonicalRollbackFailed;
        if (err == error.CommitOutcomeUnknown) return self.settleLostCommit();
        return err;
    };
    if (which == .commit or which == .rollback) {
        self.state.endTransaction();
        if (which == .commit) self.state.commit_seq += 1;
    }
}
/// After the connection was lost around COMMIT: reconnects and reads
/// `commit_seq`, which every transaction advances by exactly one, to learn
/// whether the transaction landed. Landed is success. Not landed leaves
/// the Store on its new connection with nothing saved, which still fences
/// for now. When no reconnect succeeds the outcome stays unknown.
fn settleLostCommit(self: *Mysql) Failure!void {
    const s = self.state;
    const owner = self.reconnect() catch return error.CommitOutcomeUnknown;
    s.endTransaction();
    s.long_query = false;
    s.prefix_results = 0;
    s.fence_result = 0;
    s.pass_failure = null;
    const err: Failure = if (owner.epoch != s.epoch)
        error.OwnershipLost
    else if (owner.commit_seq == s.commit_seq + 1) {
        s.failure = null;
        s.commit_seq += 1;
        return;
    } else if (owner.commit_seq == s.commit_seq)
        error.StoreConnectionLost
    else
        error.OwnershipLost;
    s.failure = err;
    return err;
}

/// Replaces the lost connection with a new one that holds the Store's
/// lock again, and returns the ownership row it read.
fn reconnect(self: *Mysql) !mysql_open.Reclaimed {
    const s = self.state;
    const login = &(s.login orelse return error.StoreConnectionLost);
    s.connection.disconnect();
    var attempt: u8 = 0;
    while (attempt < reconnect_attempts) : (attempt += 1) {
        if (attempt != 0) s.io.sleep(.fromSeconds(1), .awake) catch {};
        var refusal_buffer: [1024]u8 = undefined;
        var refusal = std.Io.Writer.fixed(&refusal_buffer);
        s.connection.reopen(login.options(), &refusal) catch continue;
        const owner = mysql_open.reclaim(&s.connection, login.database.slice(), &s.store_id, s.connection_id) catch |err| switch (err) {
            // Another server or Store, or one admission refuses: no retry helps.
            error.WrongStoreIdentity, error.UnsupportedMysqlVersion, error.MysqlReadOnly, error.MysqlDurabilityTooWeak, error.MysqlStatementBinlog => return error.StoreConnectionLost,
            else => continue,
        };
        s.connection_id = owner.connection_id;
        if (is_test) s.testing_shape.reconnects += 1;
        return owner;
    }
    return error.StoreConnectionLost;
}

pub fn inTransaction(self: *const Mysql) bool {
    return self.state.begin != .none;
}
/// Every MySQL transaction is a write transaction.
pub fn inWriteTransaction(self: *const Mysql) bool {
    return self.inTransaction();
}
pub fn totalChanges(self: *const Mysql) i64 {
    return self.state.changes;
}
pub fn releaseEntry(_: *Mysql) void {}
pub fn readRaw(self: *Mysql, id: u64, offset: u64, destination: []u8) Failure!void {
    try self.check();
    content.readRaw(&self.state.connection, id, offset, destination, self.contentObserver()) catch |err| {
        if (err == error.StoreConnectionLost) self.state.failure = err;
        return err;
    };
}
/// A sink on the payload of the content row `id`, whose chunk INSERTs
/// ride `host`'s batches (`content.Host`).
pub fn openSink(self: *Mysql, id: u64, length: u64, host: content.Host) Failure!ContentSink {
    try self.check();
    return content.openSink(&self.state.sink, id, length, host);
}

/// Whether the open batch has room for a chunk INSERT of `n` payload
/// bytes, with the transaction's opening statements if they are due.
pub fn chunkFits(self: *Mysql, id: u64, index: u64, n: usize) bool {
    const controls = 256;
    if (self.state.long_query) return false;
    return content.chunkStatementBytes(id, index, n) + controls <= self.state.connection.batchRoom();
}

/// Begins a chunk INSERT in the open batch, after any opening statements
/// due, and returns the batch's writer with the text up to its payload
/// written: the sink writes the payload's hex and the suffix. `chunkFits`
/// was true.
pub fn beginChunk(self: *Mysql, id: u64, index: u64) Failure!*std.Io.Writer {
    try self.check();
    try self.appendControls();
    const w = self.state.connection.batch();
    w.print(content.insert_prefix, .{ id, index }) catch return error.BindFailed;
    return w;
}

pub fn writePayload(self: *Mysql, id: u64, bytes: []const u8) Failure!void {
    try self.check();
    var at: usize = 0;
    while (at < bytes.len) {
        const n = @min(content.chunk_bytes, bytes.len - at);
        const args: insert_chunk.Args = .{ .content_id = id, .chunk_index = at / content.chunk_bytes, .bytes = .{ .bytes = bytes[at..][0..n] } };
        try self.bind(insert_chunk, &args, 0);
        try self.startPass();
        if (try self.stepWrite() != 1) return error.CorruptStore;
        try self.finishPass();
        at += n;
    }
}

pub const Diagnostic = struct { doublewrite: Bounded(32), queries: u64, state_bytes: usize };
pub fn diagnostic(self: *const Mysql) Diagnostic {
    return .{ .doublewrite = self.state.doublewrite, .queries = self.state.connection.queries, .state_bytes = @sizeOf(State) };
}

test "MySQL error mapping clears only lost transactions" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{ .connection = undefined, .begin = .{ .sent = .{ .savepoint = true } } };
    state.connection.writer.end = 0;
    var mysql: Mysql = .{ .state = state };
    try std.testing.expectEqual(error.StatementFailed, mysql.serverError(1062));
    try std.testing.expect(mysql.inTransaction());
    try std.testing.expectEqual(error.CanonicalStorageFull, mysql.serverError(1114));
    try std.testing.expectEqual(error.CanonicalStorageFull, mysql.serverError(1021));
    try std.testing.expectEqual(error.StatementFailed, mysql.serverError(1213));
    try std.testing.expect(!mysql.inTransaction());
    // The aborted transaction leaves no sent BEGIN behind: the next
    // transaction's unsent BEGIN still rolls back without the server.
    try mysql.control(.begin);
    try mysql.control(.rollback);
    try std.testing.expect(!mysql.inTransaction());
    try std.testing.expectEqual(@as(u64, 0), state.testing_shape.controls);
    state.begin = .{ .sent = .{} };
    try std.testing.expectEqual(error.StatementFailed, mysql.serverError(1305));
    try std.testing.expect(!mysql.inTransaction());
}

test "MySQL unsent transaction and savepoint rollbacks do not contact server" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{ .connection = undefined };
    state.connection.writer.end = 0;
    var mysql: Mysql = .{ .state = state };
    try mysql.control(.begin);
    try std.testing.expect(mysql.inTransaction());
    try std.testing.expect(state.begin == .pending);
    try mysql.control(.rollback);
    try std.testing.expect(!mysql.inTransaction());
    state.begin = .{ .sent = .{} };
    try mysql.control(.savepoint);
    try mysql.control(.rollback_to);
    try std.testing.expect(mysql.inTransaction());
    try std.testing.expect(state.replacement == .none);
    try mysql.control(.release);
}

test "MySQL connection loss distinguishes ambiguous commit and latches first fault" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{ .connection = undefined };
    var mysql: Mysql = .{ .state = state };
    try std.testing.expectEqual(error.StoreConnectionLost, mysql.lost());
    try std.testing.expectError(error.StoreConnectionLost, mysql.check());
    state.failure = null;
    state.committing = true;
    try std.testing.expectEqual(error.CommitOutcomeUnknown, mysql.lost());
    try std.testing.expectError(error.CommitOutcomeUnknown, mysql.check());
}

test "MySQL ordinary deferred failures report once and never block rollback" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{ .connection = undefined, .failure = error.StatementFailed };
    state.connection.writer.end = 0;
    var mysql: Mysql = .{ .state = state };
    try std.testing.expectError(error.StatementFailed, mysql.check());
    try mysql.check();
    state.failure = error.ContentWriteFailed;
    try mysql.control(.rollback);
    try std.testing.expectEqual(null, state.failure);
    state.failure = error.OwnershipLost;
    try std.testing.expectError(error.OwnershipLost, mysql.control(.rollback));
    try std.testing.expectError(error.OwnershipLost, mysql.check());
}

test "MySQL discarding an unsent replacement savepoint does not rollback an older one" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{ .connection = undefined, .begin = .{ .sent = .{ .savepoint = true } }, .replacement = .buffered };
    state.connection.writer.end = 20;
    var mysql: Mysql = .{ .state = state };
    try mysql.discardBatch();
    try std.testing.expect(state.replacement == .pending);
    try mysql.control(.rollback_to);
    try std.testing.expect(mysql.inTransaction());
    try std.testing.expectEqual(@as(usize, 0), state.connection.writer.end);
}

test "MySQL discarding a sent long query propagates and latches connection loss" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{ .connection = undefined, .long_query = true };
    state.connection.lost = true;
    var mysql: Mysql = .{ .state = state };
    try std.testing.expectError(error.StoreConnectionLost, mysql.discardBatch());
    try std.testing.expectError(error.StoreConnectionLost, mysql.check());
    try std.testing.expectError(error.StoreConnectionLost, mysql.control(.rollback));
}

test "MySQL content observer shares transaction error transitions" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{ .connection = undefined, .begin = .{ .sent = .{} } };
    var mysql: Mysql = .{ .state = state };
    const observer = mysql.contentObserver();
    observer.server_error(observer.context, 1062);
    try std.testing.expect(mysql.inTransaction());
    observer.server_error(observer.context, 1213);
    try std.testing.expect(!mysql.inTransaction());
    try std.testing.expect(!mysql.inWriteTransaction());
}

test "MySQL content query shape counts causes independently of wire sends" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{ .connection = undefined };
    var mysql: Mysql = .{ .state = state };
    const observer = mysql.contentObserver();
    observer.content_query(observer.context);
    observer.content_query(observer.context);
    try std.testing.expectEqual(@as(u64, 2), state.testing_shape.content_queries);
    try std.testing.expectEqual(@as(u64, 0), state.testing_shape.controls);
    try std.testing.expectEqual(@as(u64, 0), state.testing_shape.prefix_only);
    try std.testing.expectEqual(@as(u64, 0), state.testing_shape.access_passes);
    try std.testing.expectEqual(@as(u64, 0), state.testing_shape.identity_passes);
}
