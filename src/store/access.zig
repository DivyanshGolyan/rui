//! Access: the statements of one locked transition, run in rounds. A
//! transition queues typed reads, ends the round with `run`, decides in
//! plain Zig, then queues its writes and ends with `commit`. It never
//! writes BEGIN, COMMIT, a row-count check or a position claim itself.
//!
//! The engine is the Store's SQLite connection. A statement is bound when
//! queued: fixed values are copied then, and only texts and blobs are read
//! in place when it steps (`sqlite.bindArgs`, `Borrowed`). A round may
//! queue one statement any number of times: SQLite steps what is queued,
//! in order (an engine pass), before it rebinds a statement already
//! queued, when the queue's 8 slots are full, when `contentSink` opens a
//! row, before the commit round's compare-and-sets, and at `run`. A pass
//! is in-process work inside the round, never a round trip, so a
//! destination is defined only after `run`, as it will be on a network
//! engine, where a repeated statement is one more Bind/Execute in the same
//! pipeline. Until the pass that steps it, a `readInto`'s `Found` is
//! `.pending` and panics when asked, and Debug and test builds poison a
//! `read`'s destination (`Access.read` says what that catches).

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
    ContentNotInserted,
};

/// A Session's positions claimed by one Access, from its head as a round
/// read it. `commit` advances `next_position` once, by a compare-and-set
/// against that head.
pub const Positions = struct {
    head: rsql.SessionHead,
    taken: u64 = 0,

    /// Claims `count` consecutive positions and returns the first.
    pub fn take(self: *Positions, count: u64) error{SessionPositionExhausted}!u64 {
        const first = self.head.next_position.get() + self.taken;
        // `first` is at most maxInt(i64), so this never wraps, for any count.
        if (count > std.math.maxInt(i64) - first) return error.SessionPositionExhausted;
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

/// The byte Debug and test builds fill a `read` destination with until the
/// pass that steps it (`Access.read` says what that catches).
pub const poison_byte = 0xAA;

/// Whether a queued `readInto` found its row. It is `.pending` from the
/// queuing until the pass that steps the read, in every build, and `get`
/// panics on `.pending`, so a body that asks before then stops.
pub const Found = enum(u8) {
    pending,
    found,
    missing,

    pub fn get(found: Found) bool {
        return switch (found) {
            .found => true,
            .missing => false,
            .pending => @panic("a readInto result was read before the pass that steps it"),
        };
    }
};
const poisons = @import("builtin").mode == .debug or @import("builtin").is_test;

/// The most arguments one statement reads in place (`sqlite.borrows`).
const max_borrowed = 4;

/// What a queued statement reads in place when its pass steps it: its
/// `[]const u8` texts and `rsql.Bytes` blobs (`sqlite.bindArgs`), or a
/// queued payload's bytes. Debug and test builds keep those slices and a
/// checksum of their bytes, taken when the statement is queued, and check
/// it just before its pass steps it: bytes that changed in between panic.
/// It checks that the bytes are equal, not that their owner still holds
/// them; an owner that frees and refills them with equal bytes passes.
/// Other builds keep nothing.
const Borrowed = if (poisons) struct {
    slices: [max_borrowed][]const u8 = undefined,
    count: u8 = 0,
    sum: u64 = 0,

    fn of(comptime Args: type, args: *const Args) Borrowed {
        const info = @typeInfo(Args).@"struct";
        const fields = comptime count: {
            var count = 0;
            for (info.field_types) |Field| count += @intFromBool(sqlite.borrows(Field));
            break :count count;
        };
        if (fields > max_borrowed) @compileError(std.fmt.comptimePrint("rsql: a statement reads at most {d} arguments in place", .{max_borrowed}));
        var result: Borrowed = .{};
        inline for (info.field_names, info.field_types) |name, Field| {
            if (comptime !sqlite.borrows(Field)) continue;
            if (sqlite.borrowed(Field, @field(args, name))) |bytes| {
                result.slices[result.count] = bytes;
                result.count += 1;
            }
        }
        result.sum = checksum(result.slices[0..result.count]);
        return result;
    }

    fn ofBytes(bytes: []const u8) Borrowed {
        var result: Borrowed = .{ .count = 1 };
        result.slices[0] = bytes;
        result.sum = checksum(result.slices[0..1]);
        return result;
    }

    fn check(borrowed: *const Borrowed) void {
        if (checksum(borrowed.slices[0..borrowed.count]) != borrowed.sum)
            @panic("bytes a queued statement reads in place changed before the pass that steps it");
    }

    fn checksum(slices: []const []const u8) u64 {
        var hash = std.hash.Wyhash.init(0);
        for (slices) |bytes| {
            hash.update(std.mem.asBytes(&bytes.len));
            hash.update(bytes);
        }
        return hash.final();
    }
} else struct {
    fn of(comptime Args: type, _: *const Args) Borrowed {
        return .{};
    }

    fn ofBytes(_: []const u8) Borrowed {
        return .{};
    }

    fn check(_: *const Borrowed) void {}
};

/// A count only tests read: engine passes.
const TestCount = if (@import("builtin").is_test) u32 else u0;

fn bump(count: *TestCount) void {
    if (TestCount != u0) count.* += 1;
}

pub fn Access(comptime mode: Mode, comptime Guards: type) type {
    return struct {
        const Self = @This();
        pub const Error = Guards || Failure;
        /// The statements one engine pass steps at most.
        const max_queued = 8;

        store: *Store,
        opened: bool = false,
        /// Set by `commit` and `abandon`; `deinit` refuses a write Access
        /// that opened its transaction without either.
        ended: bool = false,
        /// The first failure; every later call does nothing and every round
        /// reports it.
        failure: ?Error = null,
        /// The statement whose step recorded `failure`, if one did.
        failed_statement: ?*c.sqlite3_stmt = null,
        queue: [max_queued]Queued = undefined,
        queued: u8 = 0,
        /// Engine passes. Rounds, each one round trip on a network
        /// engine, count on the Store (`testing_content_work.rounds` for
        /// `run` and `commit`, `.content_rounds` for `readRaw`).
        passes: TestCount = 0,
        /// None in a read Access, which claims no positions.
        claims: [if (mode == .read or mode == .single) 0 else max_claims]Positions = undefined,
        claimed: u8 = 0,
        /// The last `max_taken` content ids this Access took, the rows
        /// `contentSink` may open; 0 marks a free entry.
        taken: [if (mode == .read or mode == .single) 0 else max_taken]u64 = @splat(0),
        taken_count: u64 = 0,
        /// The content rows this Access queued, by identity, so a second
        /// import of an equal value reuses the row (`content.importSlot`).
        inserted: [if (mode == .read or mode == .single) 0 else max_inserted]InsertedContent = undefined,
        inserted_count: u8 = 0,

        /// The most content rows one Access inserts: a creating Message's
        /// instructions, output schema, empty default and text.
        const max_inserted = 4;
        /// How many of its latest content ids an Access can open a sink
        /// on. Every caller opens one right after taking its id.
        const max_taken = max_inserted;

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
                into: struct { row: *anyopaque, found: *Found },
                /// An `.each` read's visitor, and how many rows it may step.
                each: struct { visitor: *anyopaque, limit: u64 },
                payload: struct { content_id: u64, bytes: []const u8 },
                /// A `.counted` write's rows (`writeCount`).
                counted: u64,
                none: void,
            },
            /// What it reads in place when its pass steps it, in Debug and
            /// test builds.
            borrowed: Borrowed = .{},
        };

        /// An Access under `entry`'s lock.
        pub fn open(entry: *const store_core.Entry) Self {
            return .{ .store = entry.store };
        }

        /// Queues a read; `destination` is defined once the round runs.
        /// Debug and test builds fill it with `poison_byte` until the pass
        /// that steps it. Poison makes a `.one` row's integers read as
        /// 0xAA.. and an `.at_most` list's length so large that slicing it
        /// traps in safe builds. It traps nothing else: a poisoned `bool`
        /// or optional tag reads as true or present, a poisoned enum
        /// reads as an invalid tag Zig does not check on load, and a
        /// `.optional` result is not covered. `readInto`'s `Found` is the
        /// covered form.
        pub fn read(a: *Self, comptime S: type, args: S.Args, destination: *S.Result) void {
            comptime std.debug.assert(S.kind == .read and S.cardinality != .each);
            // An `.optional` result is a copy of the decoded Row.
            if (comptime S.cardinality == .optional and (@sizeOf(S.Row) > 1024 or rsql.fillsInPlace(S.Row)))
                @compileError("rsql: a Row over 1 KiB, or one that points into the caller's memory, is read with readInto: " ++ S.sql);
            if (a.queueStatement(S, &args, runRead(S), .{ .destination = destination })) poison(destination);
        }

        /// Queues an `.optional` read that decodes into `row` in place, so
        /// a Row over 1 KiB is never copied, and a Row's pointer fields
        /// (`rsql.fillsInPlace`) fill what they point to; `found` says
        /// whether there was one. A missing row leaves `row` as it was.
        /// Both are defined once the round runs. `found` is `.pending`
        /// until the pass that steps the read, in every build, and its
        /// `get` panics then; `row` is not poisoned, because a missing row
        /// must keep its bytes. Two reads need it: `saved_session`, whose
        /// 4.6 KB Row `configure` fills in the caller's Session, and
        /// `bash_input`, whose Row points into the caller's
        /// `BashExecutionInput`, so neither is copied.
        pub fn readInto(a: *Self, comptime S: type, args: S.Args, row: *S.Row, found: *Found) void {
            comptime std.debug.assert(S.kind == .read and S.cardinality == .optional);
            found.* = .pending;
            _ = a.queueStatement(S, &args, runInto(S), .{ .into = .{ .row = row, .found = found } });
        }

        /// Queues an `.each` read whose round hands each row in turn to
        /// `visitor.visit(*const S.Row) bool`, until it returns false, the
        /// rows end, or `limit` rows were stepped. `visitor` must outlive
        /// the round. Nothing is poisoned: the visitor holds the read's
        /// results, and what they mean before the pass is its own. A row
        /// decodes into the pass's frame, unless the visitor has a field
        /// named `decoded`, which it then decodes into, so its size is
        /// the visitor's own (`eachVisitorError` states what is checked).
        /// Either way `visit` gets a pointer that the next row's decode
        /// overwrites, so a visitor copies what it keeps; a `decoded`
        /// field holds the last row stepped, and after a decode failure a
        /// row half written.
        pub fn readEach(a: *Self, comptime S: type, args: S.Args, limit: u64, visitor: anytype) void {
            a.readEachFrom(S, &args, limit, visitor);
        }

        /// `readEach` with Args its caller keeps, for Args too large to
        /// copy into a frame. The Args struct itself may be reused once
        /// this returns: its fixed-size values are copied when queued. The
        /// bytes its `[]const u8` and `rsql.Bytes` fields point to are read
        /// in place at the pass, so they must outlive it unchanged, which
        /// debug and test builds check with a checksum (`Borrowed`).
        pub fn readEachFrom(a: *Self, comptime S: type, args: *const S.Args, limit: u64, visitor: anytype) void {
            comptime std.debug.assert(S.kind == .read and S.cardinality == .each);
            if (comptime eachVisitorError(S.Row, @TypeOf(visitor.*))) |message| @compileError(message ++ ": " ++ S.sql);
            _ = a.queueStatement(S, args, runEach(S, @TypeOf(visitor.*)), .{ .each = .{ .visitor = visitor, .limit = limit } });
        }

        /// Ends the round: runs every queued statement in order, and
        /// reports the first failure of this round's passes.
        pub fn run(a: *Self) Error!void {
            if (@import("builtin").is_test) a.store.testing_content_work.rounds += 1;
            a.pass();
            if (a.failure) |err| return err;
        }

        /// An engine pass: steps every queued statement in order, then
        /// empties the queue. A failure stops it, and the round that
        /// contains it reports it.
        fn pass(a: *Self) void {
            bump(&a.passes);
            for (a.queue[0..a.queued]) |*entry| {
                if (a.failure != null) break;
                entry.borrowed.check();
                entry.run(a, entry) catch |err| {
                    a.failure = err;
                    a.failed_statement = entry.statement;
                };
                if (entry.statement) |statement| sqlite.resetCached(statement);
            }
            a.resetQueued();
        }

        /// Whether `S`'s step recorded this Access's failure: how a caller
        /// maps a round's `StatementFailed` to the name main gave the
        /// statement that failed.
        pub fn failedOn(a: *const Self, comptime S: type) bool {
            const statement = a.failed_statement orelse return false;
            return a.store.statements.find(S.sql.ptr) == statement;
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
            inline for (S.session_fields) |field| a.touch(@field(args, field));
            _ = a.queueStatement(S, args, runWrite(S), target);
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
            if (column == .content_id) {
                a.taken[a.taken_count % max_taken] = id;
                a.taken_count += 1;
            }
            return id;
        }

        /// Queues writing `bytes` into the payload of the content row
        /// `content_id`, inserted by an earlier queued write. `bytes` must
        /// outlive the round.
        pub fn writeContent(a: *Self, content_id: u64, bytes: []const u8) void {
            comptime std.debug.assert(mode != .read and mode != .single);
            if (a.reserve()) |slot| {
                slot.* = .{ .statement = null, .run = runPayload, .target = .{ .payload = .{ .content_id = content_id, .bytes = bytes } } };
                slot.borrowed = .ofBytes(bytes);
                a.queued += 1;
            }
        }

        /// Reads exactly `destination.len` bytes of the content row
        /// `content_id`'s payload at `offset`, as a round of its own,
        /// through the Store's one reused blob handle, which the Entry
        /// closes. Nothing may be queued, in every build. An empty
        /// `destination` reads nothing and counts no round.
        pub fn readRaw(a: *Self, content_id: u64, offset: u64, destination: []u8) Error!void {
            if (a.queued != 0) @panic("readRaw is a round of its own; run what is queued first");
            if (a.failure) |err| return err;
            if (destination.len == 0) return;
            if (@import("builtin").is_test) a.store.testing_content_work.content_rounds += 1;
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

        /// A sink for the payload of the content row `content_id`. It
        /// checks exactly that the id is one of the last `max_taken` this
        /// Access took with `identity(.content_id)`; any other, 0 and ids
        /// other code took in the same transaction included, is
        /// `ContentNotInserted`. It does not check that this Access
        /// queued a row with that id. It runs an engine pass first, so an
        /// insert queued before it has stepped; an id with no row is
        /// `ContentWriteFailed`. It writes into the open transaction, so
        /// the bytes commit with the row. Streamed imports need it
        /// (`importSealed`, settlement), so a value is never held in
        /// memory whole.
        pub fn contentSink(a: *Self, content_id: u64) Error!ContentSink {
            comptime std.debug.assert(mode != .read and mode != .single);
            if (a.failure) |err| return err;
            if (content_id == 0 or std.mem.findScalar(u64, &a.taken, content_id) == null) return error.ContentNotInserted;
            a.pass();
            if (a.failure) |err| return err;
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
            if (@import("builtin").is_test) a.store.testing_content_work.rounds += 1;
            if (mode == .single) {
                // A second statement would not commit with the first.
                if (a.failure == null and a.queued != 1) @panic("a single Access commits exactly one write");
                a.pass();
                if (a.failure) |err| return err;
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

        /// The queued writes, then one compare-and-set per claiming
        /// Session, in the round that commits. The compare-and-sets are
        /// bound only once the writes stepped without a failure.
        fn finishWrites(a: *Self) Error!void {
            a.ensureOpen();
            a.pass();
            if (a.failure) |err| return err;
            for (a.claims[0..a.claimed]) |*claim| if (claim.taken != 0) {
                const expected = claim.head.next_position.get();
                _ = a.queueStatement(advance, &.{ .session = claim.head, .expected = expected, .next = expected + claim.taken }, runWrite(advance), .{ .none = {} });
            };
            a.pass();
            a.claimed = 0;
            if (a.failure) |err| return err;
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
        /// fifth Session makes the record "everything"
        /// (`change_ring.Touched.needsEntry`); it never fails.
        fn touch(a: *Self, head: rsql.SessionHead) void {
            const touched = &a.store.touched;
            if (touched.needsEntry(&head.ref)) touched.add(.{ .session = head.ref, .workspace = head.workspace_key.get() });
        }

        /// Binds and queues `S`, after an engine pass when `S` is already
        /// queued or the queue is full. True when it queued.
        fn queueStatement(a: *Self, comptime S: type, args: *const S.Args, runner: *const fn (*Self, *const Queued) Error!void, target: @FieldType(Queued, "target")) bool {
            a.ensureOpen();
            if (a.failure != null) return false;
            const statement = store_core.cachedTyped(a.store, S) catch |err| {
                a.failure = err;
                return false;
            };
            // Binding a queued statement would replace the arguments it
            // has not stepped with yet.
            for (a.queue[0..a.queued]) |entry| if (entry.statement == statement) {
                a.pass();
                break;
            };
            const now = if (S.uses_now) store_core.transactionSecond(a.store) catch |err| {
                a.failure = err;
                return false;
            } else 0;
            const slot = a.reserve() orelse return false;
            slot.* = .{ .statement = statement, .run = runner, .target = target };
            sqlite.bindArgs(statement, S, args, now) catch |err| {
                sqlite.resetCached(statement);
                a.failure = err;
                return false;
            };
            slot.borrowed = .of(S.Args, args);
            a.queued += 1;
            return true;
        }

        /// The next queue slot, after an engine pass when the queue is
        /// full; null once a failure is recorded.
        fn reserve(a: *Self) ?*Queued {
            if (a.failure == null and a.queued == a.queue.len) a.pass();
            if (a.failure != null) return null;
            return &a.queue[a.queued];
        }

        /// Fills a queued read's destination with `poison_byte` in Debug
        /// and test builds, so a body that reads it before the pass that
        /// steps it reads poison. A pass that runs before `run` defines it
        /// early; only a network engine catches a body that reads it
        /// between that pass and `run`.
        fn poison(destination: anytype) void {
            if (poisons) @memset(std.mem.asBytes(destination), poison_byte);
        }

        /// Empties the queue. A pass reset each statement it stepped, and
        /// checked it (`sqlite.resetCached`), as it stepped; what is left
        /// was never stepped since its bind (`sqlite.resetUnstepped`).
        fn resetQueued(a: *Self) void {
            for (a.queue[0..a.queued]) |entry| if (entry.statement) |statement| sqlite.resetUnstepped(statement);
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
                    if (!try nextRow(statement)) {
                        into.found.* = .missing;
                        return;
                    }
                    into.found.* = .found;
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
                    // At most 1 KiB, unless the visitor owns its row (`eachVisitorError`).
                    const owned = comptime @hasField(Visitor, "decoded");
                    var local: if (owned) void else S.Row = undefined;
                    const row: *S.Row = if (owned) &visitor.decoded else &local;
                    var stepped: u64 = 0;
                    while (stepped < each.limit and try nextRow(statement)) : (stepped += 1) {
                        try sqlite.decodeRow(S.Row, statement, row);
                        if (!visitor.visit(row)) break;
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

/// Why `Visitor` cannot visit an `.each` read of `Row`, or null: a Row
/// over 1 KiB needs a visitor field named `decoded`, and a visitor's
/// `decoded` field, whatever the Row's size, is of type `Row`.
pub fn eachVisitorError(comptime Row: type, comptime Visitor: type) ?[]const u8 {
    if (!@hasField(Visitor, "decoded"))
        return if (@sizeOf(Row) > 1024) "rsql: an .each Row over 1 KiB decodes into its visitor's own decoded field" else null;
    if (@FieldType(Visitor, "decoded") != Row) return "rsql: a visitor's decoded field is the Row its .each read decodes, " ++ @typeName(Row);
    return null;
}

/// Ends `a`'s round with `run`, answering a failed step with `failed`:
/// how a converted read keeps the name main gave the statements of a
/// round, when they shared one.
pub fn runAs(a: anytype, comptime failed: anytype) (RunError(@TypeOf(a.*)) || @TypeOf(failed))!void {
    return runNamed(a, .{}, failed);
}

/// Ends `a`'s round with `run`, answering a failed step with the name main
/// gave the statement that failed: the error of the first pair in `named`
/// whose statement it was (`failedOn`), or `otherwise`.
pub fn runNamed(a: anytype, comptime named: anytype, comptime otherwise: anytype) (RunError(@TypeOf(a.*)) || NamedErrors(named) || @TypeOf(otherwise))!void {
    a.run() catch |err| {
        if (err != error.StatementFailed) return err;
        inline for (named) |pair| if (a.failedOn(pair[0])) return pair[1];
        return otherwise;
    };
}

/// The errors `A.run` returns.
fn RunError(comptime A: type) type {
    return @typeInfo(@typeInfo(@TypeOf(A.run)).@"fn".return_type.?).error_union.error_set;
}

/// The errors `runNamed`'s pairs name.
fn NamedErrors(comptime named: anytype) type {
    comptime var set: type = error{};
    inline for (named) |pair| set = set || @TypeOf(pair[1]);
    return set;
}

/// Steps `statement`: true at a row, false at its end.
fn nextRow(statement: *c.sqlite3_stmt) Failure!bool {
    return switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => error.StatementFailed,
    };
}
