const std = @import("std");
const change_ring = @import("../change_ring.zig");
const obligation = @import("domain/session_obligation.zig");
const store_core = @import("Store.zig");
const Store = store_core.Store;
const rsql = @import("rsql.zig");
const engine = @import("engine.zig");
const sqlite = @import("sqlite.zig");
const pass_plan = @import("pass_plan.zig");

pub const Mode = pass_plan.Mode;

pub const Failure = engine.Failure;

pub const Positions = struct {
    head: rsql.SessionHead,
    taken: u64 = 0,

    pub fn take(self: *Positions, count: u64) error{SessionPositionExhausted}!u64 {
        const first = self.head.next_position.get() + self.taken;
        if (count > std.math.maxInt(i64) - first) return error.SessionPositionExhausted;
        self.taken += count;
        return first;
    }
};

const advance = rsql.Write(.{
    .sql = "UPDATE session SET next_position=?3 WHERE session_ref=@session(?1) AND next_position=?2",
    .Args = struct { session: rsql.SessionHead, expected: u64, next: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

pub const InsertedContent = struct { digest: [32]u8, length: u64, private: bool, content_id: u64 };

pub const ContentSink = engine.ContentSink;

pub const poison_byte = 0xAA;

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

const max_borrowed = 4;

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

const TestCount = if (@import("builtin").is_test) u32 else u0;

fn bump(count: *TestCount) void {
    if (TestCount != u0) count.* += 1;
}

pub const Tail = struct {
    context: *anyopaque,
    step: *const fn (*anyopaque) bool,
};

const Unfollowed = struct {
    pub fn queue(_: *Unfollowed, _: anytype) void {}
    pub fn followed(_: *Unfollowed) void {}
};

fn failureClass(err: ?anyerror) pass_plan.Class {
    const failure = err orelse return .none;
    return if (pass_plan.fences(failure)) .fencing else .ordinary;
}

pub fn Access(comptime mode: Mode, comptime Guards: type) type {
    return struct {
        const Self = @This();
        pub const Error = Guards || Failure;
        const reads_only = mode == .read or mode == .survey;
        const transacts = mode == .write or mode == .settlement;
        const max_queued = pass_plan.capacity(mode);
        const Guarded = if (max_queued > 16) u32 else u16;

        store: *Store,
        phase: enum { lazy, opened, ended } = .lazy,
        failure: ?Error = null,
        failed_sql: ?[*:0]const u8 = null,
        queue: [max_queued]Queued = undefined,
        queued: u8 = 0,
        guarded: Guarded = 0,
        tail: if (mode == .survey) bool else void = if (mode == .survey) false else {},
        passes: TestCount = 0,
        claims: [if (reads_only or mode == .single) 0 else max_claims]Positions = undefined,
        claimed: u8 = 0,
        obligation_heads: [if (reads_only or mode == .single) 0 else max_claims]rsql.SessionHead = undefined,
        obligation_count: u8 = 0,
        taken: [if (reads_only or mode == .single) 0 else max_taken]u64 = @splat(0),
        taken_rows: [if (reads_only or mode == .single) 0 else max_taken]bool = @splat(false),
        taken_count: u64 = 0,
        inserted: [if (reads_only or mode == .single) 0 else max_inserted]InsertedContent = undefined,
        inserted_count: u8 = 0,

        const max_inserted = 6;
        comptime {
            std.debug.assert(2 * @import("domain/tool_set.zig").records_per_transaction <= max_inserted);
        }
        const max_taken = max_inserted;

        const max_claims = change_ring.Touched.max;
        const max_sessions = 2;

        const Queued = struct {
            run: *const fn (*Self, *const Queued) Error!void,
            statement: ?engine.Statement,
            target: union {
                destination: *anyopaque,
                into: struct { row: *anyopaque, found: *Found },
                each: struct { visitor: *anyopaque, limit: u64 },
                payload: struct { content_id: u64, bytes: []const u8 },
                counted: u64,
                none: void,
            },
            borrowed: Borrowed = .{},
        };

        pub fn open(entry: *const store_core.Entry) Self {
            return .{ .store = entry.store };
        }

        pub fn init(a: *Self, entry: *const store_core.Entry) void {
            a.* = .{ .store = entry.store };
        }

        pub fn read(a: *Self, comptime S: type, args: S.Args, destination: *S.Result) void {
            comptime std.debug.assert(S.kind == .read and S.cardinality != .each);
            if (comptime S.cardinality == .optional and (@sizeOf(S.Row) > 1024 or rsql.fillsInPlace(S.Row)))
                @compileError("rsql: a Row over 1 KiB, or one that points into the caller's memory, is read with readInto: " ++ S.sql);
            if (a.queueStatement(S, &args, runRead(S), .{ .destination = destination })) poison(destination);
        }

        pub fn readInto(a: *Self, comptime S: type, args: S.Args, row: *S.Row, found: *Found) void {
            comptime std.debug.assert(S.kind == .read and S.cardinality == .optional);
            found.* = .pending;
            _ = a.queueStatement(S, &args, runInto(S), .{ .into = .{ .row = row, .found = found } });
        }

        pub fn readEach(a: *Self, comptime S: type, args: S.Args, limit: u64, visitor: anytype) void {
            a.readEachFrom(S, &args, limit, visitor);
        }

        pub fn readEachFrom(a: *Self, comptime S: type, args: *const S.Args, limit: u64, visitor: anytype) void {
            comptime std.debug.assert(S.kind == .read and S.cardinality == .each);
            if (comptime eachVisitorError(S.Row, @TypeOf(visitor.*))) |message| @compileError(message ++ ": " ++ S.sql);
            _ = a.queueStatement(S, args, runEach(S, @TypeOf(visitor.*)), .{ .each = .{ .visitor = visitor, .limit = limit } });
        }

        pub fn run(a: *Self) Error!void {
            if (@import("builtin").is_test) a.store.testing_content_work.rounds += 1;
            a.pass();
            if (a.failure) |err| return err;
        }

        fn pass(a: *Self) void {
            a.passWith(null);
        }

        fn passWith(a: *Self, tail: ?Tail) void {
            if (mode == .survey) if (a.tail) {
                if (a.failure == null) a.failure = error.StatementFailed;
                return;
            };
            bump(&a.passes);
            if (a.store.engine.batches() and a.failure == null)
                for (a.queue[0..a.queued]) |*entry| entry.borrowed.check();
            if (a.queued != 0 and a.failure == null) {
                if (@import("builtin").is_test) a.store.testingAccessPasses().* += 1;
                a.store.engine.startPass() catch |err| {
                    a.failure = err;
                };
            }
            for (a.queue[0..a.queued]) |*entry| {
                if (a.failure != null) break;
                if (!a.store.engine.batches()) entry.borrowed.check();
                entry.run(a, entry) catch |err| {
                    a.failure = err;
                };
                a.store.engine.endStatement(entry.statement);
            }
            const tail_failed = if (tail) |reads| a.failure == null and !reads.step(reads.context) else false;
            if (a.queued != 0) a.store.engine.finishPass() catch |err| {
                if (pass_plan.surviving(failureClass(a.failure), tail_failed, failureClass(err), .none) == .finish) a.failure = err;
            };
            a.resetQueued() catch |err| {
                if (pass_plan.surviving(failureClass(a.failure), false, .none, failureClass(err)) == .reset) a.failure = err;
            };
        }

        pub fn failedOn(a: *const Self, comptime S: type) bool {
            return a.failed_sql == S.sql.ptr;
        }

        pub fn transactionOpen(a: *const Self) bool {
            comptime std.debug.assert(transacts);
            if (a.phase != .opened or a.failure != null) return false;
            std.debug.assert(a.store.engine.inWriteTransaction());
            return true;
        }

        pub fn positions(a: *Self, head: rsql.SessionHead) error{TooManyPositionClaims}!*Positions {
            comptime std.debug.assert(!reads_only and mode != .single);
            a.touch(head);
            for (a.claims[0..a.claimed]) |*claim| if (std.mem.eql(u8, &claim.head.ref, &head.ref)) return claim;
            if (a.claimed == a.claims.len) return error.TooManyPositionClaims;
            a.claims[a.claimed] = .{ .head = head };
            a.claimed += 1;
            return &a.claims[a.claimed - 1];
        }

        pub fn write(a: *Self, comptime S: type, args: S.Args) void {
            if (S.expect == .counted) @compileError("rsql: a .counted write states its rows through writeCount: " ++ S.sql);
            a.queueWrite(S, &args, .{ .none = {} });
        }

        pub fn writeCount(a: *Self, comptime S: type, args: S.Args, rows: u64) void {
            if (S.expect != .counted) @compileError("rsql: writeCount queues only a .counted write: " ++ S.sql);
            a.queueWrite(S, &args, .{ .counted = rows });
        }

        fn queueWrite(a: *Self, comptime S: type, args: *const S.Args, target: @FieldType(Queued, "target")) void {
            comptime std.debug.assert(S.kind == .write and !reads_only and S.session_fields.len <= max_sessions);
            if (!reads_only and mode != .single and
                a.obligation_count + S.session_fields.len > a.obligation_heads.len)
            {
                a.reconcileObligations() catch |err| {
                    a.failure = err;
                    return;
                };
            }
            inline for (S.session_fields) |field| a.touch(@field(args, field));
            _ = a.queueStatement(S, args, runWrite(S), target);
        }

        pub fn insertedContent(a: *const Self, digest: *const [32]u8, length: u64, private: bool) ?u64 {
            for (a.inserted[0..a.inserted_count]) |row| {
                if (row.length == length and row.private == private and std.mem.eql(u8, &row.digest, digest)) return row.content_id;
            }
            return null;
        }

        pub fn recordInserted(a: *Self, digest: *const [32]u8, length: u64, private: bool, content_id: u64) void {
            if (a.inserted_count == a.inserted.len) @panic("an Access inserts at most max_inserted content rows");
            a.inserted[a.inserted_count] = .{ .digest = digest.*, .length = length, .private = private, .content_id = content_id };
            a.inserted_count += 1;
        }

        pub fn attemptTimings(a: *const Self, operation: u64) @import("../model_timing.zig").Values {
            comptime std.debug.assert(!reads_only);
            return a.store.modelTimingSource().snapshot(operation, a.store.io);
        }

        pub fn identity(a: *Self, comptime column: store_core.Identity) !u64 {
            comptime std.debug.assert(!reads_only and mode != .single);
            a.ensureOpen();
            if (a.failure) |err| return err;
            const id = try store_core.takeIdentity(a.store, column);
            if (column == .content_id) {
                a.taken[a.taken_count % max_taken] = id;
                a.taken_rows[a.taken_count % max_taken] = false;
                a.taken_count += 1;
            }
            return id;
        }

        pub fn writeContent(a: *Self, content_id: u64, bytes: []const u8) void {
            comptime std.debug.assert(!reads_only and mode != .single);
            a.ensureOpen();
            if (a.failure != null) return;
            a.store.engine.queuePayload(content_id, bytes, PayloadHost{ .access = a });
        }

        const PayloadHost = struct {
            access: *Self,

            pub fn statement(host: @This(), comptime S: type, args: S.Args) bool {
                return host.access.queueStatement(S, &args, runWrite(S), .{ .none = {} });
            }

            pub fn payload(host: @This(), content_id: u64, bytes: []const u8) void {
                const a = host.access;
                if (a.reserve()) |slot| {
                    slot.* = .{ .statement = null, .run = runPayload, .target = .{ .payload = .{ .content_id = content_id, .bytes = bytes } } };
                    slot.borrowed = .ofBytes(bytes);
                    a.queued += 1;
                }
            }
        };

        pub fn readRaw(a: *Self, content_id: u64, offset: u64, destination: []u8) Error!void {
            if (a.queued != 0) @panic("readRaw is a round of its own; run what is queued first");
            if (a.failure) |err| return err;
            if (destination.len == 0) return;
            if (@import("builtin").is_test) a.store.testing_content_work.content_rounds += 1;
            try a.store.engine.readRaw(content_id, offset, destination);
            if (@import("builtin").is_test) _ = a.store.testing_content_work.blob.fetchAdd(destination.len, .monotonic);
        }

        pub fn recordContentRow(a: *Self, content_id: u64) void {
            comptime std.debug.assert(!reads_only and mode != .single);
            const index = std.mem.findScalar(u64, &a.taken, content_id) orelse @panic("a content row is recorded under an id this Access took");
            a.taken_rows[index] = true;
        }

        pub fn contentSink(a: *Self, content_id: u64, length: u64) Error!ContentSink {
            comptime std.debug.assert(!reads_only and mode != .single);
            if (a.failure) |err| return err;
            if (content_id == 0) return error.ContentNotInserted;
            const index = std.mem.findScalar(u64, &a.taken, content_id) orelse return error.ContentNotInserted;
            if (!a.taken_rows[index]) return error.ContentWriteFailed;
            if (!a.store.engine.batches()) {
                a.pass();
                if (a.failure) |err| return err;
            }
            return a.store.engine.openSink(content_id, length, .{ .context = a, .chunk = queueChunk });
        }

        fn queueChunk(context: *anyopaque, id: u64, index: u64, n: usize) error{ContentWriteFailed}!*std.Io.Writer {
            const a: *Self = @ptrCast(@alignCast(context));
            a.ensureOpen();
            if (a.failure != null) return error.ContentWriteFailed;
            const e = &a.store.engine;
            if (!e.chunkFits(id, index, n)) {
                a.pass();
                if (a.failure == null and !e.chunkFits(id, index, n)) return error.ContentWriteFailed;
            }
            const slot = a.reserve() orelse return error.ContentWriteFailed;
            const w = e.beginChunk(id, index) catch |err| {
                a.failure = err;
                return error.ContentWriteFailed;
            };
            slot.* = .{ .statement = null, .run = runChunk, .target = .{ .none = {} } };
            slot.borrowed = .of(struct {}, &.{});
            a.queued += 1;
            return w;
        }

        pub fn commit(a: *Self) Error!void {
            return a.commitFollowed(@as(?*Unfollowed, null));
        }

        pub fn commitFollowed(a: *Self, follow: anytype) Error!void {
            comptime std.debug.assert(transacts or mode == .single);
            if (@import("builtin").is_test) a.store.testing_content_work.rounds += 1;
            if (mode == .single and a.failure == null and a.queued != 1)
                @panic("a single Access commits exactly one write");
            if (!a.transactional()) {
                a.pass();
                if (a.failure) |err| return err;
                a.phase = .ended;
                return;
            }
            try a.finishWrites(follow);
            store_core.commit(a.store) catch |err| {
                a.failure = err;
                return err;
            };
            a.phase = .ended;
        }

        pub fn abandon(a: *Self, faults: store_core.Faults) Error!void {
            comptime std.debug.assert(transacts or mode == .single);
            if (a.phase == .ended) return;
            const opened = a.phase == .opened;
            const discarded = a.resetQueued();
            a.claimed = 0;
            a.phase = .ended;
            if (a.transactional() and opened) try store_core.rollbackAfterError(a.store, faults);
            try discarded;
        }

        pub fn end(a: *Self, faults: store_core.Faults, result: anytype) @TypeOf(result) {
            comptime std.debug.assert(transacts or mode == .single);
            _ = result catch |err| {
                a.abandon(faults) catch |failed| return failed;
                return err;
            };
            return result;
        }

        pub fn deinit(a: *Self) void {
            a.resetQueued() catch |err| {
                a.failure = err;
            };
            if (a.transactional() and a.phase == .opened) @panic("a write Access neither committed nor abandoned its transaction");
        }

        fn finishWrites(a: *Self, follow: anytype) Error!void {
            a.ensureOpen();
            if (!a.store.engine.batches()) a.pass();
            if (a.failure) |err| return err;
            for (a.claims[0..a.claimed]) |*claim| if (claim.taken != 0) {
                const expected = claim.head.next_position.get();
                _ = a.queueStatement(advance, &.{ .session = claim.head, .expected = expected, .next = expected + claim.taken }, runWrite(advance), .{ .none = {} });
            };
            if (mode != .single and a.obligation_count != 0) {
                try a.reconcileObligations();
            }
            const commits = a.bindCommit();
            if (commits and transacts) store_core.commitWithSurvey(a.store, a, follow) else a.pass();
            a.claimed = 0;
            if (commits) {
                if (a.store.engine.settleCommit()) |_| {
                    if (a.failure) |err| if (err == error.CommitOutcomeUnknown) {
                        a.failure = null;
                    };
                } else |err| a.failure = err;
            }
            if (a.failure) |err| return err;
        }

        fn transactional(a: *const Self) bool {
            return transacts or (mode == .single and a.store.engine.batches());
        }

        pub fn passCommit(a: *Self, tail: ?Tail) void {
            comptime std.debug.assert(transacts);
            a.passWith(tail);
        }

        pub fn asTail(a: *Self) Tail {
            comptime std.debug.assert(mode == .survey);
            return .{ .context = a, .step = stepTail };
        }

        fn stepTail(context: *anyopaque) bool {
            const a: *Self = @ptrCast(@alignCast(context));
            for (a.queue[0..a.queued]) |*entry| {
                if (a.failure != null) break;
                entry.run(a, entry) catch |err| {
                    a.failure = err;
                };
                a.store.engine.endStatement(entry.statement);
            }
            return a.failure == null;
        }

        fn bindCommit(a: *Self) bool {
            if (a.failure != null or !store_core.commitsWithWrites(a.store)) return false;
            const slot = a.reserve() orelse return false;
            if (!a.store.engine.appendCommit()) return false;
            slot.* = .{ .statement = null, .run = runCommit, .target = .{ .none = {} } };
            slot.borrowed = .of(struct {}, &.{});
            a.queued += 1;
            return true;
        }

        fn ensureOpen(a: *Self) void {
            std.debug.assert(a.phase != .ended);
            if (a.phase == .opened or a.failure != null) return;
            a.phase = .opened;
            if (a.transactional()) store_core.begin(a.store) catch |err| {
                a.failure = err;
            };
        }

        fn touch(a: *Self, head: rsql.SessionHead) void {
            const touched = &a.store.touched;
            if (touched.needsEntry(&head.ref)) touched.add(.{ .session = head.ref, .workspace = head.workspace_key.get() });
            if (reads_only or mode == .single) return;
            for (a.obligation_heads[0..a.obligation_count]) |known| if (std.mem.eql(u8, &known.ref, &head.ref)) return;
            if (a.obligation_count == a.obligation_heads.len) {
                a.reconcileObligations() catch |err| {
                    a.failure = err;
                    return;
                };
            }
            a.obligation_heads[a.obligation_count] = head;
            a.obligation_count += 1;
        }

        pub fn obligationsChanged(a: *Self, head: rsql.SessionHead) void {
            comptime std.debug.assert(transacts);
            a.touch(head);
        }

        pub fn obligationTouch(a: *Self, head: rsql.SessionHead) void {
            const touched = &a.store.touched;
            if (touched.needsEntry(&head.ref)) touched.add(.{ .session = head.ref, .workspace = head.workspace_key.get() });
        }

        pub fn visit(a: *Self, row: anytype) bool {
            return obligation.hint(a, row);
        }

        noinline fn reconcileObligations(a: *Self) Error!void {
            if (a.failure) |err| return err;
            if (a.obligation_count == 0) return;
            obligation.reconcile(a, a.obligation_heads[0..a.obligation_count]);
            a.obligation_count = 0;
        }

        fn queueStatement(a: *Self, comptime S: type, args: *const S.Args, runner: Runner, target: @FieldType(Queued, "target")) bool {
            a.ensureOpen();
            if (a.failure != null) return false;
            const statement = a.store.engine.statementFor(S) catch |err| {
                a.failure = err;
                return false;
            };
            // Full queues are sent by reserve, after the time and fit checks.
            // Check the other reasons separately to preserve that ordering.
            if (statement != null) for (a.queue[0..a.queued]) |entry| if (pass_plan.flushBefore(0, max_queued, entry.statement == statement, true)) {
                a.pass();
                break;
            };
            const now = if (S.uses_now) store_core.transactionSecond(a.store) catch |err| {
                a.failure = err;
                return false;
            } else 0;
            const fits = a.store.engine.fits(S, args, now) catch |err| {
                a.failure = err;
                return false;
            };
            if (pass_plan.flushBefore(0, max_queued, false, fits)) a.pass();
            const slot = a.reserve() orelse return false;
            slot.* = .{ .statement = statement, .run = runner, .target = target };
            a.store.engine.bind(statement, S, args, now) catch |err| {
                a.store.engine.discard(statement);
                a.failure = err;
                return false;
            };
            slot.borrowed = .of(S.Args, args);
            if (comptime S.kind == .write and !reads_only and S.guarded) {
                const e = &a.store.engine;
                const bound = switch (S.expect) {
                    .exact => |exact| e.guard(false, exact.rows),
                    .at_most => |rows| e.guard(true, rows),
                    .counted => e.guard(false, target.counted),
                };
                if (bound) a.guarded |= @as(Guarded, 1) << @intCast(a.queued);
            }
            a.queued += 1;
            return true;
        }

        fn reserve(a: *Self) ?*Queued {
            if (a.failure == null and pass_plan.flushBefore(a.queued, max_queued, false, true)) a.pass();
            if (a.failure != null) return null;
            return &a.queue[a.queued];
        }

        fn poison(destination: anytype) void {
            if (poisons) @memset(std.mem.asBytes(destination), poison_byte);
        }

        fn resetQueued(a: *Self) Failure!void {
            for (a.queue[0..a.queued]) |entry| a.store.engine.discard(entry.statement);
            a.queued = 0;
            a.guarded = 0;
            try a.store.engine.discardBatch();
        }

        const Runner = *const fn (*Self, *const Queued) Error!void;

        fn named(comptime S: type, comptime step: fn (*Self, *const Queued) Error!void) Runner {
            return &struct {
                fn run(a: *Self, entry: *const Queued) Error!void {
                    step(a, entry) catch |err| {
                        a.failed_sql = S.sql.ptr;
                        return err;
                    };
                }
            }.run;
        }

        fn runRead(comptime S: type) Runner {
            return named(S, struct {
                fn run(a: *Self, entry: *const Queued) Error!void {
                    const e = &a.store.engine;
                    const statement = entry.statement;
                    const destination: *S.Result = @ptrCast(@alignCast(entry.target.destination));
                    switch (S.cardinality) {
                        .one => {
                            if (!try e.nextRow(statement)) return error.CorruptStore;
                            try e.decodeRow(S.Row, statement, destination);
                            if (!S.single_row and try e.nextRow(statement)) return error.CorruptStore;
                        },
                        .optional => {
                            if (!try e.nextRow(statement)) {
                                destination.* = null;
                                return;
                            }
                            var row: S.Row = undefined;
                            try e.decodeRow(S.Row, statement, &row);
                            destination.* = row;
                            if (!S.single_row and try e.nextRow(statement)) return error.CorruptStore;
                        },
                        .at_most => |max| {
                            destination.len = 0;
                            while (try e.nextRow(statement)) {
                                if (destination.len == max) return error.CorruptStore;
                                try e.decodeRow(S.Row, statement, &destination.items[destination.len]);
                                destination.len += 1;
                                if (S.single_row) break;
                            }
                        },
                        .each => @compileError("readEach runs an .each read"),
                    }
                }
            }.run);
        }

        fn runInto(comptime S: type) Runner {
            return named(S, struct {
                fn run(a: *Self, entry: *const Queued) Error!void {
                    const e = &a.store.engine;
                    const statement = entry.statement;
                    const into = entry.target.into;
                    if (!try e.nextRow(statement)) {
                        into.found.* = .missing;
                        return;
                    }
                    into.found.* = .found;
                    try e.decodeRow(S.Row, statement, @ptrCast(@alignCast(into.row)));
                    if (!S.single_row and try e.nextRow(statement)) return error.CorruptStore;
                }
            }.run);
        }

        fn runEach(comptime S: type, comptime Visitor: type) Runner {
            return named(S, struct {
                fn run(a: *Self, entry: *const Queued) Error!void {
                    const e = &a.store.engine;
                    const statement = entry.statement;
                    const each = entry.target.each;
                    const visitor: *Visitor = @ptrCast(@alignCast(each.visitor));
                    const owned = comptime @hasField(Visitor, "decoded");
                    var local: if (owned) void else S.Row = undefined;
                    const row: *S.Row = if (owned) (if (@FieldType(Visitor, "decoded") == *S.Row) visitor.decoded else &visitor.decoded) else &local;
                    var stepped: u64 = 0;
                    while (stepped < each.limit and try e.nextRow(statement)) : (stepped += 1) {
                        try e.decodeRow(S.Row, statement, row);
                        if (!visitor.visit(row)) break;
                    }
                }
            }.run);
        }

        fn runWrite(comptime S: type) Runner {
            return named(S, struct {
                fn run(a: *Self, entry: *const Queued) Error!void {
                    const changed = try a.store.engine.stepWrite(entry.statement);
                    const expected: pass_plan.Expect = switch (S.expect) {
                        .exact => |guard| .{ .exact = guard.rows },
                        .at_most => |rows| .{ .at_most = rows },
                        .counted => .counted,
                    };
                    const stated = if (S.expect == .counted) entry.target.counted else 0;
                    switch (pass_plan.verdict(expected, changed, stated)) {
                        .ok => {},
                        .corrupt => return error.CorruptStore,
                        .otherwise => switch (S.expect) {
                            .exact => |guard| return comptime @as(Error, @errorCast(guard.otherwise)),
                            .counted => |guard| return comptime @as(Error, @errorCast(guard.otherwise)),
                            .at_most => unreachable,
                        },
                    }
                    const slot = entry - @as([*]const Queued, &a.queue);
                    if (a.guarded >> @intCast(slot) & 1 != 0) _ = try a.store.engine.stepWrite(entry.statement);
                }
            }.run);
        }

        fn runCommit(a: *Self, _: *const Queued) Error!void {
            try a.store.engine.stepCommit();
        }

        fn runChunk(a: *Self, _: *const Queued) Error!void {
            if (try a.store.engine.stepWrite(null) != 1) return error.CorruptStore;
        }

        fn runPayload(a: *Self, entry: *const Queued) Error!void {
            const payload = entry.target.payload;
            if (payload.bytes.len == 0) return;
            try a.store.engine.stepPayload(payload.content_id, payload.bytes);
        }
    };
}

pub fn eachVisitorError(comptime Row: type, comptime Visitor: type) ?[]const u8 {
    if (!@hasField(Visitor, "decoded")) {
        if (rsql.fillsInPlace(Row)) return "rsql: an .each Row that points into its caller's memory decodes into its visitor's own decoded field";
        return if (@sizeOf(Row) > 1024) "rsql: an .each Row over 1 KiB decodes into its visitor's own decoded field" else null;
    }
    if (@FieldType(Visitor, "decoded") != Row and @FieldType(Visitor, "decoded") != *Row) return "rsql: a visitor's decoded field is the Row or *Row its .each read decodes, " ++ @typeName(Row);
    return null;
}

pub fn runAs(a: anytype, comptime failed: anytype) (RunError(@TypeOf(a.*)) || @TypeOf(failed))!void {
    return runNamed(a, .{}, failed);
}

pub fn runNamed(a: anytype, comptime named: anytype, comptime otherwise: anytype) (RunError(@TypeOf(a.*)) || NamedErrors(named) || @TypeOf(otherwise))!void {
    a.run() catch |err| {
        if (err != error.StatementFailed) return err;
        return failedName(a, named) orelse otherwise;
    };
}

pub fn failedName(a: anytype, comptime named: anytype) ?NamedErrors(named) {
    inline for (named) |pair| if (a.failedOn(pair[0])) return pair[1];
    return null;
}

fn RunError(comptime A: type) type {
    return @import("../error_set.zig").Of(A.run);
}

fn NamedErrors(comptime named: anytype) type {
    comptime var set: type = error{};
    inline for (named) |pair| set = set || @TypeOf(pair[1]);
    return set;
}
