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
    /// `commit`, or with `abandon` when it finds no work.
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
    CorruptStore,
    ContentWriteFailed,
    SqliteExecFailed,
    ClockReadFailed,
    SessionPositionExhausted,
    IdentityExhausted,
    IdentityReadFailed,
    TooManySessions,
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
    .sql = "UPDATE session SET next_position=?3 WHERE session_ref=?1 AND next_position=?2",
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
        /// The Host's Unix second, bound to @now: read once, by the first
        /// statement that uses it.
        now: ?i64 = null,
        opened: bool = false,
        /// The first failure; every later call does nothing and every round
        /// reports it.
        failure: ?Error = null,
        queue: [max_queued]Queued = undefined,
        queued: u8 = 0,
        claims: [change_ring.Touched.max]Positions = undefined,
        claimed: u8 = 0,

        const Queued = struct {
            /// Null for a content payload.
            statement: ?*c.sqlite3_stmt,
            run: *const fn (*Self, *const Queued) Error!void,
            destination: ?*anyopaque = null,
            content_id: u64 = 0,
            bytes: []const u8 = "",
        };

        /// An Access under `entry`'s lock.
        pub fn open(entry: *const store_core.Entry) Self {
            comptime std.debug.assert(mode != .nested);
            return .{ .store = entry.store };
        }

        /// An Access inside the transaction its caller opened.
        pub fn within(store: *Store) Self {
            comptime std.debug.assert(mode == .nested);
            std.debug.assert(c.sqlite3_get_autocommit(store.database) == 0);
            return .{ .store = store };
        }

        /// Queues a read; `destination` is defined once the round runs.
        pub fn read(a: *Self, comptime S: type, args: S.Args, destination: *S.Result) void {
            comptime std.debug.assert(S.kind == .read);
            a.queueStatement(S, &args, runRead(S), destination);
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
        pub fn touch(a: *Self, head: rsql.SessionHead) error{TooManySessions}!*Positions {
            comptime std.debug.assert(mode != .read);
            for (a.claims[0..a.claimed]) |*claim| if (std.mem.eql(u8, &claim.head.ref, &head.ref)) return claim;
            if (a.claimed == a.claims.len) return error.TooManySessions;
            const touched = &a.store.touched;
            if (touched.needsEntry(&head.ref)) touched.add(.{ .session = head.ref, .workspace = head.workspace_key.get() });
            a.claims[a.claimed] = .{ .head = head };
            a.claimed += 1;
            return &a.claims[a.claimed - 1];
        }

        /// Queues a write, touching the Session it binds. A failed guard
        /// fails the round that runs it.
        pub fn write(a: *Self, comptime S: type, args: S.Args) void {
            comptime std.debug.assert(S.kind == .write and mode != .read);
            if (S.session_field) |field| if (a.failure == null) {
                _ = a.touch(@field(args, field)) catch |err| {
                    a.failure = err;
                };
            };
            a.queueStatement(S, &args, runWrite(S), null);
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
            a.push(.{ .statement = null, .run = runPayload, .content_id = content_id, .bytes = bytes });
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
        }

        /// `commit` without COMMIT: the caller's transaction stays open.
        pub fn apply(a: *Self) Error!void {
            comptime std.debug.assert(mode == .nested);
            try a.finishWrites();
        }

        /// Ends a write Access that found no work: nothing queued runs.
        pub fn abandon(a: *Self) Error!void {
            comptime std.debug.assert(mode == .write);
            a.resetQueued();
            a.claimed = 0;
            if (a.opened) store_core.rollback(a.store) catch |err| {
                a.failure = err;
                return err;
            };
        }

        /// Clears statements queued but never run, after an early return.
        pub fn deinit(a: *Self) void {
            a.resetQueued();
        }

        fn finishWrites(a: *Self) Error!void {
            a.ensureOpen();
            try a.run();
            for (a.claims[0..a.claimed]) |*claim| if (claim.taken != 0) {
                const expected = claim.head.next_position.get();
                a.queueStatement(advance, &.{ .session = claim.head, .expected = expected, .next = expected + claim.taken }, runWrite(advance), null);
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

        fn hostSecond(a: *Self) Error!i64 {
            if (a.now) |now| return now;
            const now = @divFloor(try store_core.readUnixMilliseconds(a.store.io), 1000);
            a.now = now;
            return now;
        }

        fn queueStatement(a: *Self, comptime S: type, args: *const S.Args, runner: *const fn (*Self, *const Queued) Error!void, destination: ?*anyopaque) void {
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
            const now = if (S.uses_now) a.hostSecond() catch |err| {
                a.failure = err;
                return;
            } else 0;
            sqlite.bindArgs(statement, S, args, now) catch |err| {
                sqlite.resetCached(statement);
                a.failure = err;
                return;
            };
            a.push(.{ .statement = statement, .run = runner, .destination = destination });
            if (a.failure != null) sqlite.resetCached(statement);
        }

        fn push(a: *Self, entry: Queued) void {
            if (a.failure != null) return;
            if (a.queued == a.queue.len) {
                a.failure = error.RoundFull;
                return;
            }
            a.queue[a.queued] = entry;
            a.queued += 1;
        }

        fn resetQueued(a: *Self) void {
            for (a.queue[0..a.queued]) |entry| if (entry.statement) |statement| sqlite.resetCached(statement);
            a.queued = 0;
        }

        fn runRead(comptime S: type) *const fn (*Self, *const Queued) Error!void {
            return &struct {
                fn run(_: *Self, entry: *const Queued) Error!void {
                    const statement = entry.statement.?;
                    const destination: *S.Result = @ptrCast(@alignCast(entry.destination.?));
                    switch (S.cardinality) {
                        .one => {
                            destination.* = try nextRow(S.Row, statement) orelse return error.CorruptStore;
                            if (try nextRow(S.Row, statement) != null) return error.CorruptStore;
                        },
                        .optional => {
                            destination.* = try nextRow(S.Row, statement);
                            if (destination.* != null and try nextRow(S.Row, statement) != null) return error.CorruptStore;
                        },
                        .at_most => |max| {
                            destination.* = .{};
                            while (try nextRow(S.Row, statement)) |row| {
                                if (destination.len == max) return error.CorruptStore;
                                destination.items[destination.len] = row;
                                destination.len += 1;
                            }
                        },
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
            if (entry.bytes.len == 0) return;
            var blob: ?*c.sqlite3_blob = null;
            if (c.sqlite3_blob_open(a.store.database, "main", "content", "payload", @intCast(entry.content_id), 1, &blob) != c.SQLITE_OK) return error.ContentWriteFailed;
            defer _ = c.sqlite3_blob_close(blob);
            if (c.sqlite3_blob_write(blob, entry.bytes.ptr, @intCast(entry.bytes.len), 0) != c.SQLITE_OK) return error.ContentWriteFailed;
        }
    };
}

fn nextRow(comptime Row: type, statement: *c.sqlite3_stmt) Failure!?Row {
    return switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => try sqlite.decodeRow(Row, statement),
        c.SQLITE_DONE => null,
        else => error.StatementFailed,
    };
}
