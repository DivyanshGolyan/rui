const std = @import("std");
const group = @import("../session_group.zig");
const command_input = @import("../command_input.zig");
const mutation_answer = @import("../mutation_answer.zig");
const protocol = @import("../protocol.zig");
const listing = @import("../session_list.zig");
const Store = @import("Store.zig").Store;
const testing = @import("testing.zig");
const fixtures = @import("tests.zig");

fn command(key: []const u8, session: []const u8, action: group.Action) !command_input.SessionGroupCommand {
    var result: command_input.SessionGroupCommand = .{ .action = action };
    try result.key.set(key);
    try result.session.set(session);
    return result;
}

const Saved = struct { group: ?group.Brief = null, manual: bool = false, found: bool = false };

fn saved(storage: *Store, reference: []const u8) !Saved {
    const Visitor = struct {
        reference: []const u8,
        value: Saved = .{},
        next: ?struct { after: u64, ceiling: u64 } = null,
        pub fn head(_: *@This()) !void {}
        pub fn row(self: *@This(), value: *const listing.Row) !void {
            if (std.mem.eql(u8, value.reference, self.reference)) self.value = .{ .group = value.group, .manual = value.group_manual, .found = true };
        }
        pub fn tail(self: *@This(), value: listing.Tail) !void {
            self.next = switch (value) {
                .full => |page| .{ .after = page.after, .ceiling = page.ceiling },
                else => null,
            };
        }
    };
    var visitor: Visitor = .{ .reference = reference };
    var request: listing.ListSessions = .{ .archive = .all };
    while (true) {
        try storage.readSessionList(&request, &visitor);
        if (visitor.next) |next| {
            request.after = next.after;
            request.ceiling = next.ceiling;
        } else break;
    }
    if (!visitor.value.found) return error.SessionMissingFromListing;
    return visitor.value;
}

fn accepted(storage: *Store, key: []const u8, session: []const u8, action: group.Action) !void {
    var edit = try command(key, session, action);
    const reply = storage.groupSession(&edit, .{});
    try std.testing.expect(reply == .accepted);
    try std.testing.expect(!reply.accepted.replayed);
}

fn create(storage: *Store, key: []const u8, parent: ?[]const u8, label: ?[]const u8) !protocol.Bounded(protocol.max_session_bytes) {
    var path: [protocol.max_workspace_bytes]u8 = undefined;
    var input = try testing.completeConfiguration(key, "", try testing.canonicalCwd(std.testing.io, &path), "model-a");
    if (parent) |reference| {
        input.configuration.parent.state = .value;
        try input.configuration.parent.value.set(reference);
        input.configuration.workspace.state = .omitted;
        input.configuration.provider.state = .omitted;
        input.configuration.tools = try .of(&.{});
        try input.configuration.permission_mode.value.set("ask");
    }
    if (label) |name| {
        input.configuration.label.state = .value;
        try input.configuration.label.value.set(name);
    }
    const reply = try storage.configure(&input, .{});
    if (reply != .accepted) {
        std.debug.print("group fixture Configure {s} failed: {any}\n", .{ key, reply });
        return error.GroupFixtureConfigurationRejected;
    }
    return reply.accepted.session;
}

fn relabel(storage: *Store, key: []const u8, reference: []const u8, label: []const u8) !void {
    var input: @import("../wire_request.zig").ConfigureCommand = .{};
    try input.key.set(key);
    try input.session.set(reference);
    input.configuration.label.state = .value;
    try input.configuration.label.value.set(label);
    try std.testing.expect((try storage.configure(&input, .{})) == .accepted);
}

