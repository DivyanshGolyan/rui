const std = @import("std");
const protocol = @import("../protocol.zig");
const SessionPinReply = @import("../command_reply.zig").SessionPinReply;
const store_core = @import("Store.zig");
pub const Store = store_core.Store;
const testing = @import("testing.zig");
const fixtures = @import("tests.zig");

pub fn command(key: []const u8, session: []const u8, pinned: bool) !protocol.SessionPinCommand {
    var result: protocol.SessionPinCommand = .{ .pinned = pinned };
    try result.key.set(key);
    try result.session.set(session);
    return result;
}

pub fn order(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8) !?u64 {
    var used: std.atomic.Value(u64) = .init(0);
    const bytes = try fixtures.testingSessionList(storage, tmp, .{ .archive = .all }, &used, 1);
    defer std.testing.allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    for (parsed.value.object.get("sessions").?.array.items) |row| {
        if (!std.mem.eql(u8, row.object.get("reference").?.string, session)) continue;
        const rank = row.object.get("pin_order").?;
        return if (rank == .null) null else try std.fmt.parseInt(u64, rank.string, 10);
    }
    return error.TestMissingSession;
}

pub fn expectAccepted(reply: SessionPinReply, pinned: bool, replayed: bool) !void {
    try std.testing.expect(reply == .accepted);
    try std.testing.expectEqual(pinned, reply.accepted.pinned);
    try std.testing.expectEqual(replayed, reply.accepted.replayed);
}

test "Session pin preserves first rank and historical replay through unpin archive and reopen" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            var opened = true;
            defer if (opened) storage.close() catch unreachable;
            const first = try testing.configureTestSession(&storage, "pin-first-config");
            const second = try testing.configureTestSession(&storage, "pin-second-config");
            const before = try storage.inspectSessionForTesting(first.slice());
            const before_position = try testing.queryU64(&storage, "SELECT next_position FROM session WHERE session_ref=?1", .{first.slice()});
            var no_op = try command("pin-absent-unpin", first.slice(), false);
            try expectAccepted(storage.pinSession(&no_op, .{}), false, false);
            try std.testing.expectEqual(@as(?u64, null), try order(&storage, &tmp, first.slice()));
            var pin = try command("pin-first", first.slice(), true);
            try expectAccepted(storage.pinSession(&pin, .{}), true, false);
            const first_pin_order = try order(&storage, &tmp, first.slice());
            if (first_pin_order == null) std.debug.print("pinning oracle: first accepted pin has no current pin_order\n", .{});
            try std.testing.expect(first_pin_order != null);
            const rank = (try order(&storage, &tmp, first.slice())).?;
            var other = try command("pin-second", second.slice(), true);
            try expectAccepted(storage.pinSession(&other, .{}), true, false);
            const other_rank = (try order(&storage, &tmp, second.slice())).?;
            try std.testing.expect(other_rank > rank);
            var repeated = try command("pin-first-fresh-key", first.slice(), true);
            try expectAccepted(storage.pinSession(&repeated, .{}), true, false);
            try std.testing.expectEqual(rank, (try order(&storage, &tmp, first.slice())).?);
            const after = try storage.inspectSessionForTesting(first.slice());
            try std.testing.expectEqual(before.revision, after.revision);
            try std.testing.expectEqual(before_position, try testing.queryU64(&storage, "SELECT next_position FROM session WHERE session_ref=?1", .{first.slice()}));
            var unpin = try command("pin-first-unpin", first.slice(), false);
            try expectAccepted(storage.pinSession(&unpin, .{}), false, false);
            try expectAccepted(storage.pinSession(&pin, .{}), true, true);
            try std.testing.expectEqual(@as(?u64, null), try order(&storage, &tmp, first.slice()));
            pin.pinned = false;
            try std.testing.expect(storage.pinSession(&pin, .{}) == .conflict);
            pin.pinned = true;
            pin.session = second;
            try std.testing.expect(storage.pinSession(&pin, .{}) == .conflict);
            pin.session = first;
            repeated = try command("pin-first-repin", first.slice(), true);
            try expectAccepted(storage.pinSession(&repeated, .{}), true, false);
            const new_rank = (try order(&storage, &tmp, first.slice())).?;
            try std.testing.expect(new_rank > other_rank);
            var stop = try fixtures.completeSessionStop("pin-ordinary-stop", first.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try std.testing.expectEqual(new_rank, (try order(&storage, &tmp, first.slice())).?);
            var archive: protocol.SessionArchiveCommand = .{};
            try archive.key.set("pin-archive");
            archive.session = first;
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            try std.testing.expectEqual(@as(?u64, null), try order(&storage, &tmp, first.slice()));
            try expectAccepted(storage.pinSession(&pin, .{}), true, true);
            try std.testing.expectEqual(@as(?u64, null), try order(&storage, &tmp, first.slice()));
            var archived_pin = try command("pin-archived-refused", first.slice(), true);
            try std.testing.expectEqual(protocol.SessionPinRejection.session_archived, storage.pinSession(&archived_pin, .{}).rejected.code);
            no_op = try command("pin-archived-unpin", first.slice(), false);
            try expectAccepted(storage.pinSession(&no_op, .{}), false, false);
            archive.archived = false;
            try archive.key.set("pin-restore");
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            try std.testing.expectEqual(@as(?u64, null), try order(&storage, &tmp, first.slice()));
            try storage.close();
            opened = false;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            opened = true;
            try std.testing.expectEqual(@as(?u64, null), try order(&storage, &tmp, first.slice()));
            try std.testing.expectEqual(other_rank, (try order(&storage, &tmp, second.slice())).?);
            try expectAccepted(storage.pinSession(&pin, .{}), true, true);
            try std.testing.expectEqual(@as(?u64, null), try order(&storage, &tmp, first.slice()));
            const observed = try testing.observeCommandForTesting(&storage, pin.key.slice());
            try std.testing.expect(observed.kind.session_pin.?.pinned);
            var unknown = try command("pin-unknown", "zzzzzz", true);
            try std.testing.expectEqual(protocol.SessionPinRejection.unknown_session, storage.pinSession(&unknown, .{}).rejected.code);
            unknown.pinned = false;
            try unknown.key.set("unpin-unknown");
            try std.testing.expectEqual(protocol.SessionPinRejection.unknown_session, storage.pinSession(&unknown, .{}).rejected.code);
        }
    }.run);
}

