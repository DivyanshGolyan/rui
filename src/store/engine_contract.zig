//! The engine contract: what every engine must honour for the Store's rule suites to run on one engine
//! (docs/contracts/store.md "Store tests per engine"). Each test owns one catalog row (docs/invariants/store-host.md);
//! rows that name a MySQL-only witness run it on the plain MySQL leg only, and the rule suites use SQLite alone.

const action_domain = @import("domain/action.zig");
const ActionExecutionInput = action_domain.ActionExecutionInput;
const ActiveOperationFilter = action_domain.ActiveOperationFilter;
const Bounded = @import("../bounded.zig").Bounded;
const canonicalCwd = store_testing.canonicalCwd;
const change_ring = @import("../change_ring.zig");
const completeConfiguration = store_testing.completeConfiguration;
const completeSessionStop = shared_fixtures.completeSessionStop;
const configuration_domain = @import("domain/configuration.zig");
const configureTestSessionAsk = shared_fixtures.configureTestSessionAsk;
const Connection = mysql_connection.Connection;
const content_domain = @import("domain/content.zig");
const ContentReader = content_domain.ContentReader;
const ContentReference = content_domain.ContentReference;
const Drop = @TypeOf(@as(@import("engine/Mysql.zig").State, undefined).testing_drop);
const EntryPoint = shared_fixtures.EntryPoint;
const expectContent = shared_fixtures.expectContent;
const historical_domain = @import("domain/historical.zig");
const HistoricalEntryKind = historical_domain.HistoricalEntryKind;
const HistoricalSettings = historical_domain.HistoricalSettings;
const literal = @import("mysql_literal.zig");
const ModelOperationKind = historical_domain.ModelOperationKind;
const Mysql = @import("engine/Mysql.zig");
const mysql_connection = @import("wire/mysql_connection.zig");
const nextTestingItem = shared_fixtures.nextTestingItem;
const openCheckedView = shared_fixtures.openCheckedView;
const os = @import("os");
const protocol = @import("../protocol.zig");
const reads_domain = @import("domain/reads.zig");
const report_domain = @import("domain/report.zig");
const round_budgets = shared_fixtures.round_budgets;
const pass_budgets = shared_fixtures.pass_budgets;
const rsql = @import("rsql.zig");
const schema = @import("schema.zig");
const SessionPinReply = @import("../command_reply.zig").SessionPinReply;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const settleCallsForTestingWithFaults = shared_fixtures.settleCallsForTestingWithFaults;
const settleCompactionForTesting = store_testing.settleCompactionForTesting;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const settleMessagesForTesting = shared_fixtures.settleMessagesForTesting;
const shared_fixtures = @import("tests.zig");
const skills_fixture_domain = @import("domain/skills.zig");
const std = @import("std");
const store_access = @import("access.zig");
const store_core = @import("Store.zig");
const store_schema = @import("schema.zig");
const store_testing = @import("testing.zig");
const submitTestMessage = store_testing.submitTestMessage;
const testing = @import("testing.zig");
const testingAgentSpec = shared_fixtures.testingAgentSpec;
const TestingAsk = @import("tests.zig").TestingAsk;
const TestingCall = shared_fixtures.TestingCall;
const testingContent = shared_fixtures.testingContent;
const testingHostToolRecords = shared_fixtures.testingHostToolRecords;
const TestingPage = store_testing.TestingPage;
const TestingScript = @import("tests.zig").TestingScript;
const testingSessionList = shared_fixtures.testingSessionList;
const testingSessionReport = shared_fixtures.testingSessionReport;
const tool_defs = @import("../tools.zig");
const tool_set_domain = @import("domain/tool_set.zig");
const touchForTesting = shared_fixtures.touchForTesting;
const transition = @import("transition.zig");
const ViewRounds = shared_fixtures.ViewRounds;
const wire = @import("wire/mysql_connection.zig");
const wire_request = @import("../wire_request.zig");
const ms = @import("mysql_session_tests.zig");
const mt = @import("mysql_testing.zig");
const pt = @import("pin_tests.zig");

// Fixtures moved from the mechanism suites (src/store/tests/transition.zig, access.zig and the rest).
const Worker = struct {
    storage: *pt.Store,
    gate: *std.Io.Event,
    input: protocol.SessionPinCommand,
    reply: SessionPinReply = .infrastructure_failure,

    fn run(self: *@This()) void {
        self.gate.waitUncancelable(std.testing.io);
        self.reply = self.storage.pinSession(&self.input, .{});
    }
};

const Store = store_core.Store;

const configureTestSession = store_testing.configureTestSession;

const TestingRound = shared_fixtures.TestingRound;

const RoundMeter = shared_fixtures.RoundMeter;

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
    after: change_ring.Id = @splat(0),
    after_len: usize = 0,
    last: change_ring.Id = undefined,

    pub fn step(t: *TestingSessionPages, r: *transition.Round(TestingSessionPages), ran: ?rounds.At) !transition.Next(TestingSessionPages) {
        if (ran != null) {
            if (t.page_rows == 0) return .{ .done = t.counted };
            t.after = t.last;
            t.after_len = t.after.len;
        }
        t.page_rows = 0;
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

const TestingFollow = struct {
    pub const rounds = transition.rounds(.{ .head = .{ .always, error.TestingRead } });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = null;
    pub const Input = struct { session: []const u8, follow: bool };
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

    fn held(storage: *Store, session: []const u8, follows: bool) !Result {
        return transition.apply(storage, TestingFollow, .{ .session = session, .follow = follows }, .{});
    }
};

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

const counted_dating = rsql.Write(.{
    .sql = "UPDATE session SET created_at=?2 WHERE session_ref=@session(?1) AND revision=?3",
    .Args = struct { session: rsql.SessionHead, at: u64, revision: u64 },
    .expect = .{ .counted = .{ .otherwise = error.TestingGuard } },
});

fn countedDatingForTesting(storage: *Store, session: []const u8, at: u64, revision: u64, rows: u64) !void {
    const Counted = struct {
        pub const Guards = error{TestingGuard};
        session: []const u8,
        at: u64,
        revision: u64,
        rows: u64,
        loaded: TestingRound.head.Result = undefined,

        pub fn step(b: *@This(), r: anytype, ran: u32) !TestingAsk {
            if (ran == 0) {
                r.read(TestingRound.head, .{ .session_ref = b.session }, &b.loaded);
                return .round;
            }
            r.writeCount(counted_dating, .{ .session = b.loaded.head, .at = b.at, .revision = b.revision }, b.rows);
            return .commit;
        }
    };
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    var counted: Counted = .{ .session = session, .at = at, .revision = revision, .rows = rows };
    return entry.finishTransaction(error{TestingGuard}, .{}, TestingScript(Counted).run(&entry, &counted));
}

fn contentRoundBudget(engine: store_testing.Engine, point: EntryPoint) u16 {
    return switch (engine) {
        .sqlite, .mysql => switch (point) {
            .readOwnedContent, .readHostToolSetText, .searchActivity, .findTools, .readSkills => 1,
            else => 0,
        },
    };
}

// Moved from src/store/tests/transition.zig: "a transition's commit lands its writes, positions and identities and answers committed"
fn sh103_a_transition_s_commit_lands_its_writes(case: *store_testing.Case) !void {
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
    if (!case.rerun) try std.testing.expectEqual(rounds + 2, storage.testing_content_work.rounds);
    const after: TestingDatingState = try .of(&storage);
    try std.testing.expectEqual(before.next_position + 2, after.next_position);
    try std.testing.expectEqual(before.content_id, try store_testing.queryU64(&storage, "SELECT content_id FROM content WHERE byte_length=5 AND digest=?1", .{store_testing.Blob{ .bytes = &protocol.contentDigest("dated") }}));
    try std.testing.expect(!storage.isFenced());
}

// Moved from src/store/tests/transition.zig: "a transition that ends done leaves nothing it queued"
fn sh103_a_transition_that_ends_done_leaves_nothing(case: *store_testing.Case) !void {
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

// Moved from src/store/tests/transition.zig: "a transition's declined guard answers declined and leaves nothing it queued"
fn sh103_a_transition_s_declined_guard_answers_declined(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "transition-declined");
    const before: TestingDatingState = try .of(&storage);
    const result = try transition.apply(&storage, TestingDating, .{ .session = session.slice(), .revision = 99, .finish = .commit }, .{});
    try std.testing.expectEqual(TestingDating.Result.declined, result);
    try std.testing.expectEqual(before, try TestingDatingState.of(&storage));
    try std.testing.expect(!storage.isFenced());
}

// Moved from src/store/tests/transition.zig: "a transition's failure hook runs when a step or its commit fails, and only then"
fn sh103_a_transition_s_failure_hook_runs_when(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "transition-failing");
    const before: TestingDatingState = try .of(&storage);
    var failed = false;
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

// Moved from src/store/tests/transition.zig: "a transition's guard that it does not decline fails it and leaves nothing it queued"
fn sh103_a_transition_s_guard_that_it_does(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "transition-guard");
    const before: TestingDatingState = try .of(&storage);
    try std.testing.expectError(error.TestingGuard, transition.apply(&storage, TestingBegin, .{ .storage = &storage, .session = session.slice(), .revision = 99 }, .{}));
    try std.testing.expectEqual(before, try TestingDatingState.of(&storage));
    try std.testing.expect(!storage.engine.inTransaction());
    try std.testing.expect(!storage.isFenced());
}

// Moved from src/store/mysql_testing.zig: "store.mysql live reused savepoint replaces its position and preserves earlier writes"
fn sh5_store_mysql_live_reused_savepoint_replaces_its() !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: mt.Store = undefined;
    try mt.openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const mysql = &storage.engine.mysql;
    defer if (mysql.inTransaction()) mysql.control(.rollback) catch unreachable;
    try mysql.control(.begin);
    _ = try mt.liveWrite(&storage, mt.live_insert, .{ .id = 9000001, .digest = protocol.contentDigest("before-savepoint") });
    try mysql.control(.savepoint);
    _ = try mt.liveWrite(&storage, mt.live_insert, .{ .id = 9000002, .digest = protocol.contentDigest("before-replaced-savepoint") });
    try mysql.control(.savepoint);
    _ = try mt.liveWrite(&storage, mt.live_insert, .{ .id = 9000003, .digest = protocol.contentDigest("after-replaced-savepoint") });
    try mysql.control(.rollback_to);
    try mysql.control(.release);
    try mysql.control(.commit);
    try std.testing.expectEqual(@as(u64, 2), try mt.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id IN (9000001,9000002)", .{}));
    try std.testing.expectEqual(@as(u64, 0), try mt.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=9000003", .{}));
    // Replacing, told from nesting: the second SAVEPOINT replaced the first, so one RELEASE of the name leaves nothing for
    // ROLLBACK TO to reach. The release goes to the server as raw SQL, because the engine's own release is a no-op here.
    try mysql.control(.begin);
    _ = try mt.liveWrite(&storage, mt.live_insert, .{ .id = 9000004, .digest = protocol.contentDigest("nesting-probe-first") });
    try mysql.control(.savepoint);
    _ = try mt.liveWrite(&storage, mt.live_insert, .{ .id = 9000005, .digest = protocol.contentDigest("nesting-probe-second") });
    try mysql.control(.savepoint);
    _ = try mt.liveWrite(&storage, mt.live_insert, .{ .id = 9000006, .digest = protocol.contentDigest("nesting-probe-third") });
    try mt.storeRawExec(&storage, "RELEASE SAVEPOINT rui_write");
    try std.testing.expectError(error.MysqlFixtureFailed, mt.storeRawExec(&storage, "ROLLBACK TO SAVEPOINT rui_write"));
    try mysql.control(.rollback);
    try std.testing.expectEqual(@as(u64, 0), try mt.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id IN (9000004,9000005,9000006)", .{}));
    try std.testing.expectEqual(@as(u64, 1), try mt.liveWrite(&storage, mt.live_noop, .{}));
    try std.testing.expect(!storage.isFenced());
}

// SH-5 on SQLite: a savepoint reused inside one transaction nests, so the first survives a release of the second, as the
// MySQL leg's replacing probe shows the other way round.
fn sh5_store_sqlite_reused_savepoint_nests_its(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    defer if (storage.engine.inTransaction()) storage.engine.control(.rollback) catch unreachable;
    const insert = "INSERT INTO content(content_id,digest,byte_length,payload,private) VALUES(?1,?2,0,zeroblob(0),0)";
    const before = protocol.contentDigest("before-savepoint");
    const replaced = protocol.contentDigest("before-replaced-savepoint");
    const after = protocol.contentDigest("after-replaced-savepoint");
    try storage.engine.control(.begin);
    try store_testing.sqliteExec(storage.sqliteDatabase(), insert, .{ @as(u64, 9000001), store_testing.Blob{ .bytes = &before } });
    try storage.engine.control(.savepoint);
    try store_testing.sqliteExec(storage.sqliteDatabase(), insert, .{ @as(u64, 9000002), store_testing.Blob{ .bytes = &replaced } });
    try storage.engine.control(.savepoint);
    try store_testing.sqliteExec(storage.sqliteDatabase(), insert, .{ @as(u64, 9000003), store_testing.Blob{ .bytes = &after } });
    try storage.engine.control(.rollback_to);
    try storage.engine.control(.release);
    try storage.engine.control(.commit);
    try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id IN (9000001,9000002)", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=9000003", .{}));
    // Nesting, told from replacing: one RELEASE of the name takes only the inner savepoint, so ROLLBACK TO still reaches the
    // outer one. Raw SQL, as on MySQL, so the probe does not depend on the control layer's own bookkeeping.
    try storage.engine.control(.begin);
    try store_testing.sqliteExec(storage.sqliteDatabase(), insert, .{ @as(u64, 9000004), store_testing.Blob{ .bytes = &protocol.contentDigest("nesting-probe-first") } });
    try storage.engine.control(.savepoint);
    try store_testing.sqliteExec(storage.sqliteDatabase(), insert, .{ @as(u64, 9000005), store_testing.Blob{ .bytes = &protocol.contentDigest("nesting-probe-second") } });
    try storage.engine.control(.savepoint);
    try store_testing.sqliteExec(storage.sqliteDatabase(), insert, .{ @as(u64, 9000006), store_testing.Blob{ .bytes = &protocol.contentDigest("nesting-probe-third") } });
    try store_testing.sqliteExec(storage.sqliteDatabase(), "RELEASE write", .{});
    try store_testing.sqliteExec(storage.sqliteDatabase(), "ROLLBACK TO write", .{});
    try storage.engine.control(.rollback);
    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id IN (9000004,9000005,9000006)", .{}));
    try std.testing.expect(!storage.isFenced());
}

// Moved from src/store/pin_tests.zig: "Session pin concurrent commands derive distinct ranks from serialized command sequence"
fn sh5_session_pin_concurrent_commands_derive_distinct_ranks(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: pt.Store = undefined;
    try testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var gate: std.Io.Event = .unset;
    var workers: [4]Worker = undefined;
    for (&workers, 0..) |*worker, index| {
        var key: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&key, "pin-concurrent-{d}", .{index});
        const session = try testing.configureTestSession(&storage, name);
        worker.* = .{ .storage = &storage, .gate = &gate, .input = try pt.command(name, session.slice(), true) };
        try worker.input.key.set(try std.fmt.bufPrint(&key, "pin-concurrent-write-{d}", .{index}));
    }
    var threads: [workers.len]std.Thread = undefined;
    var started: usize = 0;
    defer {
        gate.set(std.testing.io);
        for (threads[0..started]) |thread| thread.join();
    }
    for (&threads, &workers) |*thread, *worker| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
        started += 1;
    }
    gate.set(std.testing.io);
    for (threads[0..started]) |thread| thread.join();
    started = 0;
    var ranks: [workers.len]u64 = undefined;
    for (&workers, &ranks) |*worker, *rank| {
        try pt.expectAccepted(worker.reply, true, false);
        rank.* = (try pt.order(&storage, &tmp, worker.input.session.slice())).?;
        const sequence = try testing.queryU64(&storage, "SELECT command_seq FROM core_command WHERE command_key=?1", .{worker.input.key.slice()});
        try std.testing.expectEqual(sequence, rank.*);
    }
    std.mem.sort(u64, &ranks, {}, std.sort.asc(u64));
    for (ranks[1..], ranks[0 .. ranks.len - 1]) |rank, previous| try std.testing.expect(rank > previous);
}