test "session group manual moves leaves and reset persist through replay and reopen" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            var opened = true;
            defer if (opened) storage.close() catch unreachable;
            const parent = try create(&storage, "group-parent", null, null);
            const child = try create(&storage, "group-child", parent.slice(), null);
            const family = (try saved(&storage, parent.slice())).group.?;
            try std.testing.expectEqual(family.id, (try saved(&storage, child.slice())).group.?.id);
            const named = try group.Name.from("Deliberate work");
            try accepted(&storage, "group-move", child.slice(), .{ .assign = named });
            const manual = try saved(&storage, child.slice());
            try std.testing.expect(manual.manual and manual.group != null);
            try std.testing.expect(manual.group.?.name.eql(named.slice()));
            try std.testing.expect(manual.group.?.id != family.id);
            try accepted(&storage, "group-parent-leave", parent.slice(), .leave);
            const next = try create(&storage, "group-after-leave", parent.slice(), "Storage migration repair");
            try std.testing.expect((try saved(&storage, next.slice())).group == null);
            try std.testing.expectEqual(manual.group.?.id, (try saved(&storage, child.slice())).group.?.id);
            try accepted(&storage, "group-child-leave", child.slice(), .leave);
            try relabel(&storage, "group-child-label", child.slice(), "Storage migration repair");
            try std.testing.expect((try saved(&storage, child.slice())).group == null);
            var replay = try command("group-move", child.slice(), .{ .assign = named });
            const historical = storage.groupSession(&replay, .{});
            try std.testing.expect(historical == .accepted and historical.accepted.replayed);
            try std.testing.expect((try saved(&storage, child.slice())).group == null);
            replay.action = .leave;
            try std.testing.expect(storage.groupSession(&replay, .{}) == .conflict);
            try storage.close();
            opened = false;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            opened = true;
            const kept = try saved(&storage, child.slice());
            try std.testing.expect(kept.manual and kept.group == null);
            try accepted(&storage, "group-child-reset", child.slice(), .automatic);
            const reset = try saved(&storage, child.slice());
            try std.testing.expect(!reset.manual and reset.group == null);
            const observed = try testing.observeCommandForTesting(&storage, "group-child-reset");
            try std.testing.expect(observed.kind == .session_group);
            try accepted(&storage, "group-same-value-manual", next.slice(), .leave);
            try std.testing.expect((try saved(&storage, next.slice())).manual);
        }
    }.run);
}

test "session group first label topic placement metadata and pagination remain durable" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var ids: [listing.session_list_page_size + 2]protocol.Bounded(protocol.max_session_bytes) = undefined;
            for (&ids, 0..) |*id, index| {
                var key: [40]u8 = undefined;
                id.* = try create(&storage, try std.fmt.bufPrint(&key, "group-page-{d}", .{index}), null, null);
            }
            try relabel(&storage, "group-topic-first", ids[0].slice(), "Fix SQLite migration");
            try relabel(&storage, "group-topic-second", ids[ids.len - 1].slice(), "SQLite migration tests");
            const first = (try saved(&storage, ids[0].slice())).group.?;
            try std.testing.expectEqual(first.id, (try saved(&storage, ids[ids.len - 1].slice())).group.?.id);
            try relabel(&storage, "group-topic-stable", ids[0].slice(), "Unrelated transport request");
            try std.testing.expectEqual(first.id, (try saved(&storage, ids[0].slice())).group.?.id);
            const initial = try fixtures.TestingListing.read(&storage, &tmp, .{});
            const renamed = try group.Name.from("Saved migration work");
            try accepted(&storage, "group-rename", ids[0].slice(), .{ .rename = .{ .group = first.id, .name = renamed } });
            try accepted(&storage, "group-collapse", ids[0].slice(), .{ .collapse = .{ .group = first.id, .collapsed = true } });
            const changed = try fixtures.TestingListing.read(&storage, &tmp, .{ .since = initial.since });
            try std.testing.expect(changed.delta == .full);
            const brief = (try saved(&storage, ids[ids.len - 1].slice())).group.?;
            try std.testing.expect(brief.collapsed and brief.name.eql(renamed.slice()));
            try std.testing.expectEqual(first.revision + 2, brief.revision);
            try accepted(&storage, "group-collapse-again", ids[0].slice(), .{ .collapse = .{ .group = first.id, .collapsed = true } });
            try std.testing.expectEqual(brief.revision, (try saved(&storage, ids[0].slice())).group.?.revision);
            try accepted(&storage, "group-rename-same", ids[0].slice(), .{ .rename = .{ .group = first.id, .name = renamed } });
            try accepted(&storage, "group-current-rename-same", ids[0].slice(), .{ .rename_current = renamed });
            try std.testing.expectEqual(brief.revision, (try saved(&storage, ids[0].slice())).group.?.revision);
            var archive: protocol.SessionArchiveCommand = .{};
            try archive.key.set("group-archive");
            archive.session = ids[0];
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            try std.testing.expectEqual(first.id, (try saved(&storage, ids[0].slice())).group.?.id);
            archive.archived = false;
            try archive.key.set("group-restore");
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            try std.testing.expectEqual(first.id, (try saved(&storage, ids[0].slice())).group.?.id);
        }
    }.run);
}

