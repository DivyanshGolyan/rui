//! Transition Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const change_ring = @import("../../change_ring.zig");
const store_core = @import("../Store.zig");
const transition = @import("../transition.zig");
const rsql = @import("../rsql.zig");
const Store = store_core.Store;
const content_domain = @import("../domain/content.zig");
const store_testing = @import("../testing.zig");
const configureTestSession = store_testing.configureTestSession;
const TestingRound = shared_fixtures.TestingRound;
const RoundMeter = shared_fixtures.RoundMeter;

/// Reads a Session's head in its one round, then takes two positions and
/// a content id, inserts that content row and dates the Session where its
/// revision is `revision`, and commits or, with `.done`, ends without.
const TestingDating = struct {
    pub const rounds = transition.rounds(.{ .head = .{ .always, error.TestingRead } });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = null;
    pub const Input = struct { session: []const u8, revision: u64, finish: enum { commit, done } };
    pub const Result = union(enum) { committed: u64, declined, done };
    pub const Ordinary = error{};
    pub const Declined = error{TestingGuard};
    pub const Guards = Declined;

    input: Input,
    loaded: TestingRound.head.Result = undefined,
    first: u64 = 0,

    pub fn step(t: *TestingDating, r: *transition.Round(TestingDating), ran: ?rounds.At) !transition.Next(TestingDating) {
        if (ran == null) {
            r.read(TestingRound.head, .{ .session_ref = t.input.session }, &t.loaded);
            return .{ .round = .head };
        }
        const positions = try r.positions(t.loaded.head);
        t.first = try positions.take(2);
        const content_id = try r.identity(.content_id);
        r.write(TestingRound.insert_content, .{ .content_id = content_id, .digest = protocol.contentDigest("dated"), .length = 5 });
        r.write(TestingRound.date_session, .{ .session = t.loaded.head, .revision = t.input.revision });
        return switch (t.input.finish) {
            .commit => .commit,
            .done => .{ .done = .done },
        };
    }

    pub fn committed(t: *const TestingDating) Result {
        return .{ .committed = t.first };
    }

    pub fn declined(_: *const TestingDating, _: Declined) Result {
        return .declined;
    }
};

/// What a `TestingDating` changes, to compare before and after.
const TestingDatingState = struct {
    next_position: u64,
    contents: u64,
    content_id: u64,
    created_at: u64,

    fn of(storage: *Store) !TestingDatingState {
        return .{
            .next_position = try store_testing.queryU64(storage, "SELECT next_position FROM session", .{}),
            .contents = try store_testing.queryU64(storage, "SELECT count(*) FROM content", .{}),
            .content_id = storage.identities().next.get(.content_id),
            .created_at = try store_testing.queryU64(storage, "SELECT created_at FROM session", .{}),
        };
    }
};

test "a transition's commit lands its writes, positions and identities and answers committed" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "transition-commit");
            const before: TestingDatingState = try .of(&storage);
            const rounds = storage.testing_content_work.rounds;
            const result = try transition.apply(&storage, TestingDating, .{ .session = session.slice(), .revision = 1, .finish = .commit }, .{});
            try std.testing.expectEqual(TestingDating.Result{ .committed = before.next_position }, result);
            // Head and commit, with frontier maintenance inline; rerun repeats them.
            if (!case.rerun) try std.testing.expectEqual(rounds + 2, storage.testing_content_work.rounds);
            const after: TestingDatingState = try .of(&storage);
            try std.testing.expectEqual(before.next_position + 2, after.next_position);
            try std.testing.expectEqual(before.content_id, try store_testing.queryU64(&storage, "SELECT content_id FROM content WHERE byte_length=5 AND digest=?1", .{store_testing.Blob{ .bytes = &protocol.contentDigest("dated") }}));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "a transition that ends done leaves nothing it queued" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "transition-done");
            const before: TestingDatingState = try .of(&storage);
            const result = try transition.apply(&storage, TestingDating, .{ .session = session.slice(), .revision = 1, .finish = .done }, .{});
            try std.testing.expectEqual(TestingDating.Result.done, result);
            try std.testing.expectEqual(before, try TestingDatingState.of(&storage));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "a transition's declined guard answers declined and leaves nothing it queued" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "transition-declined");
            const before: TestingDatingState = try .of(&storage);
            // No revision 99: the dating write's guard stops the commit.
            const result = try transition.apply(&storage, TestingDating, .{ .session = session.slice(), .revision = 99, .finish = .commit }, .{});
            try std.testing.expectEqual(TestingDating.Result.declined, result);
            try std.testing.expectEqual(before, try TestingDatingState.of(&storage));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