// Moved from src/store/tests/model_facts.zig: "model fact effort masks are format-defined on every engine"
fn sh104_model_fact_effort_masks_are_format_defined(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const cases = .{ .{ .none, 1 }, .{ .low, 2 }, .{ .medium, 4 }, .{ .high, 8 }, .{ .xhigh, 16 }, .{ .max, 32 } };
    inline for (cases) |effort| {
        try storage.saveModelFacts(&.{.{ .id = "effort", .context_window = null, .efforts = .initOne(effort[0]), .openai_listed = false }}, null);
        try std.testing.expectEqual(@as(u8, effort[1]), (try storage.modelFact("effort")).?.efforts);
    }
    const insert = "INSERT INTO model_fact(model_id,context_window,efforts,openai_listed,generation) VALUES(?1,NULL,?2,0,1)";
    const constraint_error = if (case.engine == .mysql) error.MysqlFixtureFailed else error.StatementFailed;
    try std.testing.expectError(constraint_error, store_testing.exec(&storage, insert, .{ "below", @as(i64, -1) }));
    try std.testing.expectError(constraint_error, store_testing.exec(&storage, insert, .{ "above", @as(i64, 64) }));
    try store_testing.exec(&storage, insert, .{ "empty", @as(i64, 0) });
    try store_testing.exec(&storage, insert, .{ "full", @as(i64, 63) });
}

// Moved from src/store/mysql_session_tests.zig: "every Args type round-trips through a literal into its Row type, extremes included"
fn sh104_every_args_type_round_trips_through_a() !void {
    const allocator = std.testing.allocator;
    const connection = try allocator.create(Connection);
    defer allocator.destroy(connection);
    _ = try ms.open(connection) orelse return error.SkipZigTest;
    defer connection.close();
    const text = try allocator.create(Bounded(ms.long_text));
    defer allocator.destroy(text);
    const bytes = try allocator.create(rsql.Blob(ms.long_bytes));
    defer allocator.destroy(bytes);

    var all_bytes: [256]u8 = undefined;
    for (&all_bytes, 0..) |*byte, i| byte.* = @intCast(i);
    var label: Bounded(64) = .{ .len = 0 };
    try label.set("a'b\\c\x00é€😀");
    var digest: [32]u8 = undefined;
    for (&digest, 0..) |*byte, i| byte.* = @intCast(255 - i);
    const small: ms.Present = .{
        .id = .of(1),
        .text = "it's \\ \x00 é € 😀",
        .bytes = .{ .bytes = &all_bytes },
        .count = std.math.maxInt(i64),
        .flag = true,
        .tag = .closed_for_good,
        .digest = digest,
        .head = .{ .ref = "abc123".*, .workspace_key = .of(1), .next_position = .of(1) },
        .workspace_key = .of(std.math.maxInt(i64)),
        .next_position = .of(1),
        .served = "codex",
        .label = label,
    };
    try ms.roundTrip(connection, &small, text, bytes);

    var empty = small;
    empty.id = .of(std.math.maxInt(i64));
    empty.text = "";
    empty.bytes = .{ .bytes = "" };
    empty.count = 0;
    empty.flag = false;
    empty.tag = .open;
    empty.served = "openai";
    empty.label = .{ .len = 0 };
    try ms.roundTrip(connection, &empty, text, bytes);

    const long_value = try allocator.alloc(u8, ms.long_text);
    defer allocator.free(long_value);
    for (long_value, 0..) |*byte, i| byte.* = "é€"[i % 5];
    const long_blob = try allocator.alloc(u8, ms.long_bytes);
    defer allocator.free(long_blob);
    for (long_blob, 0..) |*byte, i| byte.* = @truncate(i *% 31);
    var long = small;
    long.id = .of(2);
    long.text = long_value;
    long.bytes = .{ .bytes = long_blob };
    try ms.roundTrip(connection, &long, text, bytes);
    try std.testing.expect(connection.queries >= 6);
}

// Moved from src/store/mysql_session_tests.zig: "optional Args round-trip as NULL and as values into optional Row fields"
fn sh104_optional_args_round_trip_as_null_and() !void {
    const allocator = std.testing.allocator;
    const connection = try allocator.create(Connection);
    defer allocator.destroy(connection);
    _ = try ms.open(connection) orelse return error.SkipZigTest;
    defer connection.close();

    const nulls: ms.Absent = .{ .id = .of(10), .text = null, .bytes = null, .count = null, .flag = null, .tag = null, .digest = null, .ref = null, .workspace_key = null, .next_position = null, .label = null };
    try ms.send(connection, ms.insert_optional, ms.Absent, &nulls, 0);
    try std.testing.expectEqual(1, try ms.okUntilReady(connection));
    try ms.send(connection, ms.select_optional, ms.Key, &.{ .id = .of(10) }, 0);
    var row: ms.AbsentRow = undefined;
    try ms.readOne(ms.AbsentRow, connection, &row);
    inline for (@typeInfo(ms.AbsentRow).@"struct".field_names) |name| try std.testing.expect(@field(row, name) == null);

    var text: Bounded(64) = .{ .len = 0 };
    try text.set("x");
    const values: ms.Absent = .{
        .id = .of(11),
        .text = text,
        .bytes = .{ .bytes = "\x00\x01" },
        .count = std.math.maxInt(u32),
        .flag = false,
        .tag = .open,
        .digest = @splat(0),
        .ref = .{ .ref = "zz9999".*, .workspace_key = .of(3), .next_position = .of(4) },
        .workspace_key = .of(3),
        .next_position = .of(4),
        .label = "",
    };
    try ms.send(connection, ms.insert_optional, ms.Absent, &values, 0);
    try std.testing.expectEqual(1, try ms.okUntilReady(connection));
    try ms.send(connection, ms.select_optional, ms.Key, &.{ .id = .of(11) }, 0);
    try ms.readOne(ms.AbsentRow, connection, &row);
    try std.testing.expectEqualStrings("x", row.text.?.slice());
    try std.testing.expectEqualSlices(u8, "\x00\x01", row.bytes.?.slice());
    try std.testing.expectEqual(std.math.maxInt(u32), row.count.?);
    try std.testing.expectEqual(false, row.flag.?);
    try std.testing.expectEqual(ms.Tag.open, row.tag.?);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &row.digest.?);
    try std.testing.expectEqualStrings("zz9999", row.ref.?.slice());
    try std.testing.expectEqual(3, row.workspace_key.?.get());
    try std.testing.expectEqual(4, row.next_position.?.get());
    try std.testing.expectEqualStrings("", row.label.?.slice());
    try std.testing.expectEqual(null, row.at);
}

// Moved from src/store/mysql_session_tests.zig: "text literals compare binary and without padding, and text that is not UTF-8 is refused"
fn sh104_text_literals_compare_binary_and_without_padding() !void {
    const allocator = std.testing.allocator;
    const connection = try allocator.create(Connection);
    defer allocator.destroy(connection);
    _ = try ms.open(connection) orelse return error.SkipZigTest;
    defer connection.close();

    const same = comptime ms.rendered("SELECT @same(?1,?2),@distinct(?1,?2)");
    const Pair = struct { a: []const u8, b: []const u8 };
    const Same = struct { same: bool, distinct: bool };
    const cases = [_]struct { Pair, bool }{
        .{ .{ .a = "a", .b = "a" }, true },
        .{ .{ .a = "a", .b = "A" }, false },
        .{ .{ .a = "a", .b = "a " }, false },
        .{ .{ .a = "é", .b = "e" }, false },
        .{ .{ .a = "", .b = "" }, true },
    };
    for (cases) |case| {
        try ms.send(connection, same, Pair, &case[0], 0);
        var row: Same = undefined;
        try ms.readOne(Same, connection, &row);
        try std.testing.expectEqual(case[1], row.same);
        try std.testing.expectEqual(!case[1], row.distinct);
    }

    const insert = comptime ms.rendered("INSERT INTO value_check(id,text_value) VALUES(?1,?2)");
    const Text = struct { id: rsql.Positive, text: []const u8 };
    const w = connection.batch();
    const bad: Text = .{ .id = .of(20), .text = "\xff" };
    const good: Text = .{ .id = .of(21), .text = "ok" };
    try std.testing.expect(try literal.length(insert, Text, &bad, ms.bound(0)) + 1 + try literal.length(insert, Text, &good, ms.bound(0)) <= connection.batchRoom());
    try literal.write(insert, Text, &bad, ms.bound(0), w);
    try w.writeByte(';');
    try literal.write(insert, Text, &good, ms.bound(0), w);
    try connection.sendBatch();
    const refused = try connection.next();
    try std.testing.expect(refused == .err);
    try std.testing.expectEqual(1300, refused.err.code);
    try std.testing.expect(connection.isReady());
    try connection.query("SELECT count(*) FROM value_check WHERE id IN (20,21)");
    const Count = struct { count: u64 };
    var count: Count = undefined;
    try ms.readOne(Count, connection, &count);
    try std.testing.expectEqual(0, count.count);
}

// Moved from src/store/tests/access.zig: "a queued read's destination holds poison until the pass that steps it"
fn sh105_a_queued_read_s_destination_holds_poison(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "poison");
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    var a: store_access.Access(.read, error{}) = .open(&entry);
    defer a.deinit();
    const poisoned = struct {
        fn all(bytes: []const u8) bool {
            for (bytes) |byte| if (byte != store_access.poison_byte) return false;
            return true;
        }
    }.all;
    var first: TestingRound.head.Result = undefined;
    var second: TestingRound.head.Result = undefined;
    @memset(std.mem.asBytes(&first), 0);
    @memset(std.mem.asBytes(&second), 0);
    a.read(TestingRound.head, .{ .session_ref = session.slice() }, &first);
    try std.testing.expect(poisoned(std.mem.asBytes(&first)));
    var fillers: [a.queue.len - 1]TestingRound.head.Result = undefined;
    for (&fillers) |*filler| a.read(TestingRound.head, .{ .session_ref = session.slice() }, filler);
    a.read(TestingRound.head, .{ .session_ref = session.slice() }, &second);
    try std.testing.expect(!poisoned(std.mem.asBytes(&first)));
    try std.testing.expectEqualSlices(u8, session.slice(), &first.head.ref);
    try std.testing.expect(poisoned(std.mem.asBytes(&second)));
    try a.run();
    try std.testing.expectEqualSlices(u8, session.slice(), &second.head.ref);
}

// Moved from src/store/tests/access.zig: "a queued readInto's Found is pending until the pass that steps it"
fn sh105_a_queued_readinto_s_found_is_pending(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "found-pending");
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    var a: store_access.Access(.read, error{}) = .open(&entry);
    defer a.deinit();
    var current: configuration_domain.CurrentConfiguration = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } };
    var missing_current: configuration_domain.CurrentConfiguration = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } };
    var found: store_access.Found = .missing;
    var missing: store_access.Found = .found;
    configuration_domain.readSaved(&a, session.slice(), &current, &found);
    try std.testing.expectEqual(store_access.Found.pending, found);
    var fillers: [a.queue.len - 1]TestingRound.head.Result = undefined;
    for (&fillers) |*filler| a.read(TestingRound.head, .{ .session_ref = session.slice() }, filler);
    configuration_domain.readSaved(&a, "AAAAAA", &missing_current, &missing);
    try std.testing.expectEqual(store_access.Found.found, found);
    try std.testing.expectEqual(store_access.Found.pending, missing);
    try a.run();
    try std.testing.expect(found.get());
    try std.testing.expect(!missing.get());
}

// Moved from src/store/tests/access.zig: "a counted write commits only when it changes the rows its caller states"
fn sh105_a_counted_write_commits_only_when_it(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "counted-config");
    const dated = "SELECT created_at FROM session";
    const created = try store_testing.queryU64(&storage, dated, .{});
    for ([_]u64{ 0, 2 }) |rows| {
        try std.testing.expectError(error.TestingGuard, countedDatingForTesting(&storage, session.slice(), 7, 1, rows));
        try std.testing.expectEqual(created, try store_testing.queryU64(&storage, dated, .{}));
    }
    try std.testing.expect(!storage.isFenced());
    try countedDatingForTesting(&storage, session.slice(), 7, 1, 1);
    try std.testing.expectEqual(@as(u64, 7), try store_testing.queryU64(&storage, dated, .{}));
    try std.testing.expectError(error.TestingGuard, countedDatingForTesting(&storage, session.slice(), 8, 2, 1));
    try countedDatingForTesting(&storage, session.slice(), 8, 2, 0);
    try std.testing.expectEqual(@as(u64, 7), try store_testing.queryU64(&storage, dated, .{}));
}

// Moved from src/store/tests/access.zig: "an .each visitor supplies storage for a big Row through decoded"
fn sh105_an_each_visitor_supplies_storage_for_a() !void {
    const Big = struct { bytes: [1025]u8 };
    const Small = struct { id: u64 };
    try std.testing.expectEqual(@as(?[]const u8, null), comptime store_access.eachVisitorError(Small, struct { count: u8 }));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime store_access.eachVisitorError(Big, struct { decoded: Big }));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime store_access.eachVisitorError(Big, struct { decoded: *Big }));
    try std.testing.expectEqualStrings("rsql: an .each Row over 1 KiB decodes into its visitor's own decoded field", comptime store_access.eachVisitorError(Big, struct { count: u8 }).?);
    try std.testing.expectEqualStrings("rsql: a visitor's decoded field is the Row or *Row its .each read decodes, " ++ @typeName(Small), comptime store_access.eachVisitorError(Small, struct { decoded: Big }).?);
}

// Moved from src/store/tests/transition.zig: "a transition's round names the failed step of each statement it names, and the round's name answers for the rest"
fn sh105_a_transition_s_round_names_the_failed(case: *store_testing.Case) !void {
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

// Moved from src/store/mysql_testing.zig: "store.mysql live CLIENT_FOUND_ROWS counts an unchanged matched UPDATE"
fn sh105_store_mysql_live_client_found_rows_counts() !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: mt.Store = undefined;
    try mt.openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const before = try mt.queryU64(&storage, "SELECT epoch FROM store_owner WHERE owner_key=1", .{});
    try std.testing.expectEqual(@as(u64, 1), try mt.liveWrite(&storage, mt.live_noop, .{}));
    try std.testing.expectEqual(before, try mt.queryU64(&storage, "SELECT epoch FROM store_owner WHERE owner_key=1", .{}));
    try std.testing.expect(!storage.isFenced());
}

// Moved from src/store/mysql_testing.zig: "store.mysql live first Access guard survives a later duplicate and keeps failedOn identity"
fn sh105_store_mysql_live_first_access_guard_survives() !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: mt.Store = undefined;
    try mt.openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const duplicate: mt.live_insert.Args = .{ .id = 9000010, .digest = protocol.contentDigest("duplicate-after-guard") };
    _ = try mt.liveWrite(&storage, mt.live_insert, duplicate);
    const Guarded = struct {
        pub const Guards = error{LiveGuard};
        storage: *mt.Store,
        duplicate: mt.live_insert.Args,
        queries: u64 = 0,
        sent: ?u64 = null,

        pub fn step(b: *@This(), r: anytype, ran: u32) !TestingAsk {
            if (ran != 0) return .done;
            b.queries = b.storage.engine.mysql.state.connection.queries;
            r.write(mt.live_guard, .{});
            r.write(mt.live_insert, b.duplicate);
            return .round;
        }

        pub fn failed(b: *@This()) void {
            b.sent = b.storage.engine.mysql.state.connection.queries - b.queries;
        }
    };
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var guarded: Guarded = .{ .storage = &storage, .duplicate = duplicate };
        try std.testing.expectError(error.LiveGuard, TestingScript(Guarded).run(&entry, &guarded));
        try std.testing.expectEqual(@as(?u64, 1), guarded.sent);
    }
    try std.testing.expect(!storage.engine.inTransaction());
    try std.testing.expect(storage.engine.mysql.state.connection.isReady());
    try std.testing.expectEqual(@as(u64, 1), try mt.liveWrite(&storage, mt.live_noop, .{}));
    try std.testing.expect(!storage.isFenced());
}