test "session group invalid edits reject atomically and preserve names" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try create(&storage, "group-error-session", null, null);
            const other = try create(&storage, "group-error-other", null, null);
            try accepted(&storage, "group-name-one", session.slice(), .{ .assign = try .from("First") });
            try accepted(&storage, "group-name-two", other.slice(), .{ .assign = try .from("Second") });
            const id = (try saved(&storage, session.slice())).group.?.id;
            const Case = struct { key: []const u8, session: []const u8, action: group.Action, code: mutation_answer.SessionGroupRejection };
            const cases = [_]Case{
                .{ .key = "group-bad-name", .session = session.slice(), .action = .{ .assign = try .from(" ") }, .code = .invalid_group_name },
                .{ .key = "group-current-bad-name", .session = session.slice(), .action = .{ .rename_current = try .from(" ") }, .code = .invalid_group_name },
                .{ .key = "group-current-duplicate", .session = session.slice(), .action = .{ .rename_current = try .from("Second") }, .code = .group_name_exists },
                .{ .key = "group-bad-id", .session = session.slice(), .action = .{ .collapse = .{ .group = 0, .collapsed = true } }, .code = .invalid_group_id },
                .{ .key = "group-missing", .session = session.slice(), .action = .{ .collapse = .{ .group = std.math.maxInt(i64), .collapsed = true } }, .code = .unknown_group },
                .{ .key = "group-duplicate", .session = session.slice(), .action = .{ .rename = .{ .group = id, .name = try .from("Second") } }, .code = .group_name_exists },
                .{ .key = "group-session-missing", .session = "zzzzzz", .action = .leave, .code = .unknown_session },
                .{ .key = "group-session-invalid", .session = "INVALID", .action = .leave, .code = .invalid_session_reference },
            };
            for (cases) |value| {
                var edit = try command(value.key, value.session, value.action);
                const reply = storage.groupSession(&edit, .{});
                try std.testing.expect(reply == .rejected);
                try std.testing.expectEqual(value.code, reply.rejected.code);
                const replay = storage.groupSession(&edit, .{});
                try std.testing.expect(replay == .rejected and replay.rejected.replayed);
                try std.testing.expectEqual(value.code, replay.rejected.code);
            }
            try std.testing.expect((try saved(&storage, session.slice())).group.?.name.eql("First"));
        }
    }.run);
}