/// Queues twenty content rows, twenty statements, in one round inside its
/// transaction, then ends done, so none of them stays.
fn TestingPassWidth(comptime width: transition.Pass) type {
    return struct {
        const Self = @This();
        pub const rounds = transition.rounds(.{ .write = .{.always} });
        pub const round_budget = 2;
        pub const commit: transition.Commit = .transaction;
        pub const pass = width;
        pub const begin: ?rounds.At = .write;
        pub const Input = struct {};
        pub const Result = void;
        pub const Ordinary = error{};
        pub const Declined = error{};
        pub const Guards = Declined;
        const text = "abcdefghijklmnopqrst";

        input: Input,

        pub fn step(_: *Self, r: *transition.Round(Self), ran: ?rounds.At) !transition.Next(Self) {
            if (ran != null) return .{ .done = {} };
            for (0..text.len) |index| _ = try content_domain.insertRow(r, &.ofBytes(text[index..][0..1], false));
            return .{ .round = .write };
        }

        pub fn committed(_: *const Self) Result {}
    };
}

test "a transition with a wide pass steps twenty statements a pass, an ordinary one twelve" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var passes: [2]u64 = undefined;
            inline for (.{ transition.Pass.wide, transition.Pass.ordinary }, &passes) |width, *taken| {
                const before = RoundMeter.QueryShape.snapshot(&storage);
                try transition.apply(&storage, TestingPassWidth(width), .{}, .{});
                taken.* = RoundMeter.QueryShape.snapshot(&storage).since(before).access_passes;
            }
            try std.testing.expect(!storage.isFenced());
            // Only a batching engine sends passes, and a rerun repeats them.
            if (case.engine != .mysql or case.rerun) return;
            try std.testing.expectEqual([2]u64{ 1, 2 }, passes);
        }
    }.run);
}

/// Asks whether its transaction is open before and after its first step
/// queues a read, then ends done. `.outside` has no `begin`, so its read
/// runs outside the transaction; `.failed` also queues an insert of a
/// content id the Store holds, which fails in the pass that twelve more
/// statements force.
fn TestingTransactionOpen(comptime path: enum { outside, inside, failed }) type {
    return struct {
        const Self = @This();
        pub const rounds = transition.rounds(.{ .head = .{.always} });
        pub const round_budget = 2;
        pub const commit: transition.Commit = .transaction;
        pub const begin: ?rounds.At = if (path == .outside) null else .head;
        pub const Input = struct { session: []const u8, taken: u64 };
        pub const Result = [3]bool;
        pub const Ordinary = error{};
        pub const Declined = error{};
        pub const Guards = Declined;

        input: Input,
        loaded: TestingRound.head.Result = undefined,
        open: [3]bool = @splat(false),

        pub fn step(t: *Self, r: *transition.Round(Self), ran: ?rounds.At) !transition.Next(Self) {
            if (ran != null) {
                t.open[2] = r.transactionOpen();
                return .{ .done = t.open };
            }
            t.open[0] = r.transactionOpen();
            r.read(TestingRound.head, .{ .session_ref = t.input.session }, &t.loaded);
            if (path == .failed) {
                for (0..13) |_| r.write(TestingRound.insert_content, .{ .content_id = t.input.taken, .digest = @splat(0), .length = 0 });
                t.open[1] = r.transactionOpen();
                return .{ .done = t.open };
            }
            t.open[1] = r.transactionOpen();
            return .{ .round = .head };
        }

        pub fn committed(t: *const Self) Result {
            return t.open;
        }
    };
}

test "a step sees its transaction open once it queues from begin on, and never before begin" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "transition-open");
            const taken = try store_testing.queryU64(&storage, "SELECT min(content_id) FROM content", .{});
            const input: TestingTransactionOpen(.inside).Input = .{ .session = session.slice(), .taken = taken };
            try std.testing.expectEqual([3]bool{ false, true, true }, try transition.apply(&storage, TestingTransactionOpen(.inside), input, .{}));
            try std.testing.expectEqual([3]bool{ false, false, false }, try transition.apply(&storage, TestingTransactionOpen(.outside), input, .{}));
            try std.testing.expectEqual([3]bool{ false, false, false }, try transition.apply(&storage, TestingTransactionOpen(.failed), input, .{}));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