// Moved from src/store/tests/transition.zig: "a transition with a wide pass steps twenty statements a pass, an ordinary one twelve"
fn sh106_a_transition_with_a_wide_pass_steps(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var passes: [2]u64 = undefined;
    inline for (.{ transition.Pass.wide, transition.Pass.ordinary }, &passes) |width, *taken| {
        const before = RoundMeter.QueryShape.snapshot(&storage);
        const rounds = storage.testing_content_work.rounds;
        try transition.apply(&storage, TestingPassWidth(width), .{}, .{});
        taken.* = RoundMeter.QueryShape.snapshot(&storage).since(before).access_passes;
        if (!case.rerun) try std.testing.expectEqual(rounds + 1, storage.testing_content_work.rounds);
    }
    try std.testing.expect(!storage.isFenced());
    if (case.engine != .mysql or case.rerun) return;
    try std.testing.expectEqual([2]u64{ 1, 2 }, passes);
}

// Moved from src/store/tests/transition.zig: "a step sees its transaction open once it queues from begin on, and never before begin"
fn sh106_a_step_sees_its_transaction_open_once(case: *store_testing.Case) !void {
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

// Moved from src/store/tests/transition.zig: "a transition's paged round runs again for each page"
fn sh106_a_transition_s_paged_round_runs_again(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    for ([_][]const u8{ "pages-a", "pages-b", "pages-c" }) |key| _ = try configureTestSession(&storage, key);
    const sessions = try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{});
    const rounds = storage.testing_content_work.rounds;
    try std.testing.expectEqual(sessions, try transition.apply(&storage, TestingSessionPages, .{}, .{}));
    try std.testing.expectEqual(rounds + sessions + 1, storage.testing_content_work.rounds);
}

// Moved from src/store/tests/transition.zig: "a transition's follow reads ride its commit's message where that message carries reads, and cost no round"
fn sh106_a_transition_s_follow_reads_ride_its(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "transition-follow");
    for ([_]bool{ false, true }) |follows| {
        const rounds = storage.testing_content_work.rounds;
        const seen = try storage.queue().write(TestingFollow.held, .{ &storage, session.slice(), follows });
        if (case.rerun) continue;
        try std.testing.expectEqual(rounds + 2, storage.testing_content_work.rounds);
        if (follows and case.engine == .mysql) {
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT created_at FROM session", .{}), seen.?);
        } else try std.testing.expectEqual(@as(?u64, null), seen);
    }
    try std.testing.expect(!storage.isFenced());
}

// Moved from src/store/tests/transition.zig: "a transition's rounds before begin read outside its transaction and the rest inside"
fn sh106_a_transition_s_rounds_before_begin_read(case: *store_testing.Case) !void {
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

// Moved from src/store/tests/model_settlement.zig: "a success settlement sends its rows twenty statements a pass"
fn sh106_a_success_settlement_sends_its_rows_twenty(case: *store_testing.Case) !void {
    if (case.engine != .mysql or case.rerun) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "settlement-pass-config");
    try submitTestMessage(&storage, &tmp, "settlement-pass-input", "settlement-pass-key", session.slice(), "passes");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const rounds = storage.testing_content_work.rounds;
    const before = RoundMeter.QueryShape.snapshot(&storage);
    try settleMessagesForTesting(&storage, &tmp, binding, 16, false, null);
    const shape = RoundMeter.QueryShape.snapshot(&storage).since(before);
    try std.testing.expectEqual(@as(u16, 2), storage.testing_content_work.rounds - rounds);
    try std.testing.expectEqual(@as(u64, 7), shape.access_passes);
    try std.testing.expectEqual(shape.expected(), shape.queries);
    try std.testing.expect(!storage.isFenced());
}

// Moved from src/store/tests/access.zig: "buffered payload boundaries and streamed payloads preserve the same bytes under queue pressure"
fn sh107_buffered_payload_boundaries_and_streamed_payloads_preserve(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const insert = rsql.Write(.{
        .sql = "INSERT INTO content(content_id,digest,byte_length,payload,private) VALUES(?1,?2,?3,zeroblob(?3),?4)",
        .Args = struct { id: u64, digest: [32]u8, length: u64, private: bool },
        .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
    });
    const chunk = store_schema.content_chunk_bytes;
    const source = try std.testing.allocator.alloc(u8, 9 * chunk + 17);
    defer std.testing.allocator.free(source);
    for (source, 0..) |*byte, i| byte.* = @truncate(i *% 31 + i / chunk);
    const window_bytes = 4093;
    var window: [window_bytes]u8 = undefined;
    const Import = struct {
        pub const Guards = error{};
        bytes: []const u8,
        ids: [2]u64 = undefined,

        pub fn step(b: *@This(), r: anytype, _: u32) !TestingAsk {
            const length = b.bytes.len;
            for (&b.ids, 0..) |*id, method| {
                id.* = try r.identity(.content_id);
                r.write(insert, .{ .id = id.*, .digest = protocol.contentDigest("adapter parity fixture"), .length = length, .private = method == 1 });
                if (method == 0) {
                    r.writeContent(id.*, b.bytes);
                } else {
                    r.recordContentRow(id.*);
                    const sink = try r.contentSink(id.*, length);
                    defer sink.close();
                    var at: usize = 0;
                    while (at < length) {
                        const n = @min(window_bytes, length - at);
                        try sink.write(b.bytes[at..][0..n], at);
                        at += n;
                    }
                }
            }
            return .commit;
        }
    };
    for ([_]usize{ 0, 1, chunk - 1, chunk, chunk + 1, 3 * chunk + 17, source.len }) |length| {
        const bytes = source[0..length];
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var import: Import = .{ .bytes = bytes };
        try TestingScript(Import).run(&entry, &import);
        const ids = import.ids;
        var a: reads_domain.ReadAccess = .open(&entry);
        defer a.deinit();
        for (ids) |id| {
            var offset: usize = 0;
            while (offset < length) {
                const n = @min(window.len, length - offset);
                try a.readRaw(id, offset, window[0..n]);
                try std.testing.expectEqualSlices(u8, bytes[offset..][0..n], window[0..n]);
                offset += n;
            }
            try std.testing.expectEqual(length, try store_testing.queryU64(&storage, "SELECT byte_length FROM content WHERE content_id=?1", .{id}));
        }
        try std.testing.expect(!storage.engine.inTransaction());
        try std.testing.expect(!storage.isFenced());
    }
}

// Moved from src/store/tests/access.zig: "a content sink opens only on a content row its Access itself queued, in the same round"
fn sh107_a_content_sink_opens_only_on_a(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "sink-config");
    const existing: u64 = @intCast((try store_core.readSessionForTesting(&storage, session.slice())).?.instructions_id.?);

    const Sinks = struct {
        pub const Guards = error{};
        storage: *Store,
        existing: u64,
        last: u64 = 0,
        never: u64 = 0,

        pub fn step(b: *@This(), r: anytype, ran: u32) !TestingAsk {
            if (ran != 0) {
                const again = try r.contentSink(b.last, 4);
                again.close();
                try std.testing.expectError(error.ContentWriteFailed, r.contentSink(b.never, 4));
                return .done;
            }
            _ = try r.identity(.turn_id);
            const before = try store_core.takeIdentity(b.storage, .content_id);
            const digests = [3][32]u8{ protocol.contentDigest("sink0"), protocol.contentDigest("sink1"), protocol.contentDigest("sink2") };
            r.write(TestingRound.insert_content, .{ .content_id = before, .digest = digests[0], .length = 4 });
            const first = try r.identity(.content_id);
            r.write(TestingRound.insert_content, .{ .content_id = first, .digest = digests[1], .length = 4 });
            r.recordContentRow(first);
            const between = try store_core.takeIdentity(b.storage, .content_id);
            b.never = try r.identity(.content_id);
            b.last = try r.identity(.content_id);
            r.write(TestingRound.insert_content, .{ .content_id = b.last, .digest = digests[2], .length = 4 });
            r.recordContentRow(b.last);
            try std.testing.expectEqual(first + 3, b.last);
            try std.testing.expectError(error.ContentNotInserted, r.contentSink(0, 4));
            try std.testing.expectError(error.ContentNotInserted, r.contentSink(b.existing, 4));
            try std.testing.expectError(error.ContentNotInserted, r.contentSink(before, 4));
            try std.testing.expectError(error.ContentNotInserted, r.contentSink(between, 4));
            try std.testing.expectError(error.ContentNotInserted, r.contentSink(b.last + 1, 4));
            const sink = try r.contentSink(first, 4);
            try sink.write("sink", 0);
            sink.close();
            return .round;
        }
    };
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    var sinks: Sinks = .{ .storage = &storage, .existing = existing };
    try TestingScript(Sinks).run(&entry, &sinks);
}

// Moved from src/store/tests/content.zig: "multiwindow content import and deduplication preserve all bytes"
fn sh107_multiwindow_content_import_and_deduplication_preserve_all(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("first", "", workspace, "model-a");
    const length = protocol.content_window_bytes * 2 + 17;
    command.configuration.instructions = try testingContent(&tmp, "source", 'q', length);
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;
    const created_session_0_reply = try storage.configure(&command, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    try command.key.set("second");
    command.session = created_session_0;
    try std.testing.expect(try storage.configure(&command, .{}) == .accepted);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, store_testing.content_beside_tools, .{}));
    const observation = try storage.inspectSessionForTesting(created_session_0.slice());
    try std.testing.expectEqual(@as(u64, 2), observation.revision);
    var reader: ContentReader = undefined;
    reader.open(try storage.openContent(observation.instructions));
    defer reader.close();
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var offset: usize = 0;
    while (offset < length) {
        const count = try reader.read(offset, buffer[0..@min(buffer.len, length - offset)]);
        try std.testing.expect(count != 0);
        for (buffer[0..count]) |byte| try std.testing.expectEqual(@as(u8, 'q'), byte);
        offset += count;
    }
    try std.testing.expectEqual(length, offset);
}

// Moved from src/store/tests/content.zig: "large raw content opens without materializing its payload"
fn sh107_large_raw_content_opens_without_materializing_its(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("large", "", workspace, "model-a");
    const length = 32 * 1024 * 1024 + 10;
    command.configuration.instructions = try testingContent(&tmp, "large-source", 'q', length);
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;
    const reference = ContentReference{
        .length = command.configuration.instructions.length,
        .digest = command.configuration.instructions.digest,
    };
    const created_session_0_reply = try storage.configure(&command, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    var reader: ContentReader = undefined;
    reader.open(try storage.openContent(reference));
    defer reader.close();
    var first: [17]u8 = undefined;
    try std.testing.expectEqual(first.len, try reader.read(0, &first));
    for (first) |byte| try std.testing.expectEqual(@as(u8, 'q'), byte);
    var last: [17]u8 = undefined;
    try std.testing.expectEqual(last.len, try reader.read(length - last.len, &last));
    for (last) |byte| try std.testing.expectEqual(@as(u8, 'q'), byte);
}

// Moved from src/store/tests/access.zig: "every round of a write Access dates its rows with the transaction's second"
fn sh108_every_round_of_a_write_access_dates(case: *store_testing.Case) !void {
    const Clock = struct {
        var ahead: std.Io.Duration = .zero;
        var vtable: std.Io.VTable = undefined;
        fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            const real = std.testing.io.vtable.now(userdata, clock);
            return if (clock == .real) real.addDuration(ahead) else real;
        }
    };
    Clock.ahead = .zero;
    Clock.vtable = std.testing.io.vtable.*;
    Clock.vtable.now = Clock.now;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &Clock.vtable };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, io);
    defer storage.close() catch unreachable;
    const first = try configureTestSession(&storage, "second-first");
    const second = try configureTestSession(&storage, "second-second");
    const Dating = struct {
        pub const Guards = error{TestingGuard};
        storage: *Store,
        io: std.Io,
        sessions: [2][]const u8,
        heads: [2]TestingRound.head.Result = undefined,
        dated: i64 = 0,

        pub fn step(b: *@This(), r: anytype, ran: u32) !TestingAsk {
            switch (ran) {
                0 => {
                    for (b.sessions, &b.heads) |session, *head| r.read(TestingRound.head, .{ .session_ref = session }, head);
                    return .round;
                },
                1 => {
                    r.write(TestingRound.date_session, .{ .session = b.heads[0].head, .revision = 1 });
                    return .round;
                },
                else => {
                    b.dated = try store_core.transactionSecond(b.storage);
                    Clock.ahead = .fromSeconds(1);
                    try std.testing.expect(@divFloor(try store_core.readUnixMilliseconds(b.io), 1000) > b.dated);
                    r.write(TestingRound.date_session, .{ .session = b.heads[1].head, .revision = 1 });
                    return .commit;
                },
            }
        }
    };
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    var dating: Dating = .{ .storage = &storage, .io = io, .sessions = .{ first.slice(), second.slice() } };
    try TestingScript(Dating).run(&entry, &dating);
    const dated = dating.dated;
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(DISTINCT created_at) FROM session", .{}));
    try std.testing.expectEqual(@as(u64, @intCast(dated)), try store_testing.queryU64(&storage, "SELECT max(created_at) FROM session", .{}));
    try store_core.begin(&storage);
    try std.testing.expect(try store_core.transactionSecond(&storage) > dated);
    try store_core.rollbackAfterError(&storage, .{});
}

// Moved from src/store/tests/access.zig: "canonical step faults fence rather than reading as ordinary misses"
fn sh3_canonical_step_faults_fence_rather_than_reading(case: *store_testing.Case) !void {
    const Route = enum { result, view, purpose, handoff, failure, success };
    for (std.enums.values(Route)) |route| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "step-fault-config");
        try submitTestMessage(&storage, &tmp, "step-fault-input", "step-fault-message", session.slice(), "work");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const result: anyerror!void = switch (route) {
            .result => blk: {
                try store_testing.failReadsOf(&storage, "core_command");
                break :blk if (storage.commandResult("step-fault-message")) |_| {} else |err| err;
            },
            .success => blk: {
                try store_testing.failReadsOf(&storage, "session_revision");
                break :blk settleCallsForTesting(&storage, &tmp, binding, "step-fault-success", &.{});
            },
            .view, .purpose, .handoff, .failure => blk: {
                try store_testing.failReadsOf(&storage, "model_operation");
                var view: TestingPage = undefined;
                break :blk switch (route) {
                    .view => openCheckedView(&storage, binding, &view),
                    .purpose => if (storage.modelOperationKind(binding)) |_| {} else |err| err,
                    .handoff => storage.withDispatchHandoff(binding, {}, struct {
                        fn run(_: void) !void {
                            return error.TestUnexpectedResult;
                        }
                    }.run),
                    .failure => storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_failure" }, .ordinary, .{}),
                    .result, .success => unreachable,
                };
            },
        };
        const unprepared = route == .view and storage.engine == .sqlite;
        try std.testing.expectError(if (route == .result) error.ResultReadFailed else if (unprepared) error.StatementPrepareFailed else error.OperationReadFailed, result);
        try std.testing.expect(storage.isFenced());
        // A later entry is refused, so the fence reaches every writer and not only the one that met the fault.
        try std.testing.expectError(error.StoreFenced, storage.commandResult("step-fault-message"));
    }
}