test "session group detached and attached agent starts share creator grouping without changing parentage" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            for ([_]bool{ false, true }) |attached| for ([_]bool{ false, true }) |reset| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                var opened = true;
                defer if (opened) storage.close() catch unreachable;
                var workspace: [protocol.max_workspace_bytes]u8 = undefined;
                var input = try testing.completeConfiguration("group-spawn-parent", "", try testing.canonicalCwd(std.testing.io, &workspace), "model-a");
                input.configuration.tools = try .of(&.{"start_agent"});
                input.configuration.label.state = .value;
                try input.configuration.label.value.set("Coordinator\twork");
                const parent = (try storage.configure(&input, .{})).accepted.session;
                if (reset) try accepted(&storage, "group-spawn-parent-leave", parent.slice(), .leave);
                try testing.submitTestMessage(&storage, &tmp, "group-spawn-message", "group-spawn-message", parent.slice(), "start a child");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try fixtures.settleCallsForTesting(&storage, &tmp, model, "group-spawn-call", &.{.{
                    .item_id = "group-spawn-item",
                    .name = "start_agent",
                    .encoded_call_id = "group-spawn-call",
                    .decoded_call_id = "group-spawn-call",
                    .encoded_arguments = "{}",
                    .decoded_arguments = "{}",
                }});
                const action = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
                const Capture = struct {
                    child: protocol.Bounded(protocol.session_id_bytes) = .{},
                    fn call(raw: *anyopaque, admission: Store.MessageAdmission) void {
                        const self: *@This() = @ptrCast(@alignCast(raw));
                        self.child.set(admission.session) catch unreachable;
                    }
                };
                var capture: Capture = .{};
                var spec = try fixtures.testingAgentSpec(&.{}, "ask");
                try std.testing.expect(try storage.startAgent(action.binding, parent.slice(), "read", attached, &spec, .{ .context = &capture, .call = Capture.call }, .{}) == .started);
                const child = (try @import("Store.zig").readSessionForTesting(&storage, capture.child.slice())).?;
                try std.testing.expectEqual(attached, child.parent_ref != null);
                if (reset) {
                    try std.testing.expect((try saved(&storage, capture.child.slice())).group == null);
                    try accepted(&storage, "group-spawn-parent-reset", parent.slice(), .automatic);
                    try accepted(&storage, "group-spawn-child-reset", capture.child.slice(), .automatic);
                }
                const parent_group = (try saved(&storage, parent.slice())).group.?;
                try std.testing.expect(parent_group.name.eql(parent.slice()));
                const family = parent_group.id;
                try std.testing.expectEqual(family, (try saved(&storage, capture.child.slice())).group.?.id);
                const grandchild = try create(&storage, "group-spawn-grandchild", capture.child.slice(), null);
                try std.testing.expectEqual(family, (try saved(&storage, grandchild.slice())).group.?.id);
                try accepted(&storage, "group-spawn-child-leave", capture.child.slice(), .leave);
                const after_leave = try create(&storage, "group-spawn-after-leave", capture.child.slice(), null);
                try std.testing.expect((try saved(&storage, after_leave.slice())).group == null);
                try std.testing.expectEqual(family, (try saved(&storage, grandchild.slice())).group.?.id);
                try std.testing.expect(!storage.isFenced());
                try storage.close();
                opened = false;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                opened = true;
                try std.testing.expect((try saved(&storage, parent.slice())).group.?.name.eql(parent.slice()));
                try std.testing.expectEqual(family, (try saved(&storage, grandchild.slice())).group.?.id);
                try std.testing.expect(!storage.isFenced());
            };
        }
    }.run);
}

test "session group transaction failure rolls back placement metadata and command together" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            var opened = true;
            defer if (opened) storage.close() catch unreachable;
            const session = try create(&storage, "group-rollback-session", null, null);
            var edit = try command("group-rollback-edit", session.slice(), .{ .assign = try .from("Rollback group") });
            try std.testing.expect(storage.groupSession(&edit, .{ .before_commit = true }) == .infrastructure_failure);
            try storage.close();
            opened = false;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            opened = true;
            const before = try saved(&storage, session.slice());
            try std.testing.expect(!before.manual and before.group == null);
            const absent = try testing.observeCommandForTesting(&storage, edit.key.slice());
            try std.testing.expect(absent.status == .absent);
            const retried = storage.groupSession(&edit, .{});
            try std.testing.expect(retried == .accepted and !retried.accepted.replayed);
            try std.testing.expect((try saved(&storage, session.slice())).manual);
        }
    }.run);
}

fn currentGroup(storage: *Store, reference: []const u8) !@import("../activity_facts.zig").PageWork {
    var request: @import("../activity_read.zig").ActivityPage = .{};
    try request.session.set(reference);
    const page = try @import("Store.zig").activityPageForTesting(storage, request);
    var buffer: [@import("../activity_reply.zig").max_page_bytes]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try @import("../activity_reply.zig").writePage(&out, &page);
    const decoded = try @import("../protocol_reply.zig").ActivityPage.parse(out.buffered(), .{});
    try std.testing.expectEqualDeep(page.work, decoded.facts.work);
    return decoded.facts.work;
}