/// Counts Sessions a page of one at a time, in a `.paged` round that runs
/// again until a page finds none.
const TestingSessionPages = struct {
    pub const rounds = transition.rounds(.{
        .first = .{ .always, error.TestingRead },
        .next = .{ .paged, error.TestingRead },
    });
    pub const round_budget = 1;
    pub const commit: transition.Commit = .none;
    pub const begin: ?rounds.At = null;
    pub const Input = struct {};
    pub const Result = u64;
    pub const Ordinary = error{};
    const after_ref = rsql.Read(.{
        .sql = "SELECT session_ref,workspace_key,next_position FROM session WHERE session_ref>?1 ORDER BY session_ref",
        .Args = struct { after: []const u8 },
        .Row = struct { head: rsql.SessionHead },
        .cardinality = .each,
    });

    input: Input,
    counted: u64 = 0,
    page_rows: u64 = 0,
    /// The page's argument, which its statement reads in place.
    after: change_ring.Id = @splat(0),
    after_len: usize = 0,
    /// The last row a page stepped.
    last: change_ring.Id = undefined,

    pub fn step(t: *TestingSessionPages, r: *transition.Round(TestingSessionPages), ran: ?rounds.At) !transition.Next(TestingSessionPages) {
        if (ran != null) {
            if (t.page_rows == 0) return .{ .done = t.counted };
            t.after = t.last;
            t.after_len = t.after.len;
        }
        t.page_rows = 0;
        // Through `readEachFrom`, whose Args the call need not keep.
        r.readEachFrom(after_ref, &.{ .after = t.after[0..t.after_len] }, 1, t);
        return .{ .round = if (ran == null) .first else .next };
    }

    pub fn visit(t: *TestingSessionPages, row: *const after_ref.Row) bool {
        t.counted += 1;
        t.page_rows += 1;
        t.last = row.head.ref;
        return true;
    }
};

test "a transition's paged round runs again for each page" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            for ([_][]const u8{ "pages-a", "pages-b", "pages-c" }) |key| _ = try configureTestSession(&storage, key);
            const sessions = try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{});
            const rounds = storage.testing_content_work.rounds;
            try std.testing.expectEqual(sessions, try transition.apply(&storage, TestingSessionPages, .{}, .{}));
            // A page per Session, then the empty one.
            try std.testing.expectEqual(rounds + sessions + 1, storage.testing_content_work.rounds);
        }
    }.run);
}

/// Reads a Session's head and the content count in one round, which names
/// the head's failed step apart from any other's.
const TestingNamedRound = struct {
    pub const rounds = transition.rounds(.{
        .reads = .{ .always, error.TestingRead, .{.{ TestingRound.head, error.TestingHeadRead }} },
    });
    pub const round_budget = 1;
    pub const commit: transition.Commit = .none;
    pub const begin: ?rounds.At = null;
    pub const Input = struct { session: []const u8 };
    pub const Result = void;
    pub const Ordinary = error{ TestingRead, TestingHeadRead };
    const contents = rsql.Read(.{
        .sql = "SELECT count(*) AS count FROM content",
        .Args = struct {},
        .Row = struct { count: u64 },
        .cardinality = .one,
    });

    input: Input,
    head: TestingRound.head.Result = undefined,
    count: contents.Row = undefined,

    pub fn step(t: *TestingNamedRound, r: *transition.Round(TestingNamedRound), ran: ?rounds.At) !transition.Next(TestingNamedRound) {
        if (ran != null) return .{ .done = {} };
        r.read(contents, .{}, &t.count);
        r.read(TestingRound.head, .{ .session_ref = t.input.session }, &t.head);
        return .{ .round = .reads };
    }
};

test "a transition's round names the failed step of each statement it names, and the round's name answers for the rest" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            inline for (.{ .{ "session", error.TestingHeadRead }, .{ "content", error.TestingRead } }) |failing| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "transition-named");
                try transition.apply(&storage, TestingNamedRound, .{ .session = session.slice() }, .{});
                try store_testing.failReadsOf(&storage, failing[0]);
                try std.testing.expectError(failing[1], transition.apply(&storage, TestingNamedRound, .{ .session = session.slice() }, .{}));
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