// Negative control for SH-3 (SH-4's ordinary outcomes): an unknown command is a declared refusal that leaves the
// Store serving, so the fence checks above are not satisfied by any refusal.
fn sh3_an_ordinary_outcome_leaves_the_store_serving(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try std.testing.expectError(error.ResultNotFound, storage.commandResult("step-fault-missing"));
    try std.testing.expect(!storage.isFenced());
    _ = try configureTestSession(&storage, "step-fault-control");
    try std.testing.expect(!storage.isFenced());
}

// Moved from src/store/tests/session_list.zig: "a list Action step fault keeps its named error and fences"
fn sh3_a_list_action_step_fault_keeps_its(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "list-actions-config");
    try submitTestMessage(&storage, &tmp, "list-actions-input", "list-actions-message", session.slice(), "call");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const call = [_]TestingCall{.{ .item_id = "list-actions-item", .name = "bash", .encoded_call_id = "list-actions-call", .decoded_call_id = "list-actions-call", .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}" }};
    try settleCallsForTesting(&storage, &tmp, binding, "list-actions-output", &call);
    var fault: store_testing.TestingStatementFault = .{ .sql = shared_fixtures.namedStatementForTesting(report_domain.work_rows_failures, null, "AS actions_total") };
    if (storage.engine == .sqlite) {
        fault.arm(storage.sqliteDatabase());
    } else try store_testing.failReadsOf(&storage, "action_operation");
    defer if (storage.engine == .sqlite) fault.disarm(storage.sqliteDatabase());
    var used = std.atomic.Value(u64).init(0);
    const expected = switch (storage.engine) {
        // The list reads a row's Actions inside its one work statement, whose failure is TurnReadFailed.
        .sqlite => error.TurnReadFailed,
        .mysql => error.SessionReadFailed,
    };
    try std.testing.expectError(expected, testingSessionList(&storage, &tmp, .{}, &used, 5));
    if (storage.engine == .sqlite) try std.testing.expect(fault.failed > 0);
    try std.testing.expect(storage.isFenced());
}

// Moved from src/store/tests/access.zig: "the touch oracle names a sender whose sent Message changed without its touch"
fn sh109_the_touch_oracle_names_a_sender_whose(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const recipient = try configureTestSession(&storage, "oracle-recipient");
    const sender = try configureTestSession(&storage, "oracle-sender");
    try submitTestMessage(&storage, &tmp, "oracle-message-file", "oracle-message", recipient.slice(), "hello");
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        try touchForTesting(&storage, recipient.slice());
        try store_testing.exec(&storage, "UPDATE message_admission SET sender_session_ref=?1,sender_position=1000000,source_kind=2 WHERE command_key='oracle-message'", .{sender.slice()});
        try std.testing.expectEqualStrings(sender.slice(), &store_core.untouchedForTesting(&storage).?);
        try touchForTesting(&storage, sender.slice());
        try std.testing.expect(store_core.untouchedForTesting(&storage) == null);
    }
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        try touchForTesting(&storage, recipient.slice());
        try store_testing.exec(&storage, "UPDATE message_admission SET turn_id=NULL WHERE command_key='oracle-message'", .{});
        try std.testing.expect(store_core.untouchedForTesting(&storage) == null);
        try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=admitted_at+1 WHERE command_key='oracle-message'", .{});
        try std.testing.expectEqualStrings(sender.slice(), &store_core.untouchedForTesting(&storage).?);
        try touchForTesting(&storage, sender.slice());
        try std.testing.expect(store_core.untouchedForTesting(&storage) == null);
    }
}

// Moved from src/store/tests/access.zig: "an Access that touches a fifth Session records everything and still commits"
fn sh109_an_access_that_touches_a_fifth_session(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var sessions: [5]protocol.Bounded(protocol.max_session_bytes) = undefined;
    inline for (&sessions, .{ "five-a", "five-b", "five-c", "five-d", "five-e" }) |*session, key| session.* = try configureTestSession(&storage, key);

    const Five = struct {
        pub const Guards = error{TestingGuard};
        all: []const protocol.Bounded(protocol.max_session_bytes),
        loaded: TestingRound.head.Result = undefined,

        pub fn step(b: *@This(), r: anytype, ran: u32) !TestingAsk {
            const index = ran / 2;
            if (ran % 2 == 1) {
                r.write(TestingRound.date_session, .{ .session = b.loaded.head, .revision = 1 });
                return .round;
            }
            if (index == b.all.len) return .commit;
            r.read(TestingRound.head, .{ .session_ref = b.all[index].slice() }, &b.loaded);
            return .round;
        }
    };
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var five: Five = .{ .all = &sessions };
        try entry.finishTransaction(error{TestingGuard}, .{}, TestingScript(Five).run(&entry, &five));
    }
    try std.testing.expect(storage.touched.everything);
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(DISTINCT created_at) FROM session", .{}));
}

// Moved from src/store/tests/access.zig: "the touch oracle names a Session whose rows changed without a touch"
fn sh109_the_touch_oracle_names_a_session_whose(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var root: [protocol.max_store_bytes]u8 = undefined;
    var command = try completeConfiguration("oracle", "", root[0..try tmp.dir.realPath(std.testing.io, &root)], "model");
    const configured = try storage.configure(&command, .{});
    const session = configured.accepted.session.slice();
    const generation = storage.commit_generation.load(.acquire);
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        try std.testing.expect(store_core.untouchedForTesting(&storage) == null);
        try store_testing.exec(&storage, "UPDATE session SET label='forgot' WHERE session_ref=?1", .{session});
        try std.testing.expectEqualStrings(session, &store_core.untouchedForTesting(&storage).?);
        try touchForTesting(&storage, session);
        try std.testing.expect(store_core.untouchedForTesting(&storage) == null);
    }
    try std.testing.expectEqual(generation + 1, storage.commit_generation.load(.acquire));
    var out: [1]change_ring.Id = undefined;
    try std.testing.expectEqualStrings(session, &storage.changes.changed(generation, generation + 1, null, null, &out)[0]);
}

// Moved from src/store/tests/access.zig: "an entry point that changed rows sets the commit wake, and a read leaves it unset"
fn sh109_an_entry_point_that_changed_rows_sets(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var wake: std.Io.Event = .unset;
    storage.commitWake().store(&wake, .release);
    defer storage.commitWake().store(null, .release);
    _ = try storage.dispatchWork(false, .{ .free_credit = .one, .mcp_open = true });
    try std.testing.expect(!wake.isSet());
    _ = try configureTestSession(&storage, "wake-config");
    try std.testing.expect(wake.isSet());
}

/// The Entry.release commit site: each commit notifies the commit subscriber exactly once,
/// after it has recorded the commit, so the notices match the generations committed.
fn sh109_each_commit_notifies_the_subscriber_once(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const Counter = struct {
        count: usize = 0,
        fn notify(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };
    var counter: Counter = .{};
    var subscriber: store_core.CommitSubscriber = .{ .context = &counter, .notify = Counter.notify };
    storage.commitSubscriber().store(&subscriber, .release);
    defer storage.commitSubscriber().store(null, .release);
    const generation = storage.commit_generation.load(.acquire);
    _ = try storage.dispatchWork(false, .{ .free_credit = .one, .mcp_open = true });
    try std.testing.expectEqual(@as(usize, 0), counter.count);
    _ = try configureTestSession(&storage, "subscriber-config");
    try std.testing.expect(counter.count >= 1);
    try std.testing.expectEqual(storage.commit_generation.load(.acquire) - generation, counter.count);
}

// Moved from src/store/mysql_testing.zig: "store.mysql touch oracle observes and clears uncommitted entry writes without changing rollback"
fn sh109_store_mysql_touch_oracle_observes_and_clears() !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: mt.Store = undefined;
    try mt.openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const session = try testing.configureTestSession(&storage, "oracle-uncommitted");
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    const Head = @import("tests.zig").TestingRound.head;
    var head: Head.Row = undefined;
    const mysql = &storage.engine.mysql;
    try mysql.bind(Head, &.{ .session_ref = session.slice() }, 0);
    try mysql.startPass();
    try std.testing.expect(try mysql.nextRow());
    try mysql.decodeRow(Head.Row, &head);
    try std.testing.expect(!try mysql.nextRow());
    mysql.endStatement();
    try mysql.finishPass();
    try store_core.begin(&storage);
    defer if (storage.engine.inTransaction()) store_core.rollbackAfterError(&storage, .{}) catch @panic("oracle fixture rollback failed");
    const forgotten_touch = rsql.Write(.{
        .sql = "UPDATE session SET label='oracle uncommitted' WHERE session_ref=@session(?1)",
        .Args = struct { session: rsql.SessionHead },
        .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
    });
    try std.testing.expectEqual(@as(u64, 1), try mt.liveWrite(&storage, forgotten_touch, .{ .session = head.head }));
    try std.testing.expect(storage.engine.mysql.state.begin == .sent);
    const missing = store_core.untouchedForTesting(&storage);
    try std.testing.expectEqual(true, missing != null);
    try std.testing.expectEqualStrings(session.slice(), &missing.?);
    mt.clearTouchOracleForTesting(&storage);
    try std.testing.expect(storage.engine.inTransaction());
    try std.testing.expect(store_core.untouchedForTesting(&storage) == null);
    try store_core.rollbackAfterError(&storage, .{});
    try std.testing.expectEqual(@as(u64, 0), try mt.queryU64(&storage, "SELECT count(*) FROM session WHERE label='oracle uncommitted'", .{}));
}

// Test-only: the SQLite leg's logical-row digests, which each MySQL leg of the journey must reproduce: the plain leg
// compares the first, the rerun leg the second (forward_id masked, as its comment in logicalDigest says).
const SqliteDigests = struct { plain: [32]u8, masked: [32]u8, replies: [32]u8, replies_masked: [32]u8 };
var sh110_sqlite_digest: ?SqliteDigests = null;

// Moved from src/store/tests/round_budget.zig: "each Store entry point takes its round budget on its common path"
fn sh110_each_store_entry_point_takes_its_round(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var meter: RoundMeter = .{ .storage = &storage, .checked = !case.rerun };
    var replies: store_testing.ReplyDigest = .init(std.testing.allocator);
    defer replies.deinit();
    meter.start();
    _ = try replies.keep(storage.publishRetryCrossings(0, 1));
    try meter.stop(.publishRetryCrossings);
    meter.start();
    try storage.saveModelFacts(&.{.{ .id = "catalog-budget", .context_window = null, .efforts = .{}, .openai_listed = true }}, null);
    try meter.stop(.saveModelFacts);
    meter.start();
    _ = try replies.keep(storage.readModelCatalogSource());
    try meter.stop(.readModelCatalogSource);
    var catalog_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer catalog_arena.deinit();
    meter.start();
    _ = try replies.keep(storage.readModelCatalog(catalog_arena.allocator()));
    try meter.stop(.readModelCatalog);
    meter.start();
    _ = try replies.keep(storage.modelFact("catalog-budget"));
    try meter.stop(.modelFact);
    meter.start();
    const model_ids = try replies.keep(storage.readOpenAiModelIds(std.testing.allocator));
    defer {
        for (model_ids) |id| std.testing.allocator.free(id);
        std.testing.allocator.free(model_ids);
    }
    try meter.stop(.readOpenAiModelIds);
    meter.start();
    try storage.saveHostToolSet(&tool_defs.built_in_tool_set);
    try meter.stop(.saveHostToolSet);
    meter.start();
    const saved = (try replies.keep(storage.readHostToolSetSet())).?;
    try meter.stop(.readHostToolSetSet);
    var rows: [tool_defs.built_in_tool_set.records.len]tool_set_domain.host_tool_records.Row = undefined;
    meter.start();
    try std.testing.expectEqual(rows.len, try replies.keep(storage.readHostToolSetRecords(saved.tool_set_id.get(), 0, &rows)));
    try meter.stop(.readHostToolSetRecords);
    var text: [tool_defs.bash_record.description.len]u8 = undefined;
    meter.start();
    try storage.readHostToolSetText(rows[0].description_id.get(), &text);
    try meter.stop(.readHostToolSetText);
    try std.testing.expectEqualStrings(tool_defs.bash_record.description, &text);
    try plainTurn(&storage, &tmp, &meter, &replies);
    try toolTurn(&storage, &tmp, &meter, &replies);
    try compoundTurn(&storage, &tmp, &meter, &replies);
    try compactedTurn(&storage, &tmp, &meter, &replies);
    try coreTurn(&storage, &tmp, &meter, &replies);
    try mcpTurn(case, &meter, &replies);
    try localRunnerTurn(case, &meter, &replies, .read_image);
    try localRunnerTurn(case, &meter, &replies, .github_pr_watch);
    try findTurn(&storage, &tmp, &meter, &replies);
    try skillTurn(case, &meter, &replies);
    stopTurn(case, &meter, &replies) catch |err| {
        std.debug.print("stop budget setup failed: {s}\n", .{@errorName(err)});
        return err;
    };
    // The SQLite leg runs first in forEachEngine, so each MySQL leg compares with the leg of the same test run.
    // The rerun leg masks forward_id (see logicalDigest and ReplyDigest.finish), so the SQLite leg records both ways.
    if (case.engine == .sqlite) {
        sh110_sqlite_digest = .{
            .plain = try store_testing.logicalDigest(&storage, false),
            .masked = try store_testing.logicalDigest(&storage, true),
            .replies = try replies.finish(&storage, false),
            .replies_masked = try replies.finish(&storage, true),
        };
    } else {
        // A MySQL leg with no SQLite digest before it has nothing to compare with: that is a failed run, not a pass.
        const expected = sh110_sqlite_digest orelse return error.SqliteLegDigestMissing;
        const logical = try store_testing.logicalDigest(&storage, case.rerun);
        const want = if (case.rerun) expected.masked else expected.plain;
        if (!std.mem.eql(u8, &want, &logical)) {
            std.debug.print("logical rows differ from the SQLite leg (rerun: {any})\n", .{case.rerun});
            return error.LogicalRowsChanged;
        }
        const reply = try replies.finish(&storage, case.rerun);
        const want_reply = if (case.rerun) expected.replies_masked else expected.replies;
        if (!std.mem.eql(u8, &want_reply, &reply)) {
            std.debug.print("replies differ from the SQLite leg (rerun: {any})\n", .{case.rerun});
            return error.RepliesChanged;
        }
    }
    var failed = false;
    for (std.enums.values(EntryPoint)) |point| {
        const measured = meter.measured.get(point) orelse {
            std.debug.print("{s}: not driven\n", .{@tagName(point)});
            failed = true;
            continue;
        };
        // A run-again leg writes more rounds by design (tests/action.zig:479), so rounds are asserted on the other legs.
        if (!case.rerun and measured.rounds != round_budgets.get(point)) failed = true;
        if (!case.rerun and measured.content_rounds != contentRoundBudget(case.engine, point)) failed = true;
        if (case.engine == .mysql and !case.rerun) {
            std.testing.expectEqual(measured.shape.expected(), measured.shape.queries) catch {
                std.debug.print("{s}: COM_QUERY shape differs\n", .{@tagName(point)});
                failed = true;
            };
        }
        if (!case.rerun and !shared_fixtures.keepsPassBudget(point, measured.shape)) {
            std.debug.print("{s}: Access passes {d}, budget {d}\n", .{ @tagName(point), measured.shape.access_passes, pass_budgets.get(point).? });
            failed = true;
        }
    }
    if (failed) {
        for (std.enums.values(EntryPoint)) |point| {
            const measured = meter.measured.get(point) orelse continue;
            std.debug.print(".{s} = {d} (budget {d}), content {d} (budget {d})\n", .{
                @tagName(point),
                measured.rounds,
                round_budgets.get(point),
                measured.content_rounds,
                contentRoundBudget(case.engine, point),
            });
            if (!case.rerun) if (pass_budgets.get(point)) |budget|
                std.debug.print("  Access passes {d} (budget {d})\n", .{ measured.shape.access_passes, budget });
            if (case.engine == .mysql and !case.rerun) std.debug.print(
                "  COM_QUERY {d} = Access passes {d} + identity passes {d} + content queries {d} + controls {d} + prefix-only passes {d} (expected {d})\n",
                .{
                    measured.shape.queries,
                    measured.shape.access_passes,
                    measured.shape.identity_passes,
                    measured.shape.content_queries,
                    measured.shape.controls,
                    measured.shape.prefix_only,
                    measured.shape.expected(),
                },
            );
        }
        return error.RoundBudgetChanged;
    }
    try std.testing.expect(!storage.isFenced());
}

