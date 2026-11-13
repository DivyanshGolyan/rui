//! Access Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const change_ring = @import("../../change_ring.zig");
const store_core = @import("../Store.zig");
const store_access = @import("../access.zig");
const rsql = @import("../rsql.zig");
const Store = store_core.Store;
const configuration_domain = @import("../domain/configuration.zig");
const historical_domain = @import("../domain/historical.zig");
const store_schema = @import("../schema.zig");
const store_testing = @import("../testing.zig");
const HistoricalView = historical_domain.HistoricalView;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const TestingRound = shared_fixtures.TestingRound;
const openCheckedView = shared_fixtures.openCheckedView;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const touchForTesting = shared_fixtures.touchForTesting;

test "buffered payload boundaries and streamed payloads preserve the same bytes under queue pressure" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
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
            // Nonuniform bytes expose chunk-index and boundary mistakes.
            for (source, 0..) |*byte, i| byte.* = @truncate(i *% 31 + i / chunk);
            var window: [4093]u8 = undefined;
            for ([_]usize{ 0, 1, chunk - 1, chunk, chunk + 1, 3 * chunk + 17, source.len }) |length| {
                const bytes = source[0..length];
                const entry = try store_core.enter(&storage, .none);
                defer entry.release();
                var a: store_access.Access(.write, error{}) = .open(&entry);
                defer a.deinit();
                errdefer a.abandon(.{}) catch {};
                var ids: [2]u64 = undefined;
                for (&ids, 0..) |*id, method| {
                    id.* = try a.identity(.content_id);
                    // A fixture key distinct from built-in empty content;
                    // this test exercises raw bytes, not content admission.
                    a.write(insert, .{ .id = id.*, .digest = protocol.contentDigest("adapter parity fixture"), .length = length, .private = method == 1 });
                    if (method == 0) {
                        // Existing writeContent callers need not record a
                        // row or open the public sink to lower their bytes.
                        a.writeContent(id.*, bytes);
                    } else {
                        a.recordContentRow(id.*);
                        const sink = try a.contentSink(id.*, length);
                        defer sink.close();
                        var at: usize = 0;
                        while (at < length) {
                            const n = @min(window.len, length - at);
                            try sink.write(bytes[at..][0..n], at);
                            at += n;
                        }
                    }
                }
                try a.commit();
                // Read bounded windows through the adapter, across every
                // boundary, rather than trusting row counts or digests.
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
    }.run);
}

test "a content sink opens only on a content row its Access itself queued, in the same round" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "sink-config");
            // A row a committed configure inserted, not this Access.
            const existing: u64 = @intCast((try store_core.readSessionForTesting(&storage, session.slice())).?.instructions_id.?);

            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            var a: store_access.Access(.write, error{}) = .open(&entry);
            defer a.deinit();
            // Opens the transaction, so the next id is taken in it, before this
            // Access takes any.
            _ = try a.identity(.turn_id);
            const before = try store_core.takeIdentity(&storage, .content_id);
            // Distinct identities, since content is unique by identity.
            const digests = [3][32]u8{ protocol.contentDigest("sink0"), protocol.contentDigest("sink1"), protocol.contentDigest("sink2") };
            a.write(TestingRound.insert_content, .{ .content_id = before, .digest = digests[0], .length = 4 });
            const first = try a.identity(.content_id);
            a.write(TestingRound.insert_content, .{ .content_id = first, .digest = digests[1], .length = 4 });
            a.recordContentRow(first);
            // Taken outside this Access between its own ids: inside the range of
            // the ids it took, but not its own.
            const between = try store_core.takeIdentity(&storage, .content_id);
            const never = try a.identity(.content_id);
            const last = try a.identity(.content_id);
            a.write(TestingRound.insert_content, .{ .content_id = last, .digest = digests[2], .length = 4 });
            a.recordContentRow(last);
            try std.testing.expectEqual(first + 3, last);
            // Refused: 0, a committed row, one taken in this transaction before
            // this Access's first, one other code took between its own, and one
            // past its last. A check of the range from its first id to its last
            // accepted `between`.
            try std.testing.expectError(error.ContentNotInserted, a.contentSink(0, 4));
            try std.testing.expectError(error.ContentNotInserted, a.contentSink(existing, 4));
            try std.testing.expectError(error.ContentNotInserted, a.contentSink(before, 4));
            try std.testing.expectError(error.ContentNotInserted, a.contentSink(between, 4));
            try std.testing.expectError(error.ContentNotInserted, a.contentSink(last + 1, 4));
            // The first id opens while its insert is still queued: SQLite
            // steps it for the blob handle, while MySQL queues the chunk
            // behind it, so one round runs both.
            const sink = try a.contentSink(first, 4);
            try sink.write("sink", 0);
            sink.close();
            try a.run();
            try std.testing.expectEqual(0, a.queued);
            const again = try a.contentSink(last, 4);
            again.close();
            // Taken but never inserted: there is no row to open.
            try std.testing.expectError(error.ContentWriteFailed, a.contentSink(never, 4));
            try a.abandon(.{});
        }
    }.run);
}

