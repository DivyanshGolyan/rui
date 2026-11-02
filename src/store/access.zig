//! Access: the statements of one locked transition, run in rounds. A
//! transition queues typed reads, ends the round with `run`, decides in
//! plain Zig, then queues its writes and ends with `commit`. It never
//! writes BEGIN, COMMIT, a row-count check or a position claim itself.
//!
//! The engine is the Store's SQLite connection. A statement is bound when
//! queued and stepped when its round runs, so a destination is defined only
//! after `run`, as it will be on a network engine.

const std = @import("std");
const change_ring = @import("../change_ring.zig");
const store_core = @import("Store.zig");
const Store = store_core.Store;
const rsql = @import("rsql.zig");
const sqlite = @import("sqlite.zig");
const c = sqlite.c;

pub const Mode = enum {
    /// Reads only, outside any transaction.
    read,
    /// Opens the transaction before its first statement and ends it with
    /// `commit`, or with `abandon` when it finds no work or fails.
    write,
    /// Writes inside a transaction its caller opened, and ends with `apply`:
    /// how unconverted code runs a rule that has an Access form.
    nested,
};

/// What a round reports besides its guards' errors. Each one fences.
pub const Failure = error{
    BindFailed,
    IntegerOutOfRange,
    StatementPrepareFailed,
    OutOfMemory,
    StatementFailed,
    CanonicalStorageFull,
    CanonicalRollbackFailed,
    CorruptStore,
    ContentWriteFailed,
    SqliteExecFailed,
    ClockReadFailed,
    SessionPositionExhausted,
    IdentityExhausted,
    IdentityOutsideTransaction,
    IdentityReadFailed,
    TooManyPositionClaims,
    RoundFull,
    StatementQueuedTwice,
};

/// A Session's positions claimed by one Access, from its head as a round
/// read it. `commit` (or `apply`) advances `next_position` once, by a
/// compare-and-set against that head.
pub const Positions = struct {
    head: rsql.SessionHead,
    taken: u64 = 0,

    /// Claims `count` consecutive positions and returns the first.
    pub fn take(self: *Positions, count: u64) error{SessionPositionExhausted}!u64 {
        const first = self.head.next_position.get() + self.taken;
        if (first > std.math.maxInt(i64) - count) return error.SessionPositionExhausted;
        self.taken += count;
        return first;
    }
};