const Launch = struct {
    fn run(_: void) !void {}
};

fn compoundTurn(storage: *Store, tmp: *std.testing.TmpDir, meter: *RoundMeter, replies: *store_testing.ReplyDigest) !void {
    const session = try replies.keep(configureTestSession(storage, "budget-compound"));
    try store_testing.submitTestMessageParts(storage, tmp, "budget-compound-message", session.slice(), &.{ .{ .bytes = "first" }, .{ .bytes = "second" } });
    const observed = try replies.keep(store_testing.observeCommandForTesting(storage, "budget-compound-message"));
    const owner = observed.kind.message.?.content.parts.owner;
    const PressureRead = @import("domain/model_admission.zig").PartsPressure.Read;
    const pressure_map = try @import("../os/pages.zig").Mapped(PressureRead).map();
    defer pressure_map.unmap();
    pressure_map.value.init(session.slice(), 0, 0, 0, std.math.maxInt(i64));
    defer pressure_map.value.deinit();
    meter.start();
    try std.testing.expect(!try replies.keep(storage.advancePartsPressure(pressure_map.value)));
    try meter.stop(.advancePartsPressure);
    var public_reader = try @import("domain/public_parts.zig").Reader.init(session, owner);
    defer public_reader.deinit();
    meter.start();
    try std.testing.expect((try replies.keep(storage.readPublicParts(&public_reader))) == .pending);
    try meter.stop(.readPublicParts);
    meter.start();
    _ = try replies.keep(storage.openPublicPart(session.slice(), owner, 1, 0));
    try meter.stop(.openPublicPart);
    const binding = (try replies.keep(storage.admitModelAttempt(.message, .{}))).?.permit.binding;
    var view: TestingPage = undefined;
    view.open(storage, binding);
    defer view.close();
    var settings: HistoricalSettings = undefined;
    try view.settings(&settings);
    _ = replies.keep(&settings);
    try std.testing.expect(view.page.compound_inputs);
    const message = (try view.nextEntry(0)).?;
    _ = replies.keep(message);
    try view.page.openMessage(message.input.?);
    try std.testing.expectError(error.PageRead, view.page.nextMessagePart());
    try storage.readRequestPage(&view.page); // One bounded raw manifest window.
    keepRequestPage(replies, &view.page);
    try std.testing.expectError(error.PageRead, view.page.nextMessagePart());
    meter.start();
    try storage.readRequestPage(&view.page); // One bounded index page.
    try meter.stop(.readHistoricalMessagePart);
    keepRequestPage(replies, &view.page);
    var count: usize = 0;
    while (try view.nextMessagePart()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
    _ = replies.keep(count);
    try std.testing.expect(view.page.message_cursor == null);
    try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
}

/// A request page's reads: the entries its window holds and the tool and message counters it reads. Its cursors hold
/// allocators and pointers to other reads, so the struct is not kept whole.
fn keepRequestPage(replies: *store_testing.ReplyDigest, page: *const historical_domain.RequestPage) void {
    _ = replies.keep(page.entries[0..page.entries_end]);
    _ = replies.keep(page.message_cursor == null);
    _ = replies.keep(page.tool_set_id);
    _ = replies.keep(page.tool_count);
    _ = replies.keep(page.provider_tool_count);
    _ = replies.keep(page.provider_tools_read);
}

fn plainTurn(storage: *Store, tmp: *std.testing.TmpDir, meter: *RoundMeter, replies: *store_testing.ReplyDigest) !void {
    meter.start();
    const session = try replies.keep(configureTestSession(storage, "budget-plain"));
    try meter.stop(.configure);
    meter.start();
    try submitTestMessage(storage, tmp, "budget-plain-input", "budget-plain-key", session.slice(), "hello");
    try meter.stop(.submitMessageWithModel);
    const search = try std.testing.allocator.create(protocol.ActivitySearchFacts);
    defer std.testing.allocator.destroy(search);
    var search_request: protocol.ActivitySearch = .{ .session = session, .kinds = .initOne(.admission), .limit = 1 };
    try search_request.query.set("hello");
    meter.start();
    try storage.searchActivity(&search_request, search);
    try meter.stop(.searchActivity);
    _ = replies.keep(search);
    try std.testing.expectEqual(@as(usize, 1), search.count);
    meter.start();
    _ = try replies.keep(store_testing.observeCommandForTesting(storage, "budget-plain-key"));
    try meter.stop(.observeCommand);
    meter.start();
    const binding = (try replies.keep(storage.admitModelAttempt(.message, .{}))).?.permit.binding;
    try meter.stop(.admitModelAttempt);
    meter.start();
    _ = try replies.keep(storage.modelOperationKind(binding));
    try meter.stop(.checkAttempt);
    meter.start();
    try std.testing.expect(try replies.keep(storage.operationSupersededByControl(binding)) == null);
    try meter.stop(.operationSupersededByControl);
    meter.start();
    try storage.withDispatchHandoff(binding, {}, Launch.run);
    try meter.stop(.withDispatchHandoff);
    meter.start();
    _ = try replies.keep(storage.claimModelAuthRefresh(binding));
    try meter.stop(.claimModelAuthRefresh);
    const item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}";
    meter.start();
    try settleItemsForTesting(storage, tmp, binding, &.{item}, "hi");
    try meter.stop(.settleModelSuccess);
    meter.start();
    const result = try replies.keep(storage.commandResult("budget-plain-key"));
    try meter.stop(.commandResult);
    meter.start();
    const location = try replies.keep(storage.openContent(result));
    try meter.stop(.openContentIdentity);
    var reader: ContentReader = undefined;
    reader.open(location);
    defer reader.close();
    var bytes: [64]u8 = undefined;
    meter.start();
    const read_bytes = try reader.read(0, &bytes);
    try std.testing.expectEqual(2, read_bytes);
    _ = replies.keep(bytes[0..read_bytes]);
    try meter.stop(.readOwnedContent);
    var request: protocol.ConversationPage = .{};
    try request.session.set(session.slice());
    var page: reads_domain.PublicConversationPage = undefined;
    meter.start();
    try storage.publicConversationPage(&request, &page, std.testing.allocator);
    try meter.stop(.publicConversationPage);
    _ = replies.keep(&page);
    const answer = for (page.items[0..page.count]) |entry| {
        if (entry.kind == .assistant) break entry.position;
    } else return error.NoAnswer;
    meter.start();
    _ = try replies.keep(storage.openPublicConversationContent(&.{ .session = session, .position = answer }));
    try meter.stop(.openPublicConversationContent);

    try submitTestMessage(storage, tmp, "budget-again-input", "budget-again-key", session.slice(), "again");
    const running = (try replies.keep(storage.admitNextModelAttempt(.{}))).?.permit.binding;
    var interrupt: protocol.ModelInterruptionCommand = .{ .turn_id = running.turn_id, .operation_id = running.operation_id };
    try interrupt.key.set("budget-interrupt");
    try interrupt.session.set(session.slice());
    meter.start();
    try std.testing.expect(replies.keep(storage.interruptModel(&interrupt, .{})) == .accepted);
    try meter.stop(.interruptModel);
    var stop = try completeSessionStop("budget-stop", session.slice());
    meter.start();
    try std.testing.expect(replies.keep(storage.stopSession(&stop, .{})) == .accepted);
    try meter.stop(.stopSession);
    var archive: protocol.SessionArchiveCommand = .{ .session = session };
    try archive.key.set("budget-archive");
    meter.start();
    try std.testing.expect(replies.keep(storage.archiveSession(&archive, .{})) == .accepted);
    try meter.stop(.archiveSession);
    archive.archived = false;
    try archive.key.set("budget-unarchive");
    try std.testing.expect(replies.keep(storage.archiveSession(&archive, .{})) == .accepted);
    var pin: protocol.SessionPinCommand = .{ .session = session, .pinned = true };
    try pin.key.set("budget-pin");
    meter.start();
    try std.testing.expect(replies.keep(storage.pinSession(&pin, .{})) == .accepted);
    try meter.stop(.pinSession);
}

/// One Turn of a built-in Host runner whose Action is selected and read back by `nextAction`.
fn localRunnerTurn(case: *store_testing.Case, meter: *RoundMeter, replies: *store_testing.ReplyDigest, comptime runner: tool_defs.Runner) !void {
    const tool = if (runner == .read_image) "read_image" else "watch_github_pr";
    const decoded = if (runner == .read_image) "{\"path\":\"image.png\"}" else "{\"url\":\"https://github.com/org/repo/pull/42\"}";
    const encoded = if (runner == .read_image) "{\\\"path\\\":\\\"image.png\\\"}" else "{\\\"url\\\":\\\"https://github.com/org/repo/pull/42\\\"}";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const previous = meter.storage;
    meter.storage = &storage;
    defer meter.storage = previous;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var configure = try completeConfiguration("budget-" ++ tool, "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
    configure.configuration.tools = try .of(&.{tool});
    const configured = try replies.keep(storage.configure(&configure, .{}));
    try std.testing.expect(configured == .accepted);
    const session = configured.accepted.session;
    try submitTestMessage(&storage, &tmp, "budget-" ++ tool ++ "-input", "budget-" ++ tool ++ "-message", session.slice(), "inspect");
    const model = (try replies.keep(storage.admitNextModelAttempt(.{}))).?.permit.binding;
    try settleCallsForTesting(&storage, &tmp, model, "budget-" ++ tool ++ "-calls", &.{
        .{ .item_id = tool ++ "-item", .name = tool, .encoded_call_id = tool ++ "-call", .decoded_call_id = tool ++ "-call", .encoded_arguments = encoded, .decoded_arguments = decoded },
    });
    const selected = (try replies.keep(storage.nextAction(runner, .fromFree(1, false)))).?;
    const binding = (try replies.keep(storage.admitActionAttempt(selected, 1234, .{}))).?.permit.binding;
    var input: ActionExecutionInput = undefined;
    meter.start();
    try storage.readActionExecutionInput(runner, binding, &input);
    try meter.stop(if (runner == .read_image) .readImageExecutionInput else .readGithubPrWatchExecutionInput);
    _ = replies.keep(&input);
}

fn mcpTurn(case: *store_testing.Case, meter: *RoundMeter, replies: *store_testing.ReplyDigest) !void {
    const records = comptime testingHostToolRecords(&.{
        .{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a docs page.", .input_schema = "{\"type\":\"object\"}" },
    });
    const digests = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var out: [records.len][32]u8 = undefined;
        for (&records, &out) |*record, *digest| digest.* = tool_defs.recordDigest(record);
        break :blk out;
    };
    const host_tool_set: tool_defs.HostToolSet = .{ .records = &records, .digests = &digests };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
    defer storage.close() catch unreachable;
    const previous_storage = meter.storage;
    meter.storage = &storage;
    defer meter.storage = previous_storage;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("budget-mcp", "", workspace, "model-a");
    command.configuration.tools = try .of(&.{"fetch_page"});
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set("bypass");
    const configured = try replies.keep(storage.configure(&command, .{}));
    try std.testing.expect(configured == .accepted);
    const session = configured.accepted.session;
    try submitTestMessage(&storage, &tmp, "budget-mcp-input", "budget-mcp-key", session.slice(), "fetch a page");
    const model = (try replies.keep(storage.admitNextModelAttempt(.{}))).?.permit.binding;
    try settleCallsForTesting(&storage, &tmp, model, "budget-mcp-calls", &.{
        .{ .item_id = "mcp-item", .name = "fetch_page", .encoded_call_id = "mcp-call", .decoded_call_id = "mcp-call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "mcp-item-two", .name = "fetch_page", .encoded_call_id = "mcp-call-two", .decoded_call_id = "mcp-call-two", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    });
    meter.start();
    const action = (try replies.keep(storage.nextAction(.mcp, .{ .free_credit = .one, .mcp_open = true }))).?;
    try meter.stop(.nextAction);
    meter.start();
    try storage.resolveAction(action, .spawn_failed, "Failed, not run: this Host does not run MCP tool calls yet.", .{});
    try meter.stop(.resolveAction);
    const second = (try replies.keep(storage.nextAction(.mcp, .{ .free_credit = .one, .mcp_open = true }))).?;
    meter.start();
    const binding = (try replies.keep(storage.admitActionAttempt(second, 600_000, .{}))).?.permit.binding;
    try meter.stop(.admitActionAttempt);
    var input: action_domain.ActionExecutionInput = undefined;
    meter.start();
    try storage.readActionExecutionInput(.mcp, binding, &input);
    try meter.stop(.readMcpExecutionInput);
    _ = replies.keep(&input);
    _ = try replies.keep(storage.settleActionAttempt(binding, .succeeded, "done", .{}));
    try std.testing.expect((try replies.keep(storage.nextAction(.mcp, .{ .free_credit = .one, .mcp_open = true }))) == null);
    try std.testing.expect((try replies.keep(storage.admitNextModelAttempt(.{}))) != null);
}

fn skillTurn(case: *store_testing.Case, meter: *RoundMeter, replies: *store_testing.ReplyDigest) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const previous_storage = meter.storage;
    meter.storage = &storage;
    defer meter.storage = previous_storage;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const skills = @import("../skills.zig");
    const catalog: skills.Catalog = .{ .entries = &.{.{ .name = "demo", .description = "Budget skill", .path = "/budget/demo/SKILL.md" }} };
    const initial: skills_fixture_domain.Initial = .{ .ready = .{
        .encoded = try skills.encodeCatalog(arena.allocator(), catalog),
        .instruction = try skills.initialInstruction(arena.allocator(), catalog),
    } };
    var path: [protocol.max_workspace_bytes]u8 = undefined;
    var create = try completeConfiguration("budget-skill", "", try canonicalCwd(std.testing.io, &path), "model-a");
    create.configuration.tools = try .of(&.{"skill"});
    const session = (try replies.keep(storage.configureWithInitialSkills(&create, null, &initial, .{}))).accepted.session;
    meter.start();
    try std.testing.expect(try replies.keep(storage.commandExists("budget-skill")));
    try meter.stop(.commandExists);
    try std.testing.expect(!try replies.keep(storage.commandExists("budget-skill-absent")));
    meter.start();
    const saved = try replies.keep(storage.readSkills(arena.allocator(), session.slice()));
    try meter.stop(.readSkills);
    try std.testing.expectEqual(@as(usize, 1), saved.catalog.entries.len);
    try std.testing.expectEqualStrings("demo", saved.catalog.entries[0].name);
    try std.testing.expectEqualStrings("/budget/demo/SKILL.md", saved.catalog.entries[0].path);
    try submitTestMessage(&storage, &tmp, "budget-skill-input", "budget-skill-key", session.slice(), "use demo");
    const model = (try replies.keep(storage.admitNextModelAttempt(.{}))).?.permit.binding;
    const calls = [_]TestingCall{.{ .item_id = "skill-item", .name = "skill", .encoded_call_id = "skill-call", .decoded_call_id = "skill-call", .encoded_arguments = "{\\\"operation\\\":\\\"invoke\\\",\\\"name\\\":\\\"demo\\\"}", .decoded_arguments = "{\"operation\":\"invoke\",\"name\":\"demo\"}" }};
    try settleCallsForTesting(&storage, &tmp, model, "budget-skill-calls", &calls);
    const input = (try replies.keep(storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true }))).?.action;
    try std.testing.expectEqual(action_domain.CoreTool.skill, input.tool);
    const captured: skills_fixture_domain.Capture = .{ .invocation = "Skill file: \"/budget/demo/SKILL.md\"\n\nbudget bytes" };
    meter.start();
    try std.testing.expect(try replies.keep(storage.settleSkillTool(input.binding, arena.allocator(), &captured, .{})));
    try meter.stop(.settleSkillTool);
    try std.testing.expect(!storage.isFenced());
}

fn findTurn(storage: *Store, tmp: *std.testing.TmpDir, meter: *RoundMeter, replies: *store_testing.ReplyDigest) !void {
    var path: [protocol.max_workspace_bytes]u8 = undefined;
    var configuration = try completeConfiguration("budget-find", "", try canonicalCwd(std.testing.io, &path), "model-a");
    configuration.configuration.tools = try .of(&.{ "bash", "find_tools" });
    configuration.configuration.loaded_tools = try .of(&.{"find_tools"});
    const session = (try replies.keep(storage.configure(&configuration, .{}))).accepted.session;
    try submitTestMessage(storage, tmp, "budget-find-input", "budget-find-key", session.slice(), "find tools");
    const model = (try replies.keep(storage.admitNextModelAttempt(.{}))).?.permit.binding;
    const calls = [_]TestingCall{.{ .item_id = "find-item", .name = "find_tools", .encoded_call_id = "find-call", .decoded_call_id = "find-call", .encoded_arguments = "{\\\"words\\\":\\\"absent0 absent1 absent2 absent3 absent4 absent5 absent6 absent7\\\"}", .decoded_arguments = "{\"words\":\"absent0 absent1 absent2 absent3 absent4 absent5 absent6 absent7\"}" }};
    try settleCallsForTesting(storage, tmp, model, "budget-find-calls", &calls);
    const input = (try replies.keep(storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true }))).?.action;
    const words: @import("../core_tools.zig").FindTools = .{ .words = .{ "absent0", "absent1", "absent2", "absent3", "absent4", "absent5", "absent6", "absent7" }, .count = 8 };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    meter.start();
    try std.testing.expect(try replies.keep(storage.findTools(input.binding, arena.allocator(), &words, null, .{})));
    try meter.stop(.findTools);
}