test "a queued read's destination holds poison until the pass that steps it" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
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
            // Overflow the queue to force an automatic pass on every engine.
            // SQLite may step earlier on rebind; MySQL has no cached handles.
            var fillers: [a.queue.len - 1]TestingRound.head.Result = undefined;
            for (&fillers) |*filler| a.read(TestingRound.head, .{ .session_ref = session.slice() }, filler);
            a.read(TestingRound.head, .{ .session_ref = session.slice() }, &second);
            try std.testing.expect(!poisoned(std.mem.asBytes(&first)));
            try std.testing.expectEqualSlices(u8, session.slice(), &first.head.ref);
            try std.testing.expect(poisoned(std.mem.asBytes(&second)));
            try a.run();
            try std.testing.expectEqualSlices(u8, session.slice(), &second.head.ref);
        }
    }.run);
}

test "a queued readInto's Found is pending until the pass that steps it" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
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
            // A bool here held 0xAA, which reads as true: found before any step.
            var found: store_access.Found = .missing;
            var missing: store_access.Found = .found;
            configuration_domain.readSaved(&a, session.slice(), &current, &found);
            try std.testing.expectEqual(store_access.Found.pending, found);
            // Fill with small rows in distinct stable destinations, rather
            // than copying the 4.6 KiB configuration Row for every queue slot.
            // Overflow forces a pass even without SQLite's rebind boundary.
            var fillers: [a.queue.len - 1]TestingRound.head.Result = undefined;
            for (&fillers) |*filler| a.read(TestingRound.head, .{ .session_ref = session.slice() }, filler);
            configuration_domain.readSaved(&a, "AAAAAA", &missing_current, &missing);
            try std.testing.expectEqual(store_access.Found.found, found);
            try std.testing.expectEqual(store_access.Found.pending, missing);
            try a.run();
            try std.testing.expect(found.get());
            try std.testing.expect(!missing.get());
        }
    }.run);
}

test "the touch oracle names a sender whose sent Message changed without its touch" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const recipient = try configureTestSession(&storage, "oracle-recipient");
            const sender = try configureTestSession(&storage, "oracle-sender");
            try submitTestMessage(&storage, &tmp, "oracle-message-file", "oracle-message", recipient.slice(), "hello");
            {
                // Make the Message a sent one, touching both its Sessions.
                const entry = try store_core.enter(&storage, .none);
                defer entry.release();
                try store_testing.exec(&storage, "UPDATE message_admission SET sender_session_ref=?1,sender_position=1000000 WHERE command_key='oracle-message'", .{sender.slice()});
                try std.testing.expectEqualStrings(sender.slice(), &store_core.untouchedForTesting(&storage).?);
                try touchForTesting(&storage, recipient.slice());
                try touchForTesting(&storage, sender.slice());
                try std.testing.expect(store_core.untouchedForTesting(&storage) == null);
            }
            {
                const entry = try store_core.enter(&storage, .none);
                defer entry.release();
                try touchForTesting(&storage, recipient.slice());
                // A column only the recipient reads.
                try store_testing.exec(&storage, "UPDATE message_admission SET turn_id=NULL WHERE command_key='oracle-message'", .{});
                try std.testing.expect(store_core.untouchedForTesting(&storage) == null);
                // A hand-written writer that changes what the sender's page reads
                // and skips the sender.
                try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=admitted_at+1 WHERE command_key='oracle-message'", .{});
                try std.testing.expectEqualStrings(sender.slice(), &store_core.untouchedForTesting(&storage).?);
                try touchForTesting(&storage, sender.slice());
                try std.testing.expect(store_core.untouchedForTesting(&storage) == null);
            }
        }
    }.run);
}

