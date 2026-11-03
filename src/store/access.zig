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
    /// One write statement, which commits itself: no BEGIN or COMMIT.
    /// Its reads run outside any transaction, under the Entry's lock,
    /// which excludes every other writer, so what they read still holds
    /// when the write runs. It takes no identities and claims no
    /// positions, and `commit` runs exactly one queued write.
    single,
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
    ContentReadFailed,
    RangeOutOfBounds,
    SqliteExecFailed,
    ClockReadFailed,
    SessionPositionExhausted,
    IdentityExhausted,
    IdentityOutsideTransaction,
    IdentityReadFailed,
    TooManyPositionClaims,
    RoundFull,
    StatementQueuedTwice,
    ContentNotInserted,
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

/// A content row an Access queued, by its identity.
pub const InsertedContent = struct { digest: [32]u8, length: u64, private: bool, content_id: u64 };

/// The read handle on a content payload, reused within one Entry: reading
/// on through one row reuses SQLite's overflow-page index, about
/// length/1024 bytes of its heap. `Entry.release` closes it.
pub const ContentBlob = struct {
    handle: ?*c.sqlite3_blob = null,
    content_id: i64 = 0,

    pub fn close(self: *ContentBlob) void {
        // Close reports only an earlier read failure, already returned.
        if (self.handle) |handle| _ = c.sqlite3_blob_close(handle);
        self.* = .{};
    }
};