fn coreTurn(storage: *Store, tmp: *std.testing.TmpDir, meter: *RoundMeter, replies: *store_testing.ReplyDigest) !void {
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("budget-core", "", workspace, "model-a");
    command.configuration.tools.state = .value;
    command.configuration.tools = try .of(&.{ "message_agent", "start_agent" });
    const session = (try replies.keep(storage.configure(&command, .{}))).accepted.session;
    try submitTestMessage(storage, tmp, "budget-core-input", "budget-core-key", session.slice(), "message yourself");
    const model = (try replies.keep(storage.admitNextModelAttempt(.{}))).?.permit.binding;
    var arguments_buffer: [64]u8 = undefined;
    const decoded = try std.fmt.bufPrint(&arguments_buffer, "{{\"id\":\"{s}\",\"text\":\"hi\"}}", .{session.slice()});
    var encoded_buffer: [96]u8 = undefined;
    const encoded = try std.fmt.bufPrint(&encoded_buffer, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"hi\\\"}}", .{session.slice()});
    const calls = [_]TestingCall{
        .{ .item_id = "core-item", .name = "message_agent", .encoded_call_id = "core-call", .decoded_call_id = "core-call", .encoded_arguments = encoded, .decoded_arguments = decoded },
        .{ .item_id = "start-item", .name = "start_agent", .encoded_call_id = "start-call", .decoded_call_id = "start-call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "refused-item", .name = "start_agent", .encoded_call_id = "refused-call", .decoded_call_id = "refused-call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    };
    try settleCallsForTesting(storage, tmp, model, "budget-core-calls", &calls);
    meter.start();
    const core = (try replies.keep(storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true }))).?.action;
    try meter.stop(.nextCoreWork);
    meter.start();
    try std.testing.expect(try replies.keep(storage.deliverAgentMessage(core.binding, session.slice(), "hi", .{})) == .delivered);
    try meter.stop(.deliverAgentMessage);
    const start = (try replies.keep(storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true }))).?.action;
    try std.testing.expect(start.tool == .start_agent);
    var spec = try testingAgentSpec(&.{"message_agent"}, "ask");
    meter.start();
    try std.testing.expect(try replies.keep(storage.startAgent(start.binding, session.slice(), "look around", true, &spec, null, .{})) == .started);
    try meter.stop(.startAgent);
    const refused = (try replies.keep(storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true }))).?.action;
    meter.start();
    try std.testing.expect(try replies.keep(storage.failCoreCall(refused.binding, "Rui could not start the agent: task is required. Nothing was started.", .{})));
    try meter.stop(.resolveCoreCall);
    const result_page = try replies.keep(store_core.activityPageForTesting(storage, .{ .session = session, .direction = .backward, .kinds = .initOne(.tool_result), .limit = 1 }));
    const result = result_page.items[0];
    try std.testing.expectEqual(@as(u64, 3), result.ordinal);
    meter.start();
    const tool = try replies.keep(storage.activityTool(&.{ .session = session, .position = result.position, .ordinal = result.ordinal }));
    try meter.stop(.activityTool);
    try std.testing.expect(tool.presentation.code == .failed);
    try expectContent(storage, .{ .length = tool.name.length, .digest = tool.name.digest }, "start_agent");
    while (try replies.keep(storage.admitNextModelAttempt(.{}))) |_| {}
    var stop = try completeSessionStop("budget-core-stop", session.slice());
    try std.testing.expect(replies.keep(storage.stopSession(&stop, .{})) == .accepted);
    const owed = (try replies.keep(storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true }))).?.stop;
    var owed_stop: protocol.SessionStopCommand = .{ .key = owed.key };
    try owed_stop.session.set(owed.session.slice());
    meter.start();
    try std.testing.expect(replies.keep(storage.stopOwedSession(&owed_stop, .{})) == .accepted);
    try meter.stop(.stopOwedSession);
    const ending = (try replies.keep(storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true }))).?.ending;
    meter.start();
    try std.testing.expect(try replies.keep(storage.deliverChildEnding(ending.turn_id, .{})));
    try meter.stop(.deliverChildEnding);
    const forward = (try replies.keep(storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true }))).?.forward;
    meter.start();
    try std.testing.expect(try replies.keep(storage.deliverSessionForward(forward, .{})));
    try meter.stop(.deliverSessionForward);
}

fn stopTurn(case: *store_testing.Case, meter: *RoundMeter, replies: *store_testing.ReplyDigest) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const previous_storage = meter.storage;
    meter.storage = &storage;
    defer meter.storage = previous_storage;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var configure = try completeConfiguration("budget-action-stop", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
    configure.configuration.tools = try .of(&.{ "bash", "read_action", "stop_action" });
    configure.configuration.permission_mode.state = .value;
    try configure.configuration.permission_mode.value.set("bypass");
    const session = (try replies.keep(storage.configure(&configure, .{}))).accepted.session;
    try submitTestMessage(&storage, &tmp, "budget-stop-input", "budget-stop-input", session.slice(), "run");
    const model = (try replies.keep(storage.admitNextModelAttempt(.{}))).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "target-item", .name = "bash", .encoded_call_id = "target-call", .decoded_call_id = "target-call", .encoded_arguments = "{\\\"cmd\\\":\\\"true\\\",\\\"description\\\":\\\"Budget target\\\"}", .decoded_arguments = "{\"cmd\":\"true\",\"description\":\"Budget target\"}" },
        .{ .item_id = "stop-item", .name = "stop_action", .encoded_call_id = "stop-call", .decoded_call_id = "stop-call", .encoded_arguments = "{\\\"action\\\":\\\"1\\\"}", .decoded_arguments = "{\"action\":\"1\"}" },
    };
    try settleCallsForTesting(&storage, &tmp, model, "budget-stop-calls", &calls);
    const target = try store_testing.queryU64(&storage, "SELECT min(action_id) FROM action_operation WHERE parent_operation_id=?1", .{model.operation_id});
    const source = (try replies.keep(storage.nextCoreWork(.fromFree(2, true)))).?.action;
    try std.testing.expectEqual(action_domain.CoreTool.stop_action, source.tool);
    meter.start();
    const stopped = try replies.keep(storage.stopAction(source.binding, target, .{}));
    try std.testing.expectEqual(std.meta.Tag(@TypeOf(stopped)).selected, std.meta.activeTag(stopped));
    try meter.stop(.stopAction);
}

fn toolTurn(storage: *Store, tmp: *std.testing.TmpDir, meter: *RoundMeter, replies: *store_testing.ReplyDigest) !void {
    const session = try replies.keep(configureTestSessionAsk(storage, "budget-tools"));
    try submitTestMessage(storage, tmp, "budget-tools-input", "budget-tools-key", session.slice(), "run");
    const first = (try replies.keep(storage.admitNextModelAttempt(.{}))).?.permit.binding;
    const arguments = "{\\\"description\\\":\\\"Disk usage\\\",\\\"cmd\\\":\\\"df -h\\\",\\\"timeout_ms\\\":null}";
    const decoded = "{\"description\":\"Disk usage\",\"cmd\":\"df -h\",\"timeout_ms\":null}";
    const calls = [_]TestingCall{
        .{ .item_id = "item-a", .name = "bash", .encoded_call_id = "call-a", .decoded_call_id = "call-a", .encoded_arguments = arguments, .decoded_arguments = decoded },
        .{ .item_id = "item-b", .name = "bash", .encoded_call_id = "call-b", .decoded_call_id = "call-b", .encoded_arguments = arguments, .decoded_arguments = decoded },
    };
    try settleCallsForTesting(storage, tmp, first, "budget-calls", &calls);
    const allowed = try store_testing.queryU64(storage, "SELECT min(action_id) FROM action_operation", .{});
    const denied = try store_testing.queryU64(storage, "SELECT max(action_id) FROM action_operation", .{});
    meter.start();
    _ = try replies.keep(storage.actionArguments(session.slice(), allowed));
    try meter.stop(.actionContent);
    var action_read: @import("../action_read.zig").Read = undefined;
    meter.start();
    try storage.readAction(&.{ .session = session, .action_id = allowed }, &action_read);
    try meter.stop(.readAction);
    _ = replies.keep(&action_read);
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = allowed, .decision = .allow_once };
    try allow.key.set("budget-allow");
    try allow.session.set(session.slice());
    meter.start();
    try std.testing.expect(replies.keep(storage.decidePermission(&allow, .{})) == .accepted);
    try meter.stop(.decidePermission);
    meter.start();
    const action = (try replies.keep(storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{}))).?.permit.binding;
    try meter.stop(.admitNextActionAttempt);
    var input: ActionExecutionInput = undefined;
    meter.start();
    try storage.readActionExecutionInput(.bash, action, &input);
    try meter.stop(.readBashExecutionInput);
    _ = replies.keep(&input);
    meter.start();
    try std.testing.expect((try replies.keep(storage.publishActionValue(input.sender_handle.slice(), "budget-value", "value"))) == .accepted);
    try meter.stop(.publishActionValue);
    meter.start();
    try storage.withActionDispatchHandoff(action, {}, Launch.run);
    try meter.stop(.withActionDispatchHandoff);
    meter.start();
    _ = try replies.keep(storage.messageAfterActionLaunch(action, 0));
    try meter.stop(.messageAfterActionLaunch);
    meter.start();
    try std.testing.expect(try replies.keep(storage.actionSupersededByStop(action)) == null);
    try meter.stop(.actionSupersededByStop);
    meter.start();
    try storage.revokeActionSender(action);
    try meter.stop(.revokeActionSender);
    meter.start();
    _ = try replies.keep(storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{}));
    try meter.stop(.settleActionAttempt);
    var background: @import("../command_input.zig").ActionBackgroundCommand = .{ .session = session, .action_id = allowed };
    try background.key.set("budget-background");

    meter.start();
    const selected_final = replies.keep(storage.backgroundAction(.{ .command = &background }, .{}));
    try std.testing.expect(selected_final == .accepted and selected_final.accepted.selection.kind == .final);
    try meter.stop(.backgroundAction);
    var deny: protocol.PermissionDecisionCommand = .{ .action_id = denied, .decision = .deny };
    try deny.key.set("budget-deny");
    try deny.session.set(session.slice());
    meter.start();
    try std.testing.expect(replies.keep(storage.declineForMessage(&deny, .{})) == .accepted);
    try meter.stop(.declineForMessage);
    meter.start();
    try std.testing.expect(!try replies.keep(storage.recoverOneUncertainAction(ActiveOperationFilter.empty())));
    try meter.stop(.recoverOneUncertainAction);

    var add_search: wire_request.ConfigureCommand = .{};
    try add_search.key.set("budget-add-search");
    try add_search.session.set(session.slice());
    add_search.configuration.tools = try .of(&.{ "bash", "web_search" });
    add_search.configuration.tools.state = .value;
    try std.testing.expect(try replies.keep(storage.configure(&add_search, .{})) == .accepted);
    const continuation = (try replies.keep(storage.admitNextModelAttempt(.{}))).?.permit.binding;
    {
        var view: TestingPage = undefined;
        view.open(storage, continuation);
        defer view.close();
        meter.start();
        _ = replies.keep(try view.validateOutputsStep());
        try meter.stop(.validateHistoricalOutputsStep);
        while (!try replies.keep(view.validateOutputsStep())) {}
        var settings: HistoricalSettings = undefined;
        meter.start();
        try view.settings(&settings);
        try meter.stop(.readHistoricalSettings);
        _ = replies.keep(&settings);
        var tool: historical_domain.HistoricalTool = .{};
        meter.start();
        try std.testing.expect(try view.nextTool(&tool));
        try meter.stop(.readTools);
        _ = replies.keep(&tool);
        meter.start();
        try std.testing.expect(try view.nextProviderTool(&tool));
        try meter.stop(.readProviderTool);
        _ = replies.keep(&tool);
        _ = replies.keep(try view.coverage());
        var declaration = view.currentDeclaration();
        const declared = ViewRounds.start(storage);
        try std.testing.expect(!try view.nextDeclaredTool(&declaration, &tool));
        _ = replies.keep(&declaration);
        _ = replies.keep(&tool);
        try std.testing.expectEqual(@as(u16, 1), declared.taken().rounds);
        meter.start();
        var entry = (try view.nextEntry(0)).?;
        try meter.stop(.readHistoricalEntry);
        _ = replies.keep(entry);
        entry = (try nextTestingItem(&view, entry.position)).?;
        try std.testing.expectEqual(HistoricalEntryKind.provider_output, entry.kind);
        _ = replies.keep(entry);
        meter.start();
        _ = replies.keep(try view.openOutput(entry.position));
        _ = replies.keep(try view.nextOutputPart());
        try meter.stop(.readHistoricalParts);
        while (entry.kind != .tool_results) {
            entry = (try nextTestingItem(&view, entry.position)).?;
            _ = replies.keep(entry);
        }
        meter.start();
        _ = replies.keep((try view.nextToolResult()).?);
        try meter.stop(.readHistoricalToolResult);
        meter.start();
        const seal_read = try view.prefixSeal();
        try std.testing.expect(seal_read == null);
        _ = replies.keep(seal_read);
        try meter.stop(.readPrefixSeal);
        const seal: historical_domain.PrefixSeal = .{ .anchor = null, .admission_position = 1, .span_length = 0, .digest = @splat(0) };
        meter.start();
        try view.recordPrefixSeal(&seal);
        try meter.stop(.recordPrefixSeal);
    }
    meter.start();
    try std.testing.expect(try replies.keep(storage.settleModelAttemptFailurePrepared(continuation, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{}, null)));
    try meter.stop(.settleModelAttemptFailurePrepared);
    meter.start();
    try std.testing.expect(try replies.keep(storage.tryAdmitNextModelRetry(ActiveOperationFilter.empty(), .{}, null)) == null);
    try meter.stop(.tryAdmitNextModelRetry);
    meter.start();
    _ = try replies.keep(storage.dispatchWork(false, .{ .free_credit = .one, .mcp_open = true }));
    try meter.stop(.dispatchWork);
    meter.start();
    try std.testing.expect(!try replies.keep(storage.recoverOneExhaustedModelAttempt(ActiveOperationFilter.empty())));
    try meter.stop(.recoverOneExhaustedModelAttempt);

    meter.start();
    _ = try replies.keep(storage.inspectSessionForTesting(session.slice()));
    try meter.stop(.inspectSession);
    var activity: protocol.ActivityPage = .{};
    try activity.session.set(session.slice());
    meter.start();
    const rows = try replies.keep(store_core.activityPageForTesting(storage, activity));
    try meter.stop(.activityPage);
    meter.start();
    _ = try replies.keep(storage.openActivityContent(&.{ .session = session, .position = rows.items[0].position }));
    try meter.stop(.openActivityContent);
    meter.start();
    std.testing.allocator.free(try replies.keep(testingSessionReport(storage, tmp, session.slice(), 1024 * 1024)));
    try meter.stop(.readSessionReport);
    var used = std.atomic.Value(u64).init(0);
    meter.start();
    std.testing.allocator.free(try replies.keep(testingSessionList(storage, tmp, .{}, &used, 2)));
    try meter.stop(.readSessionList);
    meter.start();
    std.testing.allocator.free(try replies.keep(testingSessionList(storage, tmp, .{ .archive = .archived, .window = .head }, &used, 3)));
    try meter.stop(.readArchivedWindow);
    // A changed page: one Session is created after the token, so the page names it and its ancestor batch runs in one round.
    const since: protocol.SinceToken = .{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) };
    _ = try replies.keep(configureTestSession(storage, "budget-changed"));
    meter.start();
    std.testing.allocator.free(try replies.keep(testingSessionList(storage, tmp, .{ .since = since }, &used, 4)));
    try meter.stop(.readChangedSessionList);
    meter.start();
    const binding = try replies.keep(storage.failedResponseBinding(session.slice(), continuation.operation_id, continuation.attempt_ordinal));
    try meter.stop(.failedResponseBinding);
    try std.testing.expectEqualDeep(continuation, binding);
}

