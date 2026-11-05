//! MySQL's single-owner, blocking Store connection. Large buffers live out of line.
const std = @import("std");
const engine = @import("../engine.zig");
const Store = @import("../Store.zig");
const protocol = @import("../../protocol.zig");
const rsql = @import("../rsql.zig");
const wire = @import("../wire/mysql_connection.zig");
const row_decoder = @import("../mysql_row.zig");
const literal = @import("../mysql_literal.zig");
const content = @import("mysql_content.zig");
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
};

state: *State,

pub const State = struct {
    connection: wire.Connection,
    testing_shape: if (is_test) QueryShape else void = if (is_test) .{} else {},
    served: *const protocol.Routes = &unserved,
    epoch: u64 = 0,
    commit_seq: u64 = 0,
    changes: i64 = 0,
    failure: ?Failure = null,
    pass_failure: ?Failure = null,
    kinds: []row_decoder.Kind = &.{},
    column_count: usize = 0,
    statement_done: bool = false,
    long_query: bool = false,
    transaction: bool = false,
    write_transaction: bool = false,
    pending_begin: bool = false,
    pending_savepoint: bool = false,
    savepoint_sent: bool = false,
    prefix_results: u8 = 0,
    committing: bool = false,
    sink: content.SinkState = .{},
    doublewrite: protocol.Bounded(32) = .{},
    testing_database: if (is_test) [40]u8 else void = if (is_test) @splat(0) else {},
    begin_sent: bool = false,
    savepoint_queued: bool = false,
    fence_result: u8 = 0,
};
const unserved = protocol.routesAll(.unserved);
pub const ContentSink = content.ContentSink;
pub const insert_chunk = rsql.Write(.{
    .sql = "INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES(?1,?2,?3)",
    .Args = struct { content_id: u64, chunk_index: u64, bytes: rsql.Bytes },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

pub fn open(io: std.Io, options: wire.Options, selector: []const u8, store_options: Store.OpenOptions) !Mysql {
    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    state.* = .{ .connection = undefined };
    var refusal_buffer: [1024]u8 = undefined;
    var refusal = std.Io.Writer.fixed(&refusal_buffer);
    try state.connection.open(options, &refusal);
    const opened = try @import("mysql_open.zig").open(&state.connection, io, .{ .database = options.database, .found_schema_version = store_options.found_schema_version }, selector);
    state.doublewrite = opened.doublewrite;
    state.epoch = opened.epoch;
    state.commit_seq = opened.commit_seq;
    return .{ .state = state };
}

pub fn close(self: *Mysql) error{StoreCloseFailed}!void {
    self.state.sink.close();
    const failed = self.state.failure != null;
    self.state.connection.close();
    allocator.free(self.state.kinds);
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
    if (code == 1213 or code == 1305) {
        self.state.transaction = false;
        self.state.write_transaction = false;
    }
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
    if (s.pending_begin) {
        s.connection.batch().print("START TRANSACTION;UPDATE store_owner SET commit_seq=commit_seq+1 WHERE owner_key=1 AND epoch={d} AND commit_seq={d};", .{ s.epoch, s.commit_seq }) catch return error.BindFailed;
        s.prefix_results += 2;
        s.fence_result = 2;
        s.pending_begin = false;
    }
    if (s.pending_savepoint) {
        s.connection.batch().writeAll("SAVEPOINT rui_write;") catch return error.BindFailed;
        s.prefix_results += 1;
        s.pending_savepoint = false;
        s.savepoint_queued = true;
    }
}

pub fn startPass(self: *Mysql) Failure!void {
    try self.check();
    if (!self.state.long_query and self.state.connection.batchLen() != 0) {
        self.state.connection.sendBatch() catch return self.lost();
        if (self.state.fence_result != 0) self.state.begin_sent = true;
        if (self.state.savepoint_queued) {
            self.state.savepoint_sent = true;
            self.state.savepoint_queued = false;
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
pub fn discardBatch(self: *Mysql) void {
    // Revert only controls appended but never sent. In particular, an older
    // server-side savepoint must not be mistaken for the dropped new one.
    if (self.state.savepoint_queued) self.state.pending_savepoint = true;
    if (self.state.fence_result != 0 and !self.state.begin_sent) self.state.pending_begin = true;
    self.state.connection.writer.end = 0;
    self.state.long_query = false;
    self.state.prefix_results = 0;
    self.state.fence_result = 0;
    self.state.savepoint_queued = false;
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
    } else try self.check();
    switch (which) {
        .begin => {
            self.state.pending_begin = true;
            self.state.transaction = true;
            self.state.write_transaction = true;
            return;
        },
        .savepoint => {
            self.state.pending_savepoint = true;
            return;
        },
        .release => return,
        .rollback => if (!self.state.begin_sent) {
            self.discardBatch();
            self.state.pending_begin = false;
            self.state.pending_savepoint = false;
            self.state.transaction = false;
            self.state.write_transaction = false;
            return;
        },
        .rollback_to => if (!self.state.savepoint_sent or self.state.pending_savepoint or self.state.savepoint_queued) {
            self.discardBatch();
            self.state.pending_savepoint = false;
            return;
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
    self.state.connection.query(text) catch return self.lost();
    _ = self.stepWrite() catch |err| {
        if (which == .rollback or which == .rollback_to) return error.CanonicalRollbackFailed;
        return err;
    };
    if (which == .commit or which == .rollback) {
        self.state.transaction = false;
        self.state.write_transaction = false;
        self.state.savepoint_sent = false;
        self.state.begin_sent = false;
        if (which == .commit) self.state.commit_seq += 1;
    }
}
pub fn inTransaction(self: *const Mysql) bool {
    return self.state.transaction;
}
pub fn inWriteTransaction(self: *const Mysql) bool {
    return self.state.write_transaction;
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
pub fn openSink(self: *Mysql, id: u64, length: u64) Failure!ContentSink {
    return content.openSink(self, id, length, self.contentObserver());
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

pub const Diagnostic = struct { doublewrite: protocol.Bounded(32), queries: u64, state_bytes: usize };
pub fn diagnostic(self: *const Mysql) Diagnostic {
    return .{ .doublewrite = self.state.doublewrite, .queries = self.state.connection.queries, .state_bytes = @sizeOf(State) };
}

test "MySQL error mapping clears only lost transactions" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{ .connection = undefined, .transaction = true, .write_transaction = true };
    var mysql: Mysql = .{ .state = state };
    try std.testing.expectEqual(error.StatementFailed, mysql.serverError(1062));
    try std.testing.expect(mysql.inTransaction());
    try std.testing.expectEqual(error.CanonicalStorageFull, mysql.serverError(1114));
    try std.testing.expectEqual(error.CanonicalStorageFull, mysql.serverError(1021));
    try std.testing.expectEqual(error.StatementFailed, mysql.serverError(1213));
    try std.testing.expect(!mysql.inTransaction());
    state.transaction = true;
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
    try std.testing.expect(state.pending_begin);
    try mysql.control(.rollback);
    try std.testing.expect(!mysql.inTransaction());
    state.transaction = true;
    state.begin_sent = true;
    try mysql.control(.savepoint);
    try mysql.control(.rollback_to);
    try std.testing.expect(mysql.inTransaction());
    try std.testing.expect(!state.pending_savepoint);
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
    state.* = .{ .connection = undefined, .transaction = true, .begin_sent = true, .savepoint_sent = true, .savepoint_queued = true };
    state.connection.writer.end = 20;
    var mysql: Mysql = .{ .state = state };
    mysql.discardBatch();
    try std.testing.expect(state.pending_savepoint);
    try mysql.control(.rollback_to);
    try std.testing.expect(mysql.inTransaction());
    try std.testing.expectEqual(@as(usize, 0), state.connection.writer.end);
}

test "MySQL content observer shares transaction error transitions" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.* = .{ .connection = undefined, .transaction = true, .write_transaction = true };
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