/// Dates a Session and, where `follow`, reads its date back after COMMIT
/// in the commit's message: the reads a transition's `follow` names.
const TestingFollow = struct {
    pub const rounds = transition.rounds(.{ .head = .{ .always, error.TestingRead } });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = null;
    pub const Input = struct { session: []const u8, follow: bool };
    /// The date the follow read, or null where it did not ride.
    pub const Result = ?u64;
    pub const Ordinary = error{};
    pub const Guards = error{TestingGuard};
    pub const Declined = error{};
    const created = rsql.Read(.{
        .sql = "SELECT created_at FROM session WHERE session_ref=?1",
        .Args = struct { session_ref: []const u8 },
        .Row = struct { created_at: u64 },
        .cardinality = .one,
    });

    input: Input,
    loaded: TestingRound.head.Result = undefined,
    after: After = .{},

    const After = struct {
        session: []const u8 = &.{},
        row: created.Row = undefined,
        seen: ?u64 = null,

        pub fn queue(after: *After, reads: anytype) void {
            reads.read(created, .{ .session_ref = after.session }, &after.row);
        }

        pub fn followed(after: *After) void {
            after.seen = after.row.created_at;
        }
    };

    pub fn step(t: *TestingFollow, r: *transition.Round(TestingFollow), ran: ?rounds.At) !transition.Next(TestingFollow) {
        if (ran == null) {
            r.read(TestingRound.head, .{ .session_ref = t.input.session }, &t.loaded);
            return .{ .round = .head };
        }
        r.write(TestingRound.date_session, .{ .session = t.loaded.head, .revision = 1 });
        t.after.session = t.input.session;
        return .commit;
    }

    pub fn follow(t: *TestingFollow) ?*After {
        return if (t.input.follow) &t.after else null;
    }

    pub fn committed(t: *const TestingFollow) Result {
        return t.after.seen;
    }

    /// The body a queued write runs, so the commit is its batch's first.
    fn held(storage: *Store, session: []const u8, follows: bool) !Result {
        return transition.apply(storage, TestingFollow, .{ .session = session, .follow = follows }, .{});
    }
};

test "a transition's follow reads ride its commit's message where that message carries reads, and cost no round" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "transition-follow");
            for ([_]bool{ false, true }) |follows| {
                const rounds = storage.testing_content_work.rounds;
                const seen = try storage.queue().write(TestingFollow.held, .{ &storage, session.slice(), follows });
                // A rerun commits at its batch's end, with nothing after it.
                if (case.rerun) continue;
                // The head's round, then the commit, which the reads ride.
                try std.testing.expectEqual(rounds + 2, storage.testing_content_work.rounds);
                // Only a network engine's lone write sends COMMIT with reads after it.
                if (follows and case.engine == .mysql) {
                    try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT created_at FROM session", .{}), seen.?);
                } else try std.testing.expectEqual(@as(?u64, null), seen);
            }
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

/// Dates a Session where its revision is `revision`, or fails its step
/// after the head's round, noting in `failed` when the runner calls its
/// failure hook.
const TestingFailing = struct {
    pub const rounds = transition.rounds(.{ .head = .{ .always, error.TestingRead } });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = null;
    pub const Input = struct { session: []const u8, revision: u64, fail_step: bool, failed: *bool };
    pub const Result = void;
    pub const Ordinary = error{ TestingGuard, TestingStep };
    pub const Guards = error{TestingGuard};
    pub const Declined = error{};

    input: Input,
    loaded: TestingRound.head.Result = undefined,

    pub fn step(t: *TestingFailing, r: *transition.Round(TestingFailing), ran: ?rounds.At) !transition.Next(TestingFailing) {
        if (ran == null) {
            r.read(TestingRound.head, .{ .session_ref = t.input.session }, &t.loaded);
            return .{ .round = .head };
        }
        r.write(TestingRound.date_session, .{ .session = t.loaded.head, .revision = t.input.revision });
        if (t.input.fail_step) return error.TestingStep;
        return .commit;
    }

    pub fn committed(_: *const TestingFailing) Result {}

    pub fn failed(t: *TestingFailing) void {
        t.input.failed.* = true;
    }
};