fn compactedTurn(storage: *Store, tmp: *std.testing.TmpDir, meter: *RoundMeter, replies: *store_testing.ReplyDigest) !void {
    const session = try replies.keep(configureTestSession(storage, "budget-compacted"));
    var patch: wire_request.ConfigureCommand = .{};
    try patch.key.set("budget-heuristics");
    try patch.session.set(session.slice());
    patch.configuration.compaction_trigger.state = .value;
    try patch.configuration.compaction_trigger.value.set("1000");
    patch.configuration.output_reservation.state = .value;
    try patch.configuration.output_reservation.value.set("1");
    try std.testing.expect(try replies.keep(storage.configure(&patch, .{})) == .accepted);
    try submitTestMessage(storage, tmp, "budget-one", "budget-one", session.slice(), "original");
    const first = (try replies.keep(storage.admitNextModelAttempt(.{}))).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-a", .name = "unknown", .encoded_call_id = "call-a", .decoded_call_id = "call-a", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    };
    try settleCallsForTestingWithFaults(storage, tmp, first, "budget-usage", &calls, .{}, "{\"input_tokens\":99999,\"output_tokens\":1,\"details\":{\"input_tokens\":0}}");
    try submitTestMessage(storage, tmp, "budget-two", "budget-two", session.slice(), "later");
    const compaction = (try replies.keep(storage.admitNextModelAttempt(.{}))).?.permit.binding;
    try std.testing.expectEqual(ModelOperationKind.compaction, try replies.keep(storage.modelOperationKind(compaction)));
    const FloorPreparation = @import("domain/history_floor.zig").Preparation;
    const floor_map = try @import("../os/pages.zig").Mapped(FloorPreparation).map();
    defer floor_map.unmap();
    floor_map.value.init(compaction.operation_id);
    defer floor_map.value.deinit();
    meter.start();
    try std.testing.expect(!try replies.keep(storage.advanceHistoryFloor(floor_map.value)));
    try meter.stop(.advanceHistoryFloor);
    while (!try replies.keep(storage.advanceHistoryFloor(floor_map.value))) {}
    try std.testing.expect(floor_map.value.prepared != null);
    try settleCompactionForTesting(storage, tmp, compaction, &.{.compaction});
    const successor = (try replies.keep(storage.admitNextModelAttempt(.{}))).?.permit.binding;
    var view: TestingPage = undefined;
    view.open(storage, successor);
    defer view.close();
    while (!try replies.keep(view.validateOutputsStep())) {}
    const rounds = ViewRounds.start(storage);
    try std.testing.expect((try replies.keep(view.coverage())).anchor != null);
    try std.testing.expectEqual(@as(u16, 0), rounds.taken().rounds);
}

// Moved from src/store/mysql_testing.zig: "store.mysql live a connection lost around COMMIT reconnects and reports what landed"
fn sh2_store_mysql_live_a_connection_lost_around() !void {
    for ([_]Drop{ .before_commit, .after_commit }) |drop| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: mt.Store = undefined;
        try mt.openLive(&storage, &tmp);
        defer storage.close() catch {};
        const state = storage.engine.mysql.state;
        const old_connection = state.connection_id;
        const got = try mt.commitLosing(&storage, drop);
        const rows_saved = try mt.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=?1", .{got.id});
        switch (drop) {
            .before_commit => {
                try std.testing.expectEqual(@as(?anyerror, error.StoreConnectionLost), state.failure);
                try std.testing.expectError(error.CanonicalRollbackFailed, got.result);
                try std.testing.expectEqual(@as(u64, 0), rows_saved);
            },
            .after_commit => {
                try got.result;
                try std.testing.expectEqual(@as(u64, 1), rows_saved);
            },
            .none, .next_pass => unreachable,
        }
        try std.testing.expectEqual(@as(u64, 1), state.testing_shape.reconnects);
        try std.testing.expect(state.connection_id != old_connection);
        var second: mt.Store = undefined;
        try std.testing.expectError(error.StoreLocked, mt.open(&second, &tmp, std.testing.io, .{}));
        if (drop == .after_commit) {
            try std.testing.expectEqual(@as(u64, 1), try mt.liveWrite(&storage, mt.live_noop, .{}));
            try std.testing.expect(!storage.isFenced());
        }
    }
}

// Moved from src/store/mysql_testing.zig: "store.mysql live a reconnect onto a server admission refuses does not resume"
fn sh2_store_mysql_live_a_reconnect_onto_a() !void {
    if (!try mt.available()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: mt.Store = undefined;
    try mt.openLive(&storage, &tmp);
    defer storage.close() catch {};
    const old = old: {
        mt.mutex.lockUncancelable(std.testing.io);
        defer mt.mutex.unlock(std.testing.io);
        _ = try mt.connection();
        const old = try mt.globalValue("innodb_flush_log_at_trx_commit");
        try mt.setGlobal("innodb_flush_log_at_trx_commit", "2");
        break :old old;
    };
    defer {
        mt.mutex.lockUncancelable(std.testing.io);
        defer mt.mutex.unlock(std.testing.io);
        mt.setGlobal("innodb_flush_log_at_trx_commit", old.slice()) catch @panic("cannot restore innodb_flush_log_at_trx_commit");
    }
    const got = try mt.commitLosing(&storage, .after_commit);
    try std.testing.expectEqual(@as(?anyerror, error.CommitOutcomeUnknown), storage.engine.mysql.state.failure);
    try std.testing.expectError(error.CanonicalRollbackFailed, got.result);
    try std.testing.expectEqual(@as(u64, 0), storage.engine.mysql.state.testing_shape.reconnects);
}

// Moved from src/store/mysql_testing.zig: "store.mysql live a reconnect never ends a session that does not hold the Store's lock"
fn sh2_store_mysql_live_a_reconnect_never_ends() !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: mt.Store = undefined;
    try mt.openLive(&storage, &tmp);
    defer storage.close() catch {};
    var other_tmp = std.testing.tmpDir(.{});
    defer other_tmp.cleanup();
    var other: mt.Store = undefined;
    try mt.openLive(&other, &other_tmp);
    defer other.close() catch {};
    storage.engine.mysql.state.connection_id = other.engine.mysql.state.connection_id;
    const got = try mt.commitLosing(&storage, .after_commit);
    try std.testing.expectEqual(@as(u64, 1), try mt.liveWrite(&other, mt.live_noop, .{}));
    try std.testing.expect(!other.isFenced());
    const rows_saved = try mt.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=?1", .{got.id});
    if (got.result) |_| {
        try std.testing.expectEqual(@as(u64, 1), rows_saved);
    } else |err| {
        try std.testing.expectEqual(@as(?anyerror, error.CommitOutcomeUnknown), storage.engine.mysql.state.failure);
        try std.testing.expectEqual(error.CanonicalRollbackFailed, err);
    }
}

// Moved from src/store/mysql_testing.zig: "store.mysql live a COMMIT and the reads after it share one message"
fn sh2_store_mysql_live_a_commit_and_the() !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: mt.Store = undefined;
    try mt.openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const mysql = &storage.engine.mysql;
    const state = mysql.state;
    try mysql.control(.begin);
    _ = try mt.liveWrite(&storage, mt.live_insert, .{ .id = 9000400, .digest = protocol.contentDigest("commit-then-read") });
    const seq = state.commit_seq;
    const queries = state.connection.queries;
    try std.testing.expectEqual(@as(u64, 1), try mt.commitThenCount(&storage, 9000400));
    try std.testing.expectEqual(queries + 1, state.connection.queries);
    try std.testing.expectEqual(seq + 1, state.commit_seq);
    try std.testing.expect(!mysql.inTransaction());
    try std.testing.expectEqual(state.commit_seq, try mt.queryU64(&storage, "SELECT commit_seq FROM store_owner WHERE owner_key=1", .{}));
    try mysql.control(.begin);
    try std.testing.expectEqual(@as(u64, 1), try mt.liveWrite(&storage, mt.live_noop, .{}));
    try mysql.control(.commit);
    try std.testing.expectEqual(seq + 2, state.commit_seq);
    try std.testing.expect(!storage.isFenced());
}

// Moved from src/store/mysql_testing.zig: "store.mysql live a connection lost after COMMIT's OK keeps the commit and never runs it again"
fn sh2_store_mysql_live_a_connection_lost_after() !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: mt.Store = undefined;
    try mt.openLive(&storage, &tmp);
    defer storage.close() catch {};
    const mysql = &storage.engine.mysql;
    const state = mysql.state;
    state.armed = true;
    try mysql.control(.begin);
    _ = try mt.liveWrite(&storage, mt.live_insert, .{ .id = 9000410, .digest = protocol.contentDigest("lost-after-commit") });
    const seq = state.commit_seq;
    try mysql.queueCommit();
    try mysql.bind(mt.live_count, &.{ .id = 9000410 }, 0);
    try mysql.startPass();
    try std.testing.expectEqual(seq + 1, state.commit_seq);
    state.connection.disconnect();
    try std.testing.expectError(error.StoreConnectionLost, mt.countAfterCommit(&storage));
    try std.testing.expect(!mysql.defersFence());
    try std.testing.expect(!mysql.recover());
    try std.testing.expectEqual(@as(u64, 1), try mt.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=?1", .{@as(u64, 9000410)}));
    try std.testing.expectEqual(seq + 1, try mt.queryU64(&storage, "SELECT commit_seq FROM store_owner WHERE owner_key=1", .{}));
}

// Moved from src/store/mysql_testing.zig: "store.mysql live a COMMIT lost with reads after it answers them once it landed, and saves nothing otherwise"
fn sh2_store_mysql_live_a_commit_lost_with() !void {
    const Case = struct { drop: Drop, armed: bool };
    for ([_]Case{
        .{ .drop = .before_commit, .armed = false },
        .{ .drop = .before_commit, .armed = true },
        .{ .drop = .after_commit, .armed = false },
        .{ .drop = .after_commit, .armed = true },
    }, 0..) |case, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: mt.Store = undefined;
        try mt.openLive(&storage, &tmp);
        defer storage.close() catch {};
        const mysql = &storage.engine.mysql;
        const state = mysql.state;
        const id: u64 = 9000420 + index;
        state.armed = case.armed;
        try mysql.control(.begin);
        _ = try mt.liveWrite(&storage, mt.live_insert, .{ .id = id, .digest = protocol.contentDigest("lost with reads") });
        const seq = state.commit_seq;
        state.testing_drop = case.drop;
        const got = mt.commitThenCount(&storage, id);
        try std.testing.expectEqual(@as(u64, 1), state.testing_shape.reconnects);
        switch (case.drop) {
            .before_commit => {
                try std.testing.expectError(error.StoreConnectionLost, got);
                try std.testing.expectEqual(seq, state.commit_seq);
                try std.testing.expectEqual(@as(u64, 0), try mt.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=?1", .{id}));
                try std.testing.expectEqual(case.armed, mysql.defersFence());
                try std.testing.expectEqual(case.armed, mysql.recover());
                if (!case.armed) continue;
                try mysql.control(.begin);
                _ = try mt.liveWrite(&storage, mt.live_insert, .{ .id = id, .digest = protocol.contentDigest("lost with reads") });
                try std.testing.expectEqual(@as(u64, 1), try mt.commitThenCount(&storage, id));
            },
            .after_commit => {
                try std.testing.expectEqual(@as(u64, 1), try got);
                try std.testing.expect(!mysql.defersFence());
                try std.testing.expect(!mysql.recover());
            },
            .none, .next_pass => unreachable,
        }
        try std.testing.expectEqual(seq + 1, state.commit_seq);
        try std.testing.expectEqual(seq + 1, try mt.queryU64(&storage, "SELECT commit_seq FROM store_owner WHERE owner_key=1", .{}));
        try std.testing.expectEqual(@as(u64, 1), try mt.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=?1", .{id}));
        try std.testing.expect(!mysql.inTransaction());
        try std.testing.expectEqual(@as(u64, 1), try mt.liveWrite(&storage, mt.live_noop, .{}));
        try std.testing.expect(!storage.isFenced());
    }
}

// Moved from src/store/mysql_testing.zig: "store.mysql live a write whose connection was lost with nothing saved runs again, unseen"
fn sh2_store_mysql_live_a_write_whose_connection() !void {
    for ([_]Drop{ .next_pass, .before_commit }) |drop| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: mt.Store = undefined;
        try mt.openLive(&storage, &tmp);
        defer storage.close() catch {};
        const state = storage.engine.mysql.state;
        const id: u64 = 9000100;
        state.testing_drop = drop;
        try storage.queue().write(mt.insertHeld, .{ &storage, id });
        try std.testing.expectEqual(@as(u64, 1), state.testing_shape.reconnects);
        try std.testing.expect(!storage.isFenced());
        try std.testing.expectEqual(@as(u64, 1), try mt.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=?1", .{id}));
        try storage.queue().write(mt.insertHeld, .{ &storage, id + 1 });
        try std.testing.expectEqual(@as(u64, 1), state.testing_shape.reconnects);
    }
}

// Moved from src/store/mysql_testing.zig: "store.mysql live a batch that loses its connection mid-pass runs every write again"
fn sh2_store_mysql_live_a_batch_that_loses() !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: mt.Store = undefined;
    try mt.openLive(&storage, &tmp);
    defer storage.close() catch {};
    const state = storage.engine.mysql.state;
    const Writer = struct {
        result: anyerror!void = {},
        fn hold() error{}!void {}
        fn write(self: *@This(), s: *mt.Store, id: u64) void {
            self.result = s.queue().write(mt.insertHeld, .{ s, id });
        }
    };
    try storage.queue().callHeld(Writer.hold, .{});
    var writers: [2]Writer = .{ .{}, .{} };
    var threads: [2]std.Thread = undefined;
    for (&threads, &writers, 0..) |*thread, *writer, index| {
        thread.* = try std.Thread.spawn(.{}, Writer.write, .{ writer, &storage, 9000300 + index });
        @import("queue.zig").waitQueued(storage.queue(), index + 1);
    }
    state.testing_drop = .next_pass;
    storage.queue().release();
    for (threads) |thread| thread.join();
    for (writers) |writer| try writer.result;
    try std.testing.expectEqual(@as(u64, 1), state.testing_shape.reconnects);
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectEqual(@as(u64, 2), try mt.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id IN (9000300,9000301)", .{}));
}

// Moved from src/store/mysql_testing.zig: "store.mysql live a write that loses its connection twice fences"
fn sh2_store_mysql_live_a_write_that_loses() !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: mt.Store = undefined;
    try mt.openLive(&storage, &tmp);
    defer storage.close() catch {};
    const state = storage.engine.mysql.state;
    state.testing_drop_armed = true;
    const Twice = struct {
        fn held(s: *mt.Store, id: u64) !void {
            if (!s.engine.mysql.state.armed) s.engine.mysql.state.testing_drop = .next_pass;
            return mt.insertHeld(s, id);
        }
    };
    if (storage.queue().write(Twice.held, .{ &storage, 9000200 })) |_| return error.TestUnexpectedResult else |_| {}
    try std.testing.expect(storage.isFenced());
}