test "session group current activity snapshot is canonical outside every archive list filter" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            for ([_]bool{ false, true }) |archived| for (std.enums.values(@import("../session_archive.zig").Filter)) |filter| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try create(&storage, "group-current-session", null, null);
                if (archived) {
                    var archive: protocol.SessionArchiveCommand = .{ .session = session };
                    try archive.key.set("group-current-archive");
                    try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
                }
                try accepted(&storage, "group-current-first", session.slice(), .{ .assign = try .from("Current first") });
                const original = (try currentGroup(&storage, session.slice())).group.?;
                const listed = try fixtures.TestingListing.read(&storage, &tmp, .{ .archive = filter });
                const visible = filter == .all or (filter == .archived) == archived;
                try std.testing.expectEqual(@as(usize, @intFromBool(visible)), listed.count);
                try accepted(&storage, "group-current-move", session.slice(), .{ .assign = try .from("Current second") });
                const moved = try currentGroup(&storage, session.slice());
                try std.testing.expect(moved.group_manual and moved.group.?.id != original.id);
                try std.testing.expect(moved.group.?.name.eql("Current second"));
                try accepted(&storage, "group-current-rename", session.slice(), .{ .rename = .{ .group = moved.group.?.id, .name = try .from("Current renamed") } });
                const renamed = try currentGroup(&storage, session.slice());
                try std.testing.expectEqual(moved.group.?.id, renamed.group.?.id);
                try std.testing.expect(renamed.group.?.name.eql("Current renamed"));
                try std.testing.expect(renamed.read_version.generation > moved.read_version.generation);
                try accepted(&storage, "group-current-leave", session.slice(), .leave);
                const left = try currentGroup(&storage, session.slice());
                try std.testing.expect(left.group == null and left.group_manual);
                try accepted(&storage, "group-current-automatic", session.slice(), .automatic);
                const automatic = try currentGroup(&storage, session.slice());
                try std.testing.expect(automatic.group == null and !automatic.group_manual);
                const other = try create(&storage, "group-current-other", null, null);
                try accepted(&storage, "group-current-original-unchanged", other.slice(), .{ .assign = try .from("Current first") });
                try std.testing.expectEqual(original.id, (try currentGroup(&storage, other.slice())).group.?.id);
            };
        }
    }.run);
}

test "session group rename current resolves membership atomically before refresh and replays its saved result" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try create(&storage, "group-current-race-session", null, null);
            const first_peer = try create(&storage, "group-current-race-first-peer", null, null);
            const second_peer = try create(&storage, "group-current-race-second-peer", null, null);
            try accepted(&storage, "group-current-race-first", session.slice(), .{ .assign = try .from("Race first") });
            try accepted(&storage, "group-current-race-first-peer-place", first_peer.slice(), .{ .assign = try .from("Race first") });
            const stale = (try currentGroup(&storage, session.slice())).group.?;
            var rename = try command("group-current-race-rename", session.slice(), .{ .rename_current = try .from("Race renamed") });
            try accepted(&storage, "group-current-race-external-move", session.slice(), .{ .assign = try .from("Race second") });
            const renamed = storage.groupSession(&rename, .{});
            try std.testing.expect(renamed == .accepted and !renamed.accepted.replayed);
            const observed = (try currentGroup(&storage, session.slice())).group.?;
            try std.testing.expect(observed.id != stale.id and observed.name.eql("Race renamed"));
            const kept = (try currentGroup(&storage, first_peer.slice())).group.?;
            try std.testing.expectEqual(stale.id, kept.id);
            try std.testing.expect(kept.name.eql("Race first"));
            try accepted(&storage, "group-current-race-second-peer-place", second_peer.slice(), .{ .assign = try .from("Race renamed") });
            try accepted(&storage, "group-current-race-move-again", session.slice(), .{ .assign = try .from("Race first") });
            const replay = storage.groupSession(&rename, .{});
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            try std.testing.expect((try currentGroup(&storage, first_peer.slice())).group.?.name.eql("Race first"));
            try std.testing.expect((try currentGroup(&storage, second_peer.slice())).group.?.name.eql("Race renamed"));
            try rename.key.set("group-current-race-left-rename");
            try accepted(&storage, "group-current-race-left", session.slice(), .leave);
            const left = storage.groupSession(&rename, .{});
            try std.testing.expect(left == .rejected and left.rejected.code == .unknown_group);
            try accepted(&storage, "group-current-race-place-after-refusal", session.slice(), .{ .assign = try .from("Race first") });
            const rejected_replay = storage.groupSession(&rename, .{});
            try std.testing.expect(rejected_replay == .rejected and rejected_replay.rejected.replayed and rejected_replay.rejected.code == .unknown_group);
            try std.testing.expect((try currentGroup(&storage, first_peer.slice())).group.?.name.eql("Race first"));
        }
    }.run);
}