test "an Access that touches a fifth Session records everything and still commits" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var sessions: [5]protocol.Bounded(protocol.max_session_bytes) = undefined;
            inline for (&sessions, .{ "five-a", "five-b", "five-c", "five-d", "five-e" }) |*session, key| session.* = try configureTestSession(&storage, key);

            const Five = struct {
                fn body(a: anytype, all: []const protocol.Bounded(protocol.max_session_bytes)) !void {
                    for (all) |session| {
                        var loaded: TestingRound.head.Result = undefined;
                        a.read(TestingRound.head, .{ .session_ref = session.slice() }, &loaded);
                        try a.run();
                        a.write(TestingRound.date_session, .{ .session = loaded.head, .revision = 1 });
                        try a.run();
                    }
                    try a.commit();
                }
            };
            {
                const entry = try store_core.enter(&storage, .none);
                defer entry.release();
                var a: store_access.Access(.write, error{TestingGuard}) = .open(&entry);
                defer a.deinit();
                try entry.finishTransaction(error{TestingGuard}, .{}, a.end(.{}, Five.body(&a, &sessions)));
            }
            try std.testing.expect(storage.touched.everything);
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(DISTINCT created_at) FROM session", .{}));
        }
    }.run);
}

test "every round of a write Access dates its rows with the transaction's second" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // The Store reads the wall clock through its io; this one runs
            // ahead by `ahead` instead of waiting for the next second.
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
            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            var a: store_access.Access(.write, error{TestingGuard}) = .open(&entry);
            defer a.deinit();
            var heads: [2]TestingRound.head.Result = undefined;
            a.read(TestingRound.head, .{ .session_ref = first.slice() }, &heads[0]);
            a.read(TestingRound.head, .{ .session_ref = second.slice() }, &heads[1]);
            try a.run();
            a.write(TestingRound.date_session, .{ .session = heads[0].head, .revision = 1 });
            try a.run();
            const dated = try store_core.transactionSecond(&storage);
            // The clock moves on to a later second before the next round dates.
            Clock.ahead = .fromSeconds(1);
            try std.testing.expect(@divFloor(try store_core.readUnixMilliseconds(io), 1000) > dated);
            a.write(TestingRound.date_session, .{ .session = heads[1].head, .revision = 1 });
            try a.commit();
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(DISTINCT created_at) FROM session", .{}));
            try std.testing.expectEqual(@as(u64, @intCast(dated)), try store_testing.queryU64(&storage, "SELECT max(created_at) FROM session", .{}));
            // Commit cleared it: the next transaction reads the clock again.
            try store_core.begin(&storage);
            try std.testing.expect(try store_core.transactionSecond(&storage) > dated);
            try store_core.rollbackAfterError(&storage, .{});
        }
    }.run);
}

test "an Access commits its writes, positions and identities together, or none of them" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "round-config");
            const next_sql = "SELECT next_position FROM session";
            const position = try store_testing.queryU64(&storage, next_sql, .{});
            const contents = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
            const content_id = storage.identities().next.get(.content_id);

            // A failed guard stops the round before COMMIT: no row, position or id stays.
            try std.testing.expectError(error.TestingGuard, TestingRound.change(&storage, session.slice(), "round rolled back", 99));
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectEqual(position, try store_testing.queryU64(&storage, next_sql, .{}));
            try std.testing.expectEqual(contents, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
            try std.testing.expectEqual(content_id, storage.identities().next.get(.content_id));

            const before = @divFloor(try store_core.readUnixMilliseconds(std.testing.io), 1000);
            try std.testing.expectEqual(position, try TestingRound.change(&storage, session.slice(), "round committed", 1));
            const after = @divFloor(try store_core.readUnixMilliseconds(std.testing.io), 1000);
            try std.testing.expectEqual(position + 2, try store_testing.queryU64(&storage, next_sql, .{}));
            try std.testing.expectEqual(content_id, try store_testing.queryU64(&storage, "SELECT content_id FROM content WHERE byte_length=15 AND private=0 AND digest=?1", .{store_testing.Blob{ .bytes = &protocol.contentDigest("round committed") }}));
            const dated: i64 = @intCast(try store_testing.queryU64(&storage, "SELECT created_at FROM session", .{}));
            try std.testing.expect(before <= dated and dated <= after);
        }
    }.run);
}

const counted_dating = rsql.Write(.{
    .sql = "UPDATE session SET created_at=?2 WHERE session_ref=@session(?1) AND revision=?3",
    .Args = struct { session: rsql.SessionHead, at: u64, revision: u64 },
    .expect = .{ .counted = .{ .otherwise = error.TestingGuard } },
});