// Moved from src/store/mysql_testing.zig: "store.mysql live GET_LOCK excludes a second Store on the same database"
fn sh27_store_mysql_live_get_lock_excludes_a() !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: mt.Store = undefined;
    try mt.openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    var second: mt.Store = undefined;
    try std.testing.expectError(error.StoreLocked, mt.open(&second, &tmp, std.testing.io, .{}));
    try std.testing.expectEqual(@as(u64, 1), try mt.liveWrite(&storage, mt.live_noop, .{}));
    try std.testing.expect(!storage.isFenced());
}

// Moved from src/store/mysql_testing.zig: "store.mysql live epoch backup fence works while GET_LOCK remains held"
fn sh27_store_mysql_live_epoch_backup_fence_works() !void {
    try mt.liveBackupFence("epoch");
}

// Moved from src/store/mysql_testing.zig: "store.mysql live commit sequence backup fence works while GET_LOCK remains held"
fn sh27_store_mysql_live_commit_sequence_backup_fence() !void {
    try mt.liveBackupFence("commit_seq");
}

// Design C2 and SH-115 on SQLite: a transition whose COMMIT is refused saves nothing it queued, and its caller hears
// the refusal as the SQLite engine's COMMIT error. MySQL has no injected refused COMMIT: its failed COMMITs are lost
// answers, owned by SH-2, so this runs on SQLite alone.
fn sh115_a_transition_s_commit_failure_saves_nothing(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "transition-refused-commit");
    const before: TestingDatingState = try .of(&storage);
    store_testing.failCommits(&storage, true);
    const result = transition.apply(&storage, TestingDating, .{ .session = session.slice(), .revision = 1, .finish = .commit }, .{});
    store_testing.failCommits(&storage, false);
    try std.testing.expectError(error.SqliteExecFailed, result);
    try std.testing.expectEqual(before, try TestingDatingState.of(&storage));
    try std.testing.expect(!storage.engine.inTransaction());
}

const cardinality_one = rsql.Read(.{
    .sql = "SELECT next_position FROM session",
    .Args = struct {},
    .Row = struct { next_position: u64 },
    .cardinality = .one,
});
const cardinality_optional = rsql.Read(.{
    .sql = "SELECT next_position FROM session",
    .Args = struct {},
    .Row = struct { next_position: u64 },
    .cardinality = .optional,
});
const cardinality_at_most = rsql.Read(.{
    .sql = "SELECT next_position FROM session",
    .Args = struct {},
    .Row = struct { next_position: u64 },
    .cardinality = .{ .at_most = 2 },
});
const cardinality_at_most_one = rsql.Read(.{
    .sql = "SELECT next_position FROM session",
    .Args = struct {},
    .Row = struct { next_position: u64 },
    .cardinality = .{ .at_most = 1 },
});
const cardinality_each = rsql.Read(.{
    .sql = "SELECT next_position FROM session",
    .Args = struct {},
    .Row = struct { next_position: u64 },
    .cardinality = .each,
});

// Runs one read through its own Access, so the read's own check decides the answer.
fn runCardinalityRead(storage: *Store, comptime S: type, destination: *S.Result) !void {
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    var a: store_access.Access(.read, error{}) = .open(&entry);
    defer a.deinit();
    a.read(S, .{}, destination);
    try a.run();
}

const CardinalityVisitor = struct {
    visited: u64 = 0,

    pub fn visit(self: *CardinalityVisitor, _: *const cardinality_each.Row) bool {
        self.visited += 1;
        return true;
    }
};

// Owner of SH-116: a read answers the rows its cardinality names and nothing else, on every engine.
fn sh116_a_read_answers_the_rows_its_cardinality_names(case: *store_testing.Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var one: cardinality_one.Result = undefined;
    var optional: cardinality_optional.Result = undefined;
    var at_most: cardinality_at_most.Result = undefined;
    var at_most_one: cardinality_at_most_one.Result = undefined;
    var visitor: CardinalityVisitor = .{};
    // No Session yet: .one needs a row, .optional and .at_most take none, and .each visits none.
    try std.testing.expectError(error.CorruptStore, runCardinalityRead(&storage, cardinality_one, &one));
    try runCardinalityRead(&storage, cardinality_optional, &optional);
    try std.testing.expectEqual(@as(?cardinality_optional.Row, null), optional);
    try runCardinalityRead(&storage, cardinality_at_most, &at_most);
    try std.testing.expectEqual(@as(usize, 0), at_most.len);
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var a: store_access.Access(.read, error{}) = .open(&entry);
        defer a.deinit();
        a.readEach(cardinality_each, .{}, 1, &visitor);
        try a.run();
    }
    try std.testing.expectEqual(@as(u64, 0), visitor.visited);
    // One Session: every cardinality takes its one row.
    _ = try configureTestSession(&storage, "cardinality-one");
    try runCardinalityRead(&storage, cardinality_one, &one);
    try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT next_position FROM session", .{}), one.next_position);
    try runCardinalityRead(&storage, cardinality_optional, &optional);
    try std.testing.expect(optional != null);
    try runCardinalityRead(&storage, cardinality_at_most, &at_most);
    try std.testing.expectEqual(@as(usize, 1), at_most.len);
    // Two Sessions: .one and .optional refuse a second row, .at_most 1 refuses it too, .at_most 2 takes both, and .each's
    // limit stops it at one row.
    _ = try configureTestSession(&storage, "cardinality-two");
    try std.testing.expectError(error.CorruptStore, runCardinalityRead(&storage, cardinality_one, &one));
    try std.testing.expectError(error.CorruptStore, runCardinalityRead(&storage, cardinality_optional, &optional));
    try std.testing.expectError(error.CorruptStore, runCardinalityRead(&storage, cardinality_at_most_one, &at_most_one));
    try runCardinalityRead(&storage, cardinality_at_most, &at_most);
    try std.testing.expectEqual(@as(usize, 2), at_most.len);
    visitor = .{};
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var a: store_access.Access(.read, error{}) = .open(&entry);
        defer a.deinit();
        a.readEach(cardinality_each, .{}, 1, &visitor);
        try a.run();
    }
    try std.testing.expectEqual(@as(u64, 1), visitor.visited);
    try std.testing.expect(!storage.isFenced());
}

test "SH-115 a transition saves nothing it queued when its commit fails" {
    var case: store_testing.Case = .{ .engine = .sqlite };
    try sh115_a_transition_s_commit_failure_saves_nothing(&case);
}

test "SH-116 a read answers the rows its cardinality names and nothing else" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try sh116_a_read_answers_the_rows_its_cardinality_names(case);
        }
    }.run);
}

test "SH-103 a transition saves all it queued when it commits and nothing otherwise" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try sh103_a_transition_s_commit_lands_its_writes(case);
            try sh103_a_transition_that_ends_done_leaves_nothing(case);
            try sh103_a_transition_s_declined_guard_answers_declined(case);
            try sh103_a_transition_s_failure_hook_runs_when(case);
            try sh103_a_transition_s_guard_that_it_does(case);
        }
    }.run);
}

test "SH-5 concurrent commands derive distinct ranks, and a reused savepoint preserves earlier writes" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            if (case.engine == .mysql and !case.rerun) try sh5_store_mysql_live_reused_savepoint_replaces_its();
            if (case.engine == .sqlite) try sh5_store_sqlite_reused_savepoint_nests_its(case);
            try sh5_session_pin_concurrent_commands_derive_distinct_ranks(case);
        }
    }.run);
}

test "SH-104 every value a statement binds reads back equal" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try sh104_model_fact_effort_masks_are_format_defined(case);
            if (case.engine == .mysql and !case.rerun) try sh104_every_args_type_round_trips_through_a();
            if (case.engine == .mysql and !case.rerun) try sh104_optional_args_round_trip_as_null_and();
            if (case.engine == .mysql and !case.rerun) try sh104_text_literals_compare_binary_and_without_padding();
        }
    }.run);
}

test "SH-105 a write commits only when it changes the rows its caller states, and its guard and visitor storage hold" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try sh105_a_counted_write_commits_only_when_it(case);
            if (case.engine == .mysql and !case.rerun) try sh105_store_mysql_live_client_found_rows_counts();
            if (case.engine == .mysql and !case.rerun) try sh105_store_mysql_live_first_access_guard_survives();
        }
    }.run);
    try sh105_an_each_visitor_supplies_storage_for_a();
}

test "SH-106 a pass steps what was queued in rounds of its mode's size, and fills a destination only when it steps it" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try sh105_a_queued_read_s_destination_holds_poison(case);
            try sh105_a_queued_readinto_s_found_is_pending(case);
            try sh105_a_transition_s_round_names_the_failed(case);
            try sh106_a_transition_with_a_wide_pass_steps(case);
            try sh106_a_step_sees_its_transaction_open_once(case);
            try sh106_a_transition_s_paged_round_runs_again(case);
            try sh106_a_transition_s_follow_reads_ride_its(case);
            try sh106_a_transition_s_rounds_before_begin_read(case);
            try sh106_a_success_settlement_sends_its_rows_twenty(case);
        }
    }.run);
}

test "SH-107 content reads back the bytes written, at every size and offset" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try sh107_buffered_payload_boundaries_and_streamed_payloads_preserve(case);
            try sh107_a_content_sink_opens_only_on_a(case);
            try sh107_multiwindow_content_import_and_deduplication_preserve_all(case);
            try sh107_large_raw_content_opens_without_materializing_its(case);
        }
    }.run);
}

test "SH-108 every row a write dates carries its transaction's one second" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try sh108_every_round_of_a_write_access_dates(case);
        }
    }.run);
}

test "SH-3 a read step the engine fails fences the Store" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try sh3_canonical_step_faults_fence_rather_than_reading(case);
            try sh3_a_list_action_step_fault_keeps_its(case);
            try sh3_an_ordinary_outcome_leaves_the_store_serving(case);
        }
    }.run);
}

test "SH-109 every Session whose rows changed is named as touched, and only a change sets the commit wake" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try sh109_the_touch_oracle_names_a_sender_whose(case);
            try sh109_an_access_that_touches_a_fifth_session(case);
            try sh109_the_touch_oracle_names_a_session_whose(case);
            try sh109_an_entry_point_that_changed_rows_sets(case);
            try sh109_each_commit_notifies_the_subscriber_once(case);
            if (case.engine == .mysql and !case.rerun) try sh109_store_mysql_touch_oracle_observes_and_clears();
        }
    }.run);
}

test "SH-110 each Store entry point takes its round budget on its common path on every engine" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try sh110_each_store_entry_point_takes_its_round(case);
        }
    }.run);
}

test "SH-2 a COMMIT whose answer was lost is saved once or not at all, and the caller is told which" {
    if (!try mt.available()) return error.SkipZigTest;
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            if (case.engine == .mysql and !case.rerun) try sh2_store_mysql_live_a_connection_lost_around();
            if (case.engine == .mysql and !case.rerun) try sh2_store_mysql_live_a_reconnect_onto_a();
            if (case.engine == .mysql and !case.rerun) try sh2_store_mysql_live_a_reconnect_never_ends();
            if (case.engine == .mysql and !case.rerun) try sh2_store_mysql_live_a_commit_and_the();
            if (case.engine == .mysql and !case.rerun) try sh2_store_mysql_live_a_connection_lost_after();
            if (case.engine == .mysql and !case.rerun) try sh2_store_mysql_live_a_commit_lost_with();
            if (case.engine == .mysql and !case.rerun) try sh2_store_mysql_live_a_write_whose_connection();
            if (case.engine == .mysql and !case.rerun) try sh2_store_mysql_live_a_batch_that_loses();
            if (case.engine == .mysql and !case.rerun) try sh2_store_mysql_live_a_write_that_loses();
        }
    }.run);
}

test "SH-27 a second owner fences the first before its next write" {
    if (!try mt.available()) return error.SkipZigTest;
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            if (case.engine == .mysql and !case.rerun) try sh27_store_mysql_live_get_lock_excludes_a();
            if (case.engine == .mysql and !case.rerun) try sh27_store_mysql_live_epoch_backup_fence_works();
            if (case.engine == .mysql and !case.rerun) try sh27_store_mysql_live_commit_sequence_backup_fence();
        }
    }.run);
}

// Moved from src/store/tests/historical.zig: "an admission closes the request's view it opened when its commit fails or its settings do not settle".
// The lost-answer fault and the refusing trigger are MySQL's, so SQLite (no connection to lose) and the rerun leg return
// here, as the test did in historical.zig.
fn sh117_an_admission_closes_the_request_s_view(case: *store_testing.Case) !void {
    if (case.engine != .mysql or case.rerun) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "closed-view-config");
    try submitTestMessage(&storage, &tmp, "closed-view-one", "closed-view-one", session.slice(), "one");
    var view: TestingPage = undefined;
    var settings: HistoricalSettings = undefined;

    storage.engine.mysql.state.testing_drop = .after_commit;
    const unread = (try storage.admitModelAttemptInto(.message, .{}, .{ .view = view.pageFor(&storage), .settings = &settings })).?;
    try std.testing.expect(!unread.request_started);
    try std.testing.expect(!view.isActive());
    try settleItemsForTesting(&storage, &tmp, unread.permit.binding, &.{"{\"type\":\"message\",\"id\":\"m0\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}"}, "answer");

    try submitTestMessage(&storage, &tmp, "closed-view-two", "closed-view-two", session.slice(), "two");
    try mt.rawExec(&storage, "CREATE TRIGGER refuse_operation BEFORE INSERT ON model_operation FOR EACH ROW SIGNAL SQLSTATE '45000'");
    defer mt.rawExec(&storage, "DROP TRIGGER refuse_operation") catch @panic("cannot restore Operation inserts");
    if (storage.admitModelAttemptInto(.message, .{}, .{ .view = view.pageFor(&storage), .settings = &settings })) |_| return error.TestUnexpectedResult else |_| {}
    try std.testing.expect(!view.isActive());
}

test "SH-117 an admission closes the request's view it opened when its COMMIT answer is lost or its Operation insert is refused" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try sh117_an_admission_closes_the_request_s_view(case);
        }
    }.run);
}