/// Writes one content payload in place, at offsets the writer chooses.
pub const ContentSink = struct {
    blob: *c.sqlite3_blob,

    pub fn write(sink: ContentSink, bytes: []const u8, offset: u64) error{ ContentWriteFailed, ContentTooLarge }!void {
        if (offset > std.math.maxInt(c_int)) return error.ContentTooLarge;
        if (c.sqlite3_blob_write(sink.blob, bytes.ptr, @intCast(bytes.len), @intCast(offset)) != c.SQLITE_OK) return error.ContentWriteFailed;
    }

    pub fn close(sink: ContentSink) void {
        // Close reports only an earlier write failure, already returned.
        _ = c.sqlite3_blob_close(sink.blob);
    }
};

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
        claims: [if (mode == .read or mode == .single) 0 else max_claims]Positions = undefined,
        claimed: u8 = 0,
        /// The last `content_id` this Access took: the one row
        /// `contentSink` opens.
        content_id: u64 = 0,
        /// The content rows this Access queued, by identity, so a second
        /// import of an equal value reuses the row (`content.importSlot`).
        inserted: [if (mode == .read or mode == .single) 0 else max_inserted]InsertedContent = undefined,
        inserted_count: u8 = 0,

        /// The most content rows one Access inserts: a creating Message's
        /// instructions, output schema, empty default and text.
        const max_inserted = 4;

        /// No transition takes positions in more Sessions than the change
        /// ring tracks; touching more only degrades the ring's record.
        const max_claims = change_ring.Touched.max;
        /// A write names at most a message's two Sessions.
        const max_sessions = 2;

        const Queued = struct {
            run: *const fn (*Self, *const Queued) Error!void,
            /// Null for a content payload.
            statement: ?*c.sqlite3_stmt,
            target: union {
                /// A read's result.
                destination: *anyopaque,
                /// A `readInto` read's row, and whether it found one.
                into: struct { row: *anyopaque, found: *bool },
                /// An `.each` read's visitor, and how many rows it may step.
                each: struct { visitor: *anyopaque, limit: u64 },
                payload: struct { content_id: u64, bytes: []const u8 },
                /// A `.counted` write's rows (`writeCount`).
                counted: u64,
                none: void,
            },
            /// The references a write's @session markers bind, in its
            /// Args' order, read in place when the round runs.
            session_refs: [max_sessions]change_ring.Id = undefined,
        };

        /// An Access under `entry`'s lock.
        pub fn open(entry: *const store_core.Entry) Self {
            comptime std.debug.assert(mode != .nested);
            return .{ .store = entry.store };
        }

        /// How unconverted code, under an Entry it already holds, runs a
        /// rule that has an Access form. A `.nested` Access writes inside
        /// the transaction its caller opened, which is asserted. A `.read`
        /// one checks nothing: it is how unconverted code that holds the
        /// Store, not the Entry `open` takes, reads through a converted
        /// read (`readSaved`, `lookupCommand`, `readWindow`). Both go once
        /// that code is converted (PR 5e).
        pub fn within(store: *Store) Self {
            comptime std.debug.assert(mode == .nested or mode == .read);
            if (mode == .nested) std.debug.assert(c.sqlite3_get_autocommit(store.database) == 0);
            return .{ .store = store };
        }

        /// Queues a read; `destination` is defined once the round runs.
        pub fn read(a: *Self, comptime S: type, args: S.Args, destination: *S.Result) void {
            comptime std.debug.assert(S.kind == .read and S.cardinality != .each);
            // An `.optional` result is a copy of the decoded Row.
            if (comptime S.cardinality == .optional and (@sizeOf(S.Row) > 1024 or rsql.fillsInPlace(S.Row)))
                @compileError("rsql: a Row over 1 KiB, or one that points into the caller's memory, is read with readInto: " ++ S.sql);
            a.queueStatement(S, &args, runRead(S), .{ .destination = destination }, &.{});
        }

        /// Queues an `.optional` read that decodes into `row` in place, so
        /// a Row over 1 KiB is never copied, and a Row's pointer fields
        /// (`rsql.fillsInPlace`) fill what they point to; `found` says
        /// whether there was one. A missing row leaves `row` as it was.
        /// Both are defined once the round runs. Two reads need it:
        /// `saved_session`, whose 4.6 KB Row `configure` fills in the
        /// caller's Session, and `bash_input`, whose Row points into the
        /// caller's `BashExecutionInput`, so neither is copied.
        pub fn readInto(a: *Self, comptime S: type, args: S.Args, row: *S.Row, found: *bool) void {
            comptime std.debug.assert(S.kind == .read and S.cardinality == .optional);
            a.queueStatement(S, &args, runInto(S), .{ .into = .{ .row = row, .found = found } }, &.{});
        }

        /// Queues an `.each` read whose round hands each row in turn to
        /// `visitor.visit(*const S.Row) bool`, until it returns false, the
        /// rows end, or `limit` rows were stepped. `visitor` must outlive
        /// the round.
        pub fn readEach(a: *Self, comptime S: type, args: S.Args, limit: u64, visitor: anytype) void {
            comptime std.debug.assert(S.kind == .read and S.cardinality == .each);
            a.queueStatement(S, &args, runEach(S, @TypeOf(visitor.*)), .{ .each = .{ .visitor = visitor, .limit = limit } }, &.{});
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
            comptime std.debug.assert(mode != .read and mode != .single);
            a.touch(head);
            for (a.claims[0..a.claimed]) |*claim| if (std.mem.eql(u8, &claim.head.ref, &head.ref)) return claim;
            if (a.claimed == a.claims.len) return error.TooManyPositionClaims;
            a.claims[a.claimed] = .{ .head = head };
            a.claimed += 1;
            return &a.claims[a.claimed - 1];
        }

        /// Queues a write, touching each Session its @session markers
        /// name. A failed guard fails the round that runs it.
        pub fn write(a: *Self, comptime S: type, args: S.Args) void {
            if (S.expect == .counted) @compileError("rsql: a .counted write states its rows through writeCount: " ++ S.sql);
            a.queueWrite(S, &args, .{ .none = {} });
        }

        /// Queues a `.counted` write, as `write` does, that must change
        /// exactly `rows` rows, or the round that runs it fails with the
        /// statement's `otherwise` before COMMIT. Zero is checked like any
        /// count. The caller's doc names the read `rows` comes from.
        pub fn writeCount(a: *Self, comptime S: type, args: S.Args, rows: u64) void {
            if (S.expect != .counted) @compileError("rsql: writeCount queues only a .counted write: " ++ S.sql);
            a.queueWrite(S, &args, .{ .counted = rows });
        }

        fn queueWrite(a: *Self, comptime S: type, args: *const S.Args, target: @FieldType(Queued, "target")) void {
            comptime std.debug.assert(S.kind == .write and mode != .read and S.session_fields.len <= max_sessions);
            var refs: [S.session_fields.len]change_ring.Id = undefined;
            inline for (S.session_fields, &refs) |field, *ref| {
                const head: rsql.SessionHead = @field(args, field);
                a.touch(head);
                ref.* = head.ref;
            }
            a.queueStatement(S, args, runWrite(S), target, &refs);
        }

        /// The id of the content row this Access queued for (`digest`,
        /// `length`, `private`), or null.
        pub fn insertedContent(a: *const Self, digest: *const [32]u8, length: u64, private: bool) ?u64 {
            for (a.inserted[0..a.inserted_count]) |row| {
                if (row.length == length and row.private == private and std.mem.eql(u8, &row.digest, digest)) return row.content_id;
            }
            return null;
        }

        /// Records a content row this Access queued. More than
        /// `max_inserted` panics, in every build.
        pub fn recordInserted(a: *Self, digest: *const [32]u8, length: u64, private: bool, content_id: u64) void {
            if (a.inserted_count == a.inserted.len) @panic("an Access inserts at most max_inserted content rows");
            a.inserted[a.inserted_count] = .{ .digest = digest.*, .length = length, .private = private, .content_id = content_id };
            a.inserted_count += 1;
        }

        /// The next value of `column`, inside this transaction.
        pub fn identity(a: *Self, comptime column: store_core.Identity) !u64 {
            comptime std.debug.assert(mode != .read and mode != .single);
            a.ensureOpen();
            if (a.failure) |err| return err;
            const id = try store_core.takeIdentity(a.store, column);
            if (column == .content_id) a.content_id = id;
            return id;
        }

        /// Queues writing `bytes` into the payload of the content row
        /// `content_id`, inserted by an earlier queued write. `bytes` must
        /// outlive the round.
        pub fn writeContent(a: *Self, content_id: u64, bytes: []const u8) void {
            comptime std.debug.assert(mode != .read and mode != .single);
            if (a.reserve()) |slot| {
                slot.* = .{ .statement = null, .run = runPayload, .target = .{ .payload = .{ .content_id = content_id, .bytes = bytes } } };
                a.queued += 1;
            }
        }

        /// Reads exactly `destination.len` bytes of the content row
        /// `content_id`'s payload at `offset`, as a round of its own,
        /// through the Store's one reused blob handle, which the Entry
        /// closes. Nothing may be queued, in every build.
        pub fn readRaw(a: *Self, content_id: u64, offset: u64, destination: []u8) Error!void {
            if (a.queued != 0) @panic("readRaw is a round of its own; run what is queued first");
            if (a.failure) |err| return err;
            if (destination.len == 0) return;
            if (offset > std.math.maxInt(c_int)) return error.RangeOutOfBounds;
            const id: i64 = @intCast(content_id);
            const blob = &a.store.read_blob;
            if (blob.handle == null) {
                // A failed open leaves the handle null.
                if (c.sqlite3_blob_open(a.store.database, "main", "content", "payload", id, 0, &blob.handle) != c.SQLITE_OK) return error.ContentReadFailed;
                blob.content_id = id;
            } else if (blob.content_id != id) {
                // A failed reopen aborts the handle; close remains its release.
                if (c.sqlite3_blob_reopen(blob.handle, id) != c.SQLITE_OK) return error.ContentReadFailed;
                blob.content_id = id;
            }
            if (c.sqlite3_blob_read(blob.handle, destination.ptr, @intCast(destination.len), @intCast(offset)) != c.SQLITE_OK) return error.ContentReadFailed;
            if (@import("builtin").is_test) _ = a.store.testing_content_work.blob.fetchAdd(destination.len, .monotonic);
        }

        /// A sink for the payload of the content row `content_id`, which
        /// must be the last id this Access took (`identity(.content_id)`),
        /// with nothing queued: so its row is the one this Access inserted
        /// and a round has run, or none. Any other id is
        /// `ContentNotInserted`. It writes into the open transaction, so
        /// the bytes commit with the row. `importSealed` needs it: it
        /// streams a sealed file into the payload while hashing it, so the
        /// file is never held in memory whole.
        pub fn contentSink(a: *Self, content_id: u64) Error!ContentSink {
            comptime std.debug.assert(mode != .read and mode != .single);
            if (a.failure) |err| return err;
            if (content_id == 0 or content_id != a.content_id or a.queued != 0) return error.ContentNotInserted;
            var blob: ?*c.sqlite3_blob = null;
            if (c.sqlite3_blob_open(a.store.database, "main", "content", "payload", @intCast(content_id), 1, &blob) != c.SQLITE_OK) return error.ContentWriteFailed;
            return .{ .blob = blob.? };
        }

        /// Runs the queued writes and one compare-and-set per Session that
        /// claimed positions, then COMMIT. A failed guard stops before
        /// COMMIT. A `.single` Access runs its one write, which commits
        /// itself.
        pub fn commit(a: *Self) Error!void {
            comptime std.debug.assert(mode == .write or mode == .single);
            if (mode == .single) {
                // A second statement would not commit with the first.
                if (a.failure == null and a.queued != 1) @panic("a single Access commits exactly one write");
                try a.run();
                a.ended = true;
                return;
            }
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
        /// and `end` calls it on every error. Once the Access has ended,
        /// committed or abandoned, it does nothing, so a replay that
        /// abandoned and then failed is not rolled back twice.
        pub fn abandon(a: *Self, faults: store_core.Faults) Error!void {
            comptime std.debug.assert(mode == .write or mode == .single);
            if (a.ended) return;
            a.resetQueued();
            a.claimed = 0;
            a.ended = true;
            if (mode == .write and a.opened) try store_core.rollbackAfterError(a.store, faults);
        }

        /// The transition's `result`, after abandoning the Access when it
        /// is an error. A write Access's entry point returns through it, so
        /// no exit leaves the transaction open; a failed rollback takes the
        /// error's place, and the Entry fences on it.
        pub fn end(a: *Self, faults: store_core.Faults, result: anytype) @TypeOf(result) {
            comptime std.debug.assert(mode == .write or mode == .single);
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
                a.queueStatement(advance, &.{ .session = claim.head, .expected = expected, .next = expected + claim.taken }, runWrite(advance), .{ .none = {} }, &.{claim.head.ref});
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

        fn queueStatement(a: *Self, comptime S: type, args: *const S.Args, runner: *const fn (*Self, *const Queued) Error!void, target: @FieldType(Queued, "target"), session_refs: []const change_ring.Id) void {
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
            @memcpy(slot.session_refs[0..session_refs.len], session_refs);
            sqlite.bindArgs(statement, S, args, now, slot.session_refs[0..session_refs.len]) catch |err| {
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
                            // At most 1 KiB, holding no pointer (`Access.read`), so the copy is small.
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

        fn runInto(comptime S: type) *const fn (*Self, *const Queued) Error!void {
            return &struct {
                fn run(_: *Self, entry: *const Queued) Error!void {
                    const statement = entry.statement.?;
                    const into = entry.target.into;
                    into.found.* = try nextRow(statement);
                    if (!into.found.*) return;
                    try sqlite.decodeRow(S.Row, statement, @ptrCast(@alignCast(into.row)));
                    if (!S.single_row and try nextRow(statement)) return error.CorruptStore;
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
                        .counted => |guard| if (changed != entry.target.counted) return comptime @as(Error, @errorCast(guard.otherwise)),
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
