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
    /// From COMMIT's send until its own OK: a loss then leaves the outcome
    /// to `settleLostCommit`.
    committing: bool = false,
    /// COMMIT's place among the pass's prefix results, counted down as
    /// `fence_result` is; 0 when the pass holds no COMMIT.
    commit_result: u8 = 0,
    /// Where COMMIT's text ends in the batch that holds it, and where that
    /// batch ended when sent: the reads after COMMIT lie between.
    commit_end: usize = 0,
    batch_end: usize = 0,
    /// A COMMIT bound after the writes of its message (`appendCommit`):
    /// `buffered` until that message is sent, `sent` until COMMIT's OK or
    /// a server error, which stops the message before it. `settleCommit`
    /// ends whatever is left.
    inline_commit: enum { none, buffered, sent } = .none,
    /// Whether the open batch holds a write that needs a guard and has
    /// none (`guard`): COMMIT then takes a message of its own.
    unguarded: bool = false,
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
    /// Whether the Queue may run the current attempt again, so a lost
    /// connection defers its fence to `recover` (`queue.Batch.arm`).
    armed: bool = false,
    /// The connection was lost while armed, so `recover` may run the
    /// attempt again. A loss after a COMMIT's OK never is: the batch is saved.
    rerunnable: bool = false,
    /// A reconnect already replaced the lost connection, finding nothing
    /// saved (`settleLostCommit`).
    replaced: bool = false,
    /// Tests: lose the connection before every armed COMMIT, so each batch
    /// runs twice.
    testing_drop_armed: if (is_test) bool else void = if (is_test) false else {},
    /// Tests: where the next COMMIT loses its connection.
    testing_drop: if (is_test) enum { none, before_commit, after_commit, next_pass } else void = if (is_test) .none else {},

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
/// wiped. Trust is already loaded in the connection and is never borrowed
/// from this login; reconnect options do not retain a CA file path.
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
                // `reopen` uses its retained TLS context, not this trust value.
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
    if (self.state.connection.isReady() and self.state.connection.batchLen() == 0) mysql_open.releaseLock(&self.state.connection);
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
    self.state.rerunnable = self.state.armed;
    return err;
}

pub fn next(self: *Mysql) Failure!wire.mysql.Event {
    return self.state.connection.next() catch return self.lost();
}

fn serverError(self: *Mysql, code: u16) Failure {
    // The server runs nothing of a message after a statement that failed,
    // so a COMMIT bound after it never ran.
    if (self.state.inline_commit != .none) {
        self.state.inline_commit = .none;
        self.state.committing = false;
    }
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
    const reserved: usize = if (comptime S.kind == .write and S.guarded) guard_bytes else 0;
    return self.state.connection.batchLen() == 0 or n + 1 + reserved <= self.state.connection.batchRoom();
}

/// The most a write's guard takes in a batch (`guard`).
const guard_bytes = 112;
const guard_text = "DO (SELECT 1 FROM (SELECT 1 AS x UNION ALL SELECT 2) g WHERE g.x=1 OR ";

/// Binds, after the write just bound into the open transaction's batch, a
/// statement that fails unless that write changed exactly `rows` rows, or
/// at most `rows`: its subquery then returns two rows, error 1242. The
/// server runs nothing of a message after a failed statement, so a COMMIT
/// in the same message (`appendCommit`) never saves a write whose count
/// was wrong. True when the guard was bound, and its OK follows the
/// write's; false for a write sent alone as a long query, or one the
/// batch had no room to guard, whose count only its step checks: no
/// COMMIT joins either (`appendCommit`).
pub fn guard(self: *Mysql, comptime at_most: bool, rows: u64) bool {
    const s = self.state;
    if (s.long_query or s.begin == .none) return false;
    if (guard_bytes > s.connection.batchRoom()) {
        s.unguarded = true;
        return false;
    }
    s.connection.batch().print(guard_text ++ "ROW_COUNT()" ++ (if (at_most) ">" else "<>") ++ "{d});", .{rows}) catch unreachable;
    return true;
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
        // The fence is guarded as a write is (`guard`), so a COMMIT that
        // shares the transaction's first message never saves past it.
        s.connection.batch().print("START TRANSACTION;UPDATE store_owner SET commit_seq=commit_seq+1 WHERE owner_key=1 AND epoch={d} AND commit_seq={d};" ++ guard_text ++ "ROW_COUNT()<>1);", .{ s.epoch, s.commit_seq }) catch return error.BindFailed;
        s.prefix_results += 3;
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
    self.sendPass() catch |err| {
        // The pass's steps are still to come: `settleCommit` follows them.
        if (self.state.inline_commit != .none) return err;
        if (err == error.CommitOutcomeUnknown) return self.settleLostCommit();
        // A COMMIT that never ran leaves the transaction open, for rollback.
        self.state.committing = false;
        self.state.commit_result = 0;
        return err;
    };
}