/// Dates `session` at `at` where its revision is `revision`, stating
/// `rows` as the rows that write changes.
fn countedDatingForTesting(storage: *Store, session: []const u8, at: u64, revision: u64, rows: u64) !void {
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    var a: store_access.Access(.write, error{TestingGuard}) = .open(&entry);
    defer a.deinit();
    return entry.finishTransaction(error{TestingGuard}, .{}, a.end(.{}, struct {
        fn body(access: anytype, ref: []const u8, value: u64, current: u64, count: u64) !void {
            var loaded: TestingRound.head.Result = undefined;
            access.read(TestingRound.head, .{ .session_ref = ref }, &loaded);
            try access.run();
            access.writeCount(counted_dating, .{ .session = loaded.head, .at = value, .revision = current }, count);
            try access.commit();
        }
    }.body(&a, session, at, revision, rows)));
}

test "a counted write commits only when it changes the rows its caller states" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "counted-config");
            const dated = "SELECT created_at FROM session";
            const created = try store_testing.queryU64(&storage, dated, .{});
            // One row changes: stating none or two fails before COMMIT.
            for ([_]u64{ 0, 2 }) |rows| {
                try std.testing.expectError(error.TestingGuard, countedDatingForTesting(&storage, session.slice(), 7, 1, rows));
                try std.testing.expectEqual(created, try store_testing.queryU64(&storage, dated, .{}));
            }
            try std.testing.expect(!storage.isFenced());
            try countedDatingForTesting(&storage, session.slice(), 7, 1, 1);
            try std.testing.expectEqual(@as(u64, 7), try store_testing.queryU64(&storage, dated, .{}));
            // No row changes: zero is checked like any count.
            try std.testing.expectError(error.TestingGuard, countedDatingForTesting(&storage, session.slice(), 8, 2, 1));
            try countedDatingForTesting(&storage, session.slice(), 8, 2, 0);
            try std.testing.expectEqual(@as(u64, 7), try store_testing.queryU64(&storage, dated, .{}));
        }
    }.run);
}

test "the touch oracle names a Session whose rows changed without a touch" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
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
                // A writer that forgets its touch.
                try store_testing.exec(&storage, "UPDATE session SET label='forgot' WHERE session_ref=?1", .{session});
                try std.testing.expectEqualStrings(session, &store_core.untouchedForTesting(&storage).?);
                try touchForTesting(&storage, session);
                try std.testing.expect(store_core.untouchedForTesting(&storage) == null);
            }
            // The touched write is recorded under the generation it advanced to.
            try std.testing.expectEqual(generation + 1, storage.commit_generation.load(.acquire));
            var out: [1]change_ring.Id = undefined;
            try std.testing.expectEqualStrings(session, &storage.changes.changed(generation, generation + 1, null, null, &out)[0]);
        }
    }.run);
}

test "canonical step faults fence rather than reading as ordinary misses" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
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
                        var view: HistoricalView = undefined;
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
                // Before the Store owned classification these were ResultNotFound or
                // StaleAttemptBinding: ordinary outcomes that left the Store usable.
                // The view's settings round also reads by a named index, which
                // SQLite cannot prepare against the stand-in view.
                const unprepared = route == .view and storage.engine == .sqlite;
                try std.testing.expectError(if (route == .result) error.ResultReadFailed else if (unprepared) error.StatementPrepareFailed else error.OperationReadFailed, result);
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

test "an entry point that changed rows sets the commit wake, and a read leaves it unset" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var wake: std.Io.Event = .unset;
            storage.commitWake().store(&wake, .release);
            defer storage.commitWake().store(null, .release);
            _ = try storage.dispatchWork(false);
            try std.testing.expect(!wake.isSet());
            _ = try configureTestSession(&storage, "wake-config");
            try std.testing.expect(wake.isSet());
        }
    }.run);
}

test "an .each visitor supplies storage for a big Row through decoded" {
    const Big = struct { bytes: [1025]u8 };
    const Small = struct { id: u64 };
    try std.testing.expectEqual(@as(?[]const u8, null), comptime store_access.eachVisitorError(Small, struct { count: u8 }));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime store_access.eachVisitorError(Big, struct { decoded: Big }));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime store_access.eachVisitorError(Big, struct { decoded: *Big }));
    try std.testing.expectEqualStrings("rsql: an .each Row over 1 KiB decodes into its visitor's own decoded field", comptime store_access.eachVisitorError(Big, struct { count: u8 }).?);
    try std.testing.expectEqualStrings("rsql: a visitor's decoded field is the Row or *Row its .each read decodes, " ++ @typeName(Small), comptime store_access.eachVisitorError(Small, struct { decoded: Big }).?);
}