/// The one compare-and-set on `next_position` for converted code.
const advance = rsql.Write(.{
    .sql = "UPDATE session SET next_position=?3 WHERE session_ref=@session(?1) AND next_position=?2",
    .Args = struct { session: rsql.SessionHead, expected: u64, next: u64 },
    // The head was read in this transaction under the single writer.
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

pub fn Access(comptime mode: Mode, comptime Guards: type) type {
    return struct {
        const Self = @This();
        pub const Error = Guards || Failure;
        const max_queued = 8;

        store: *Store,
        opened: bool = false,
        /// Set by `commit` and `abandon`; `deinit` refuses a write Access
        /// that opened its transaction without either.
        ended: bool = false,
        /// The first failure; every later call does nothing and every round
        /// reports it.
        failure: ?Error = null,
        queue: [max_queued]Queued = undefined,
        queued: u8 = 0,
        /// None in a read Access, which claims no positions.
        claims: [if (mode == .read) 0 else max_claims]Positions = undefined,
        claimed: u8 = 0,

        /// No transition takes positions in more Sessions than the change
        /// ring tracks; touching more only degrades the ring's record.
        const max_claims = change_ring.Touched.max;

        const Queued = struct {
            run: *const fn (*Self, *const Queued) Error!void,
            /// Null for a content payload.
            statement: ?*c.sqlite3_stmt,
            target: union {
                /// A read's result.
                destination: *anyopaque,
                /// An `.each` read's visitor, and how many rows it may step.
                each: struct { visitor: *anyopaque, limit: u64 },
                payload: struct { content_id: u64, bytes: []const u8 },
                none: void,
            },
            /// The reference a write's @session binds, read in place when
            /// the round runs.
            session_ref: change_ring.Id = undefined,
        };

        /// An Access under `entry`'s lock.
        pub fn open(entry: *const store_core.Entry) Self {
            comptime std.debug.assert(mode != .nested);
            return .{ .store = entry.store };
        }

        /// How unconverted code, under an Entry it already holds, runs a
        /// rule that has an Access form. A `.nested` Access writes inside
        /// the transaction its caller opened, which is asserted; a `.read`
        /// one checks nothing.
        pub fn within(store: *Store) Self {
            comptime std.debug.assert(mode != .write);
            if (mode == .nested) std.debug.assert(c.sqlite3_get_autocommit(store.database) == 0);
            return .{ .store = store };
        }

        /// Queues a read; `destination` is defined once the round runs.
        pub fn read(a: *Self, comptime S: type, args: S.Args, destination: *S.Result) void {
            comptime std.debug.assert(S.kind == .read and S.cardinality != .each);
            a.queueStatement(S, &args, runRead(S), .{ .destination = destination }, null);
        }

        /// Queues an `.each` read whose round hands each row in turn to
        /// `visitor.visit(*const S.Row) bool`, until it returns false, the
        /// rows end, or `limit` rows were stepped. `visitor` must outlive
        /// the round.
        pub fn readEach(a: *Self, comptime S: type, args: S.Args, limit: u64, visitor: anytype) void {
            comptime std.debug.assert(S.kind == .read and S.cardinality == .each);
            a.queueStatement(S, &args, runEach(S, @TypeOf(visitor.*)), .{ .each = .{ .visitor = visitor, .limit = limit } }, null);
        }

        /// Ends the round: runs every queued statement in order.
        pub fn run(a: *Self) Error!void {
            for (a.queue[0..a.queued]) |*entry| {
                if (a.failure != null) break;
                entry.run(a, entry) catch |err| {
                    a.failure = err;
                };
                if (entry.statement) |statement| sqlite.resetCached(statement);
            }
            a.resetQueued();
            if (a.failure) |err| return err;
        }

        /// Records that this Access changes `head`'s Session, and returns
        /// its position claimer.
        pub fn positions(a: *Self, head: rsql.SessionHead) error{TooManyPositionClaims}!*Positions {
            comptime std.debug.assert(mode != .read);
            a.touch(head);
            for (a.claims[0..a.claimed]) |*claim| if (std.mem.eql(u8, &claim.head.ref, &head.ref)) return claim;
            if (a.claimed == a.claims.len) return error.TooManyPositionClaims;
            a.claims[a.claimed] = .{ .head = head };
            a.claimed += 1;
            return &a.claims[a.claimed - 1];
        }

        /// Queues a write, touching the Session its @session names. A
        /// failed guard fails the round that runs it.
        pub fn write(a: *Self, comptime S: type, args: S.Args) void {
            comptime std.debug.assert(S.kind == .write and mode != .read);
            const session: ?rsql.SessionHead = if (S.session_field) |field| @field(args, field) else null;
            if (session) |head| a.touch(head);
            a.queueStatement(S, &args, runWrite(S), .{ .none = {} }, if (session) |head| head.ref else null);
        }

        /// The next value of `column`, inside this transaction.
        pub fn identity(a: *Self, comptime column: store_core.Identity) !u64 {
            comptime std.debug.assert(mode != .read);
            a.ensureOpen();
            if (a.failure) |err| return err;
            return store_core.takeIdentity(a.store, column);
        }

        /// Queues writing `bytes` into the payload of the content row
        /// `content_id`, inserted by an earlier queued write. `bytes` must
        /// outlive the round.
        pub fn writeContent(a: *Self, content_id: u64, bytes: []const u8) void {
            comptime std.debug.assert(mode != .read);
            if (a.reserve()) |slot| {
                slot.* = .{ .statement = null, .run = runPayload, .target = .{ .payload = .{ .content_id = content_id, .bytes = bytes } } };
                a.queued += 1;
            }
        }

        /// Runs the queued writes and one compare-and-set per Session that
        /// claimed positions, then COMMIT. A failed guard stops before
        /// COMMIT.
        pub fn commit(a: *Self) Error!void {
            comptime std.debug.assert(mode == .write);
            try a.finishWrites();
            store_core.commit(a.store) catch |err| {
                a.failure = err;
                return err;
            };
            a.ended = true;
        }

        /// `commit` without COMMIT: the caller's transaction stays open.
        pub fn apply(a: *Self) Error!void {
            comptime std.debug.assert(mode == .nested);
            try a.finishWrites();
        }

        /// Ends a write Access without committing: drops what it queued
        /// and rolls back the transaction it opened, as the Entry would,
        /// `faults` included. A transition that finds no work calls it,
        /// and `end` calls it on every error.
        pub fn abandon(a: *Self, faults: store_core.Faults) Error!void {
            comptime std.debug.assert(mode == .write);
            a.resetQueued();
            a.claimed = 0;
            a.ended = true;
            if (a.opened) try store_core.rollbackAfterError(a.store, faults);
        }

        /// The transition's `result`, after abandoning the Access when it
        /// is an error. A write Access's entry point returns through it, so
        /// no exit leaves the transaction open; a failed rollback takes the
        /// error's place, and the Entry fences on it.
        pub fn end(a: *Self, faults: store_core.Faults, result: anytype) @TypeOf(result) {
            comptime std.debug.assert(mode == .write);
            _ = result catch |err| {
                a.abandon(faults) catch |failed| return failed;
                return err;
            };
            return result;
        }

        /// Clears statements queued but never run. A write Access that
        /// opened its transaction must have ended by now, in every build.
        pub fn deinit(a: *Self) void {
            a.resetQueued();
            if (mode == .write and a.opened and !a.ended) @panic("a write Access neither committed nor abandoned its transaction");
        }

        fn finishWrites(a: *Self) Error!void {
            a.ensureOpen();
            try a.run();
            for (a.claims[0..a.claimed]) |*claim| if (claim.taken != 0) {
                const expected = claim.head.next_position.get();
                a.queueStatement(advance, &.{ .session = claim.head, .expected = expected, .next = expected + claim.taken }, runWrite(advance), .{ .none = {} }, claim.head.ref);
                try a.run();
            };
            a.claimed = 0;
        }

        /// Opens the transaction of a write Access before its first
        /// statement. A network engine's ownership check (PR 8) joins
        /// `store_core.begin`.
        fn ensureOpen(a: *Self) void {
            if (a.opened or a.failure != null) return;
            a.opened = true;
            if (mode == .write) store_core.begin(a.store) catch |err| {
                a.failure = err;
            };
        }

        /// Records the change of `head`'s Session for the change ring. A
        /// fifth Session makes the record "everything", as `Store.touch`
        /// does; it never fails.
        fn touch(a: *Self, head: rsql.SessionHead) void {
            const touched = &a.store.touched;
            if (touched.needsEntry(&head.ref)) touched.add(.{ .session = head.ref, .workspace = head.workspace_key.get() });
        }

        fn queueStatement(a: *Self, comptime S: type, args: *const S.Args, runner: *const fn (*Self, *const Queued) Error!void, target: @FieldType(Queued, "target"), session_ref: ?change_ring.Id) void {
            a.ensureOpen();
            if (a.failure != null) return;
            const statement = store_core.cachedTyped(a.store, S) catch |err| {
                a.failure = err;
                return;
            };
            for (a.queue[0..a.queued]) |entry| if (entry.statement == statement) {
                a.failure = error.StatementQueuedTwice;
                return;
            };
            const now = if (S.uses_now) store_core.transactionSecond(a.store) catch |err| {
                a.failure = err;
                return;
            } else 0;
            const slot = a.reserve() orelse return;
            slot.* = .{ .statement = statement, .run = runner, .target = target };
            if (session_ref) |ref| slot.session_ref = ref;
            sqlite.bindArgs(statement, S, args, now, if (session_ref != null) &slot.session_ref else null) catch |err| {
                sqlite.resetCached(statement);
                a.failure = err;
                return;
            };
            a.queued += 1;
        }

        /// The next queue slot, or null after recording `RoundFull`.
        fn reserve(a: *Self) ?*Queued {
            if (a.failure != null) return null;
            if (a.queued == a.queue.len) {
                a.failure = error.RoundFull;
                return null;
            }
            return &a.queue[a.queued];
        }

        fn resetQueued(a: *Self) void {
            for (a.queue[0..a.queued]) |entry| if (entry.statement) |statement| sqlite.resetCached(statement);
            a.queued = 0;
        }

        fn runRead(comptime S: type) *const fn (*Self, *const Queued) Error!void {
            return &struct {
                fn run(_: *Self, entry: *const Queued) Error!void {
                    const statement = entry.statement.?;
                    const destination: *S.Result = @ptrCast(@alignCast(entry.target.destination));
                    // A read whose text allows one row takes no step to look for a second.
                    switch (S.cardinality) {
                        .one => {
                            if (!try nextRow(statement)) return error.CorruptStore;
                            try sqlite.decodeRow(S.Row, statement, destination);
                            if (!S.single_row and try nextRow(statement)) return error.CorruptStore;
                        },
                        .optional => {
                            if (!try nextRow(statement)) {
                                destination.* = null;
                                return;
                            }
                            // At most 1 KiB (`rsql.Read`), so the copy is small.
                            var row: S.Row = undefined;
                            try sqlite.decodeRow(S.Row, statement, &row);
                            destination.* = row;
                            if (!S.single_row and try nextRow(statement)) return error.CorruptStore;
                        },
                        .at_most => |max| {
                            destination.len = 0;
                            while (try nextRow(statement)) {
                                if (destination.len == max) return error.CorruptStore;
                                try sqlite.decodeRow(S.Row, statement, &destination.items[destination.len]);
                                destination.len += 1;
                                if (S.single_row) break;
                            }
                        },
                        .each => @compileError("readEach runs an .each read"),
                    }
                }
            }.run;
        }

        fn runEach(comptime S: type, comptime Visitor: type) *const fn (*Self, *const Queued) Error!void {
            return &struct {
                fn run(_: *Self, entry: *const Queued) Error!void {
                    const statement = entry.statement.?;
                    const each = entry.target.each;
                    const visitor: *Visitor = @ptrCast(@alignCast(each.visitor));
                    // At most 1 KiB (`rsql.Read`).
                    var row: S.Row = undefined;
                    var stepped: u64 = 0;
                    while (stepped < each.limit and try nextRow(statement)) : (stepped += 1) {
                        try sqlite.decodeRow(S.Row, statement, &row);
                        if (!visitor.visit(&row)) break;
                    }
                }
            }.run;
        }

        fn runWrite(comptime S: type) *const fn (*Self, *const Queued) Error!void {
            return &struct {
                fn run(a: *Self, entry: *const Queued) Error!void {
                    switch (c.sqlite3_step(entry.statement.?)) {
                        c.SQLITE_DONE => {},
                        c.SQLITE_FULL => return error.CanonicalStorageFull,
                        else => return error.StatementFailed,
                    }
                    const changed = c.sqlite3_changes64(a.store.database);
                    switch (S.expect) {
                        .exact => |guard| if (changed != guard.rows) return comptime @as(Error, @errorCast(guard.otherwise)),
                        .at_most => |rows| if (changed > rows) return error.CorruptStore,
                    }
                }
            }.run;
        }

        fn runPayload(a: *Self, entry: *const Queued) Error!void {
            const payload = entry.target.payload;
            if (payload.bytes.len == 0) return;
            var blob: ?*c.sqlite3_blob = null;
            if (c.sqlite3_blob_open(a.store.database, "main", "content", "payload", @intCast(payload.content_id), 1, &blob) != c.SQLITE_OK) return error.ContentWriteFailed;
            defer _ = c.sqlite3_blob_close(blob);
            if (c.sqlite3_blob_write(blob, payload.bytes.ptr, @intCast(payload.bytes.len), 0) != c.SQLITE_OK) return error.ContentWriteFailed;
        }
    };
}

/// Steps `statement`: true at a row, false at its end.
fn nextRow(statement: *c.sqlite3_stmt) Failure!bool {
    return switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => error.StatementFailed,
    };
}