test "Session pin-only commits appear in changed listing without changing creation pagination" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var ids: [protocol.session_list_page_size + 1]protocol.Bounded(protocol.max_session_bytes) = undefined;
            for (&ids, 0..) |*id, index| {
                var key: [32]u8 = undefined;
                id.* = try testing.configureTestSession(&storage, try std.fmt.bufPrint(&key, "pin-page-{d}", .{index}));
            }
            const initial = try fixtures.TestingListing.read(&storage, &tmp, .{});
            var pin = try command("pin-page-last", ids[ids.len - 1].slice(), true);
            try expectAccepted(storage.pinSession(&pin, .{}), true, false);
            const next = try fixtures.TestingListing.read(&storage, &tmp, initial.next.?);
            try next.expectReferences(&.{ids[ids.len - 1].slice()[0..protocol.session_id_bytes].*});
            const changed = try fixtures.TestingListing.read(&storage, &tmp, .{ .since = initial.since });
            try std.testing.expectEqual(protocol.ListDelta.changed, changed.delta);
            try changed.expectReferences(&.{ids[ids.len - 1].slice()[0..protocol.session_id_bytes].*});
            pin.pinned = false;
            try pin.key.set("pin-page-unpin");
            try expectAccepted(storage.pinSession(&pin, .{}), false, false);
            const unpinned = try fixtures.TestingListing.read(&storage, &tmp, .{ .since = changed.since });
            try unpinned.expectReferences(&.{ids[ids.len - 1].slice()[0..protocol.session_id_bytes].*});
        }
    }.run);
}

test "Session pin failed commit rolls back command and current pin together" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            var opened = true;
            defer if (opened) storage.close() catch unreachable;
            const session = try testing.configureTestSession(&storage, "pin-fault-config");
            var pin = try command("pin-fault", session.slice(), true);
            try std.testing.expect(storage.pinSession(&pin, .{ .before_commit = true }) == .infrastructure_failure);
            try storage.close();
            opened = false;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            opened = true;
            try std.testing.expectEqual(@as(?u64, null), try order(&storage, &tmp, session.slice()));
            const observed = try testing.observeCommandForTesting(&storage, pin.key.slice());
            try std.testing.expectEqual(protocol.CommandObservationStatus.absent, observed.status);
            try expectAccepted(storage.pinSession(&pin, .{}), true, false);
        }
    }.run);
}