test "a transition's failure hook runs when a step or its commit fails, and only then" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "transition-failing");
            const before: TestingDatingState = try .of(&storage);
            var failed = false;
            // A guard the commit does not decline, then a step's error.
            try std.testing.expectError(error.TestingGuard, transition.apply(&storage, TestingFailing, .{ .session = session.slice(), .revision = 99, .fail_step = false, .failed = &failed }, .{}));
            try std.testing.expect(failed);
            failed = false;
            try std.testing.expectError(error.TestingStep, transition.apply(&storage, TestingFailing, .{ .session = session.slice(), .revision = 1, .fail_step = true, .failed = &failed }, .{}));
            try std.testing.expect(failed);
            try std.testing.expectEqual(before, try TestingDatingState.of(&storage));
            failed = false;
            try transition.apply(&storage, TestingFailing, .{ .session = session.slice(), .revision = 1, .fail_step = false, .failed = &failed }, .{});
            try std.testing.expect(!failed);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

/// Reads a Session's head once outside its transaction and once inside,
/// noting each time whether the transaction is open, then dates the
/// Session where its revision is `revision`.
const TestingBegin = struct {
    pub const rounds = transition.rounds(.{ .outside = .{.always}, .inside = .{.always} });
    pub const round_budget = 3;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .inside;
    pub const Input = struct { storage: *Store, session: []const u8, revision: u64 };
    pub const Result = [2]bool;
    pub const Ordinary = error{TestingGuard};
    pub const Guards = error{TestingGuard};
    pub const Declined = error{};

    input: Input,
    loaded: TestingRound.head.Result = undefined,
    open: [2]bool = .{ true, false },

    pub fn step(t: *TestingBegin, r: *transition.Round(TestingBegin), ran: ?rounds.At) !transition.Next(TestingBegin) {
        const at = ran orelse {
            r.read(TestingRound.head, .{ .session_ref = t.input.session }, &t.loaded);
            return .{ .round = .outside };
        };
        t.open[@backingInt(at)] = t.input.storage.engine.inTransaction();
        if (at == .outside) {
            r.read(TestingRound.head, .{ .session_ref = t.input.session }, &t.loaded);
            return .{ .round = .inside };
        }
        r.write(TestingRound.date_session, .{ .session = t.loaded.head, .revision = t.input.revision });
        return .commit;
    }

    pub fn committed(t: *const TestingBegin) Result {
        return t.open;
    }
};

test "a transition's rounds before begin read outside its transaction and the rest inside" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "transition-begin");
            const open = try transition.apply(&storage, TestingBegin, .{ .storage = &storage, .session = session.slice(), .revision = 1 }, .{});
            try std.testing.expectEqual([2]bool{ false, true }, open);
            try std.testing.expect(!storage.engine.inTransaction());
        }
    }.run);
}

test "a transition's guard that it does not decline fails it and leaves nothing it queued" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "transition-guard");
            const before: TestingDatingState = try .of(&storage);
            // No revision 99: the dating write's guard stops the commit.
            try std.testing.expectError(error.TestingGuard, transition.apply(&storage, TestingBegin, .{ .storage = &storage, .session = session.slice(), .revision = 99 }, .{}));
            try std.testing.expectEqual(before, try TestingDatingState.of(&storage));
            try std.testing.expect(!storage.engine.inTransaction());
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "a transition's rounds run in declared order and only a paged round repeats" {
    const R = transition.rounds(.{
        .a = .{ .always, error.TestingRead },
        .b = .{ .paged, error.TestingRead },
        .c = .{ .branch, error.TestingRead },
    });
    const At = R.At;
    // Rows: the round that ran (none first); columns: a, b, c next.
    const cases = [_]struct { last: ?At, allowed: [3]bool }{
        .{ .last = null, .allowed = .{ true, true, true } },
        .{ .last = .a, .allowed = .{ false, true, true } },
        .{ .last = .b, .allowed = .{ false, true, true } },
        .{ .last = .c, .allowed = .{ false, false, false } },
    };
    for (cases) |row| for ([_]At{ .a, .b, .c }, row.allowed) |next, allowed| {
        try std.testing.expectEqual(allowed, R.follows(row.last, next));
    };
}