fn sendPass(self: *Mysql) Failure!void {
    try self.check();
    if (is_test and (self.state.testing_drop == .next_pass or ((self.state.commit_result != 0 or self.state.inline_commit != .none) and
        (self.state.testing_drop == .before_commit or (self.state.testing_drop_armed and self.state.armed)))))
    {
        self.state.testing_drop = .none;
        self.state.connection.disconnect();
    }
    if (!self.state.long_query and self.state.connection.batchLen() != 0) {
        self.state.batch_end = self.state.connection.writer.end;
        self.state.connection.sendBatch() catch return self.lost();
        if (self.state.inline_commit == .buffered) self.state.inline_commit = .sent;
        if (is_test and self.state.inline_commit == .sent and self.state.testing_drop == .after_commit) {
            // The server ran the whole message; every answer is lost.
            self.state.testing_drop = .none;
            while (!self.state.connection.isReady()) _ = self.state.connection.next() catch break;
            self.state.connection.disconnect();
        }
        if (self.state.begin == .buffered) self.state.begin = .{ .sent = .{} };
        if (self.state.replacement == .buffered) {
            self.state.replacement = .none;
            self.state.begin.sent.savepoint = true;
        }
    }
    while (self.state.prefix_results != 0) {
        const fence = self.state.fence_result == 1;
        const commit = self.state.commit_result == 1;
        if (is_test and commit and self.state.testing_drop == .after_commit) {
            // The server has committed; only its OK is lost.
            self.state.testing_drop = .none;
            _ = self.state.connection.next() catch {};
            self.state.connection.disconnect();
        }
        const changed = try self.stepWrite();
        self.state.prefix_results -= 1;
        self.state.fence_result -|= 1;
        self.state.commit_result -|= 1;
        if (fence and changed != 1) {
            self.state.failure = error.OwnershipLost;
            return error.OwnershipLost;
        }
        if (commit) self.committed();
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
/// COMMIT's own OK arrived: the transaction is saved, and the batch has
/// nothing left to run again.
fn committed(self: *Mysql) void {
    const s = self.state;
    s.committing = false;
    s.endTransaction();
    s.commit_seq += 1;
    s.armed = false;
}

pub fn finishPass(self: *Mysql) Failure!void {
    defer {
        self.state.unguarded = false;
        self.state.long_query = false;
        self.state.prefix_results = 0;
        self.state.fence_result = 0;
        self.state.commit_result = 0;
        self.state.committing = false;
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
    self.state.unguarded = false;
    self.state.long_query = false;
    self.state.prefix_results = 0;
    self.state.fence_result = 0;
    self.state.commit_result = 0;
    self.state.committing = false;
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
    if (which == .commit) {
        try self.queueCommit();
        try self.startPass();
        return self.finishPass();
    }
    try self.appendControls();
    if (self.state.connection.batchLen() != 0) {
        try self.startPass();
        try self.finishPass();
    }
    const text = comptime switch (which) {
        .rollback => "ROLLBACK",
        .rollback_to => "ROLLBACK TO SAVEPOINT rui_write",
        else => unreachable,
    };
    if (is_test) self.state.testing_shape.controls += 1;
    self.state.connection.query(text) catch return self.lost();
    _ = self.stepWrite() catch return error.CanonicalRollbackFailed;
    if (which == .rollback) self.state.endTransaction();
}

/// Queues COMMIT as the open transaction's next statement. Reads bound
/// after it share its message and run in autocommit once it has
/// committed; the next `startPass` sends them. COMMIT's own OK marks the
/// transaction saved. A connection lost before that OK is settled by
/// reconnecting (`settleLostCommit`), which sends the reads again when the
/// transaction landed; one lost after it, while the reads stream, is
/// `StoreConnectionLost` with the commit known, and fences.
pub fn queueCommit(self: *Mysql) Failure!void {
    try self.check();
    std.debug.assert(self.state.begin != .none and self.state.commit_result == 0);
    // Statements bound before it run in a pass of their own, so COMMIT's
    // result is a prefix result, as BEGIN's and the fence's are.
    if (self.state.long_query or self.state.connection.batchLen() != 0) {
        try self.startPass();
        try self.finishPass();
    }
    try self.appendControls();
    self.state.connection.batch().writeAll("COMMIT;") catch return error.BindFailed;
    self.state.commit_end = self.state.connection.writer.end;
    self.state.prefix_results += 1;
    self.state.commit_result = self.state.prefix_results;
    self.state.committing = true;
    if (is_test) self.state.testing_shape.controls += 1;
}

/// Binds COMMIT after the writes already in the open transaction's batch,
/// so its last writes and its COMMIT are one message: each write's guard
/// (`guard`) stops the message before COMMIT when its count is wrong, as
/// any failed statement does, the fence's guard included when the message
/// opens the transaction too. False, with nothing bound, when the batch
/// cannot take it: then `queueCommit` commits.
/// `stepCommit` steps its answer after the writes', and `settleCommit`
/// follows the pass.
pub fn appendCommit(self: *Mysql) bool {
    const s = self.state;
    std.debug.assert(s.inline_commit == .none);
    if (s.failure != null or s.long_query or s.unguarded or s.commit_result != 0) return false;
    if (s.begin == .none or s.begin == .pending or 8 > s.connection.batchRoom()) return false;
    s.connection.batch().writeAll("COMMIT;") catch return false;
    s.commit_end = s.connection.writer.end;
    s.committing = true;
    s.inline_commit = .buffered;
    return true;
}

/// Steps `appendCommit`'s answer: the transaction is saved.
pub fn stepCommit(self: *Mysql) Failure!void {
    const s = self.state;
    _ = try self.stepWrite();
    s.inline_commit = .none;
    self.committed();
}

/// After the pass that held `appendCommit`'s COMMIT. Nothing is left to
/// settle once COMMIT's OK arrived, or a server error stopped the message
/// before it, or the message was never sent: the transaction is saved, or
/// still open. A connection lost in between is settled as any lost COMMIT
/// (`settleLostCommit`): saved is success, and not saved is
/// `StoreConnectionLost` on a new connection. A message the server ran
/// whole while a step here failed is `CommitOutcomeUnknown`, and fences:
/// the server saved what the Host refused.
pub fn settleCommit(self: *Mysql) Failure!void {
    const s = self.state;
    const state = s.inline_commit;
    s.inline_commit = .none;
    if (state == .none) return;
    if (s.failure) |err| {
        if (err != error.CommitOutcomeUnknown) return err;
        // Nothing follows COMMIT in its message.
        s.batch_end = s.commit_end;
        return self.settleLostCommit();
    }
    s.committing = false;
    if (state == .buffered) return;
    s.failure = error.CommitOutcomeUnknown;
    return error.CommitOutcomeUnknown;
}

/// After the connection was lost around COMMIT: reconnects and reads
/// `commit_seq`, which every transaction advances by exactly one, to learn
/// whether the transaction landed. Landed is success, and the reads that
/// followed COMMIT in its message are sent again, since the lost
/// connection took their answers. Not landed leaves the Store on its new
/// connection with nothing saved, which still fences for now. When no
/// reconnect succeeds the outcome stays unknown.
fn settleLostCommit(self: *Mysql) Failure!void {
    const s = self.state;
    // The reconnect reuses the send buffer, so the reads are copied first.
    const sent = s.connection.send_buffer[s.commit_end..s.batch_end];
    const reads: ?[]const u8 = if (sent.len == 0) "" else allocator.dupe(u8, sent) catch null;
    defer if (reads) |text| allocator.free(text);
    const owner = self.reconnect() catch return error.CommitOutcomeUnknown;
    s.endTransaction();
    s.long_query = false;
    s.prefix_results = 0;
    s.fence_result = 0;
    s.commit_result = 0;
    s.committing = false;
    s.pass_failure = null;
    const err: Failure = if (owner.epoch != s.epoch)
        error.OwnershipLost
    else if (owner.commit_seq == s.commit_seq + 1) {
        s.failure = null;
        // The fence's row at least, whose answer the loss may have taken:
        // the entry point changed the Store (`Entry.release`).
        s.changes +|= 1;
        s.commit_seq += 1;
        s.armed = false;
        return self.sendAgain(reads);
    } else if (owner.commit_seq == s.commit_seq) blk: {
        s.replaced = true;
        break :blk error.StoreConnectionLost;
    } else error.OwnershipLost;
    s.failure = err;
    return err;
}

/// Sends `reads`, the statements that followed a COMMIT now known saved,
/// on the new connection. Null is a copy that could not be kept. A failure
/// keeps the commit and fences, so the batch never runs again.
fn sendAgain(self: *Mysql, reads: ?[]const u8) Failure!void {
    const s = self.state;
    s.statement_done = false;
    const text = reads orelse return self.lost();
    if (text.len == 0) return;
    // A failover may reach a server whose packets are smaller.
    if (text.len > s.connection.batchRoom()) return self.lost();
    s.connection.batch().writeAll(text) catch return self.lost();
    s.connection.sendBatch() catch return self.lost();
}

/// Whether a fence now would end an attempt the Queue can still run again
/// on a new connection: the connection was lost while armed.
pub fn defersFence(self: *const Mysql) bool {
    const s = self.state;
    return s.armed and s.rerunnable and s.login != null and s.failure != null and s.failure.? == error.StoreConnectionLost;
}

/// After an armed attempt that lost its connection: replaces it, unless a
/// lost COMMIT already did, and answers whether nothing was saved, so the
/// attempt may run again. Otherwise the loss stays, and fences.
pub fn recover(self: *Mysql) bool {
    const s = self.state;
    defer s.replaced = false;
    if (!s.rerunnable or s.login == null or s.failure == null or s.failure.? != error.StoreConnectionLost) return false;
    if (!s.replaced) {
        const owner = self.reconnect() catch return false;
        if (owner.epoch != s.epoch or owner.commit_seq != s.commit_seq) {
            s.failure = error.OwnershipLost;
            return false;
        }
    }
    s.endTransaction();
    s.sink.close();
    s.long_query = false;
    s.prefix_results = 0;
    s.fence_result = 0;
    s.pass_failure = null;
    s.statement_done = false;
    s.committing = false;
    s.commit_result = 0;
    s.inline_commit = .none;
    s.unguarded = false;
    s.rerunnable = false;
    s.failure = null;
    return true;
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
        const owner = mysql_open.reclaim(&s.connection, login.database.slice(), &s.store_id, s.epoch, s.connection_id) catch |err| switch (err) {
            // Another server, Store or owner, or one admission refuses: no retry helps.
            error.WrongStoreIdentity, error.OwnershipLost, error.StoreLocked, error.MysqlTooOld, error.MysqlIsMariadb, error.MysqlReadOnly, error.MysqlFlushLogUnsafe, error.MysqlSyncBinlogUnsafe, error.MysqlStatementBinlog => return error.StoreConnectionLost,
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
        if (err == error.StoreConnectionLost) _ = @errorName(self.lost());
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
    const controls = 384;
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

test {
    _ = mysql_open;
}

test "mysql reconnect login owns its credentials even with ssl-ca trust" {
    var login = copied: {
        const url = try @import("../../mysql_url.zig").create(std.testing.allocator, "mysql://u:secret@db.example.com:3307/db?ssl-ca=/private/ca.pem");
        defer url.destroy();
        const login = Login.of(url.options()) orelse return error.TestUnexpectedResult;
        url.wipe();
        break :copied login;
    };
    defer std.crypto.secureZero(u8, std.mem.asBytes(&login));
    const options = login.options();
    try std.testing.expectEqualStrings("db.example.com", options.address.tcp_tls.host);
    try std.testing.expectEqual(@as(u16, 3307), options.address.tcp_tls.port);
    try std.testing.expectEqualStrings("u", options.user);
    try std.testing.expectEqualStrings("secret", options.password);
    try std.testing.expectEqualStrings("db", options.database);
    // The connection, not these options, owns the trust used by `reopen`.
    try std.testing.expect(options.address.tcp_tls.trust == .system);
}
