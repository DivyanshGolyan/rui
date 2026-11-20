const std = @import("std");
const protocol = @import("../protocol.zig");
const wire_request = @import("../wire_request.zig");
const session_list = @import("../session_list.zig");
const session_archive = @import("../session_archive.zig");
const core = @import("Store.zig");
const Store = core.Store;
const testing = @import("testing.zig");
const fixtures = @import("tests.zig");

fn expectOrigin(storage: *Store, session: []const u8, creator: ?[]const u8, parent: ?[]const u8, archive: session_archive.Filter, listed: bool) !void {
    const Visitor = struct {
        session: []const u8,
        creator: ?[]const u8,
        parent: ?[]const u8,
        found: bool = false,
        pub fn head(_: *@This()) !void {}
        pub fn row(self: *@This(), value: *const session_list.Row) !void {
            if (!std.mem.eql(u8, value.reference, self.session)) return;
            try std.testing.expect(!self.found);
            self.found = true;
            try expectReference(self.creator, value.creator);
            try expectReference(self.parent, value.parent);
        }
        pub fn tail(_: *@This(), _: session_list.Tail) !void {}
        pub fn archivedRow(_: *@This(), _: *const session_list.ArchivedRow) !void {
            return error.TestUnexpectedResult;
        }
    };
    var visitor: Visitor = .{ .session = session, .creator = creator, .parent = parent };
    const request: session_list.ListSessions = .{ .archive = archive };
    var pages: @import("domain/session_list_read.zig").Scratch = undefined;
    try storage.readSessionList(&request, &visitor, &pages);
    try std.testing.expectEqual(listed, visitor.found);
    var activity: @import("../activity_read.zig").ActivityPage = .{};
    try activity.session.set(session);
    const page = try core.activityPageForTesting(storage, activity);
    try expectReference(creator, if (page.work.creator) |*value| value.slice() else null);
}

fn expectReference(expected: ?[]const u8, actual: ?[]const u8) !void {
    try std.testing.expectEqual(expected != null, actual != null);
    if (expected) |reference| try std.testing.expectEqualStrings(reference, actual.?);
}

fn childCommand(key: []const u8, parent: []const u8) !wire_request.ConfigureCommand {
    var command: wire_request.ConfigureCommand = .{};
    try command.key.set(key);
    command.configuration = try fixtures.testingAgentSpec(&.{}, "ask");
    command.configuration.parent.state = .value;
    try command.configuration.parent.value.set(parent);
    return command;
}

test "session creator records immediate attached and detached start_agent origin through updates replay and reopen" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            for ([_]bool{ false, true }) |attached| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                var opened = true;
                defer if (opened) storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try testing.canonicalCwd(std.testing.io, &workspace_buffer);
                var root_command = try testing.completeConfiguration("creator-root", "", workspace, "model-a");
                root_command.configuration.tools = try .of(&.{"start_agent"});
                const root = (try storage.configure(&root_command, .{})).accepted.session;
                try expectOrigin(&storage, root.slice(), null, null, .all, true);
                try testing.submitTestMessage(&storage, &tmp, "creator-task", "creator-task", root.slice(), "start child");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try fixtures.settleCallsForTesting(&storage, &tmp, model, "creator-call", &.{.{
                    .item_id = "creator-item",
                    .name = "start_agent",
                    .encoded_call_id = "creator-call",
                    .decoded_call_id = "creator-call",
                    .encoded_arguments = "{}",
                    .decoded_arguments = "{}",
                }});
                const action = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
                var spec = try fixtures.testingAgentSpec(&.{}, "ask");
                const Capture = struct {
                    child: protocol.Bounded(protocol.session_id_bytes) = .{},
                    fn call(context: *anyopaque, admission: Store.MessageAdmission) void {
                        const self: *@This() = @ptrCast(@alignCast(context));
                        self.child.set(admission.session) catch unreachable;
                    }
                };
                var capture: Capture = .{};
                try std.testing.expect(try storage.startAgent(action.binding, root.slice(), "child task", attached, &spec, .{ .context = &capture, .call = Capture.call }, .{}) == .started);
                const child = capture.child;
                const parent: ?[]const u8 = if (attached) root.slice() else null;
                try expectOrigin(&storage, child.slice(), root.slice(), parent, .all, true);
                var nested_command = try childCommand("creator-nested", child.slice());
                const nested = (try storage.configure(&nested_command, .{})).accepted.session;
                try expectOrigin(&storage, nested.slice(), child.slice(), child.slice(), .all, true);
                var update: wire_request.ConfigureCommand = .{};
                try update.key.set("creator-label");
                try update.session.set(child.slice());
                update.configuration.label.state = .value;
                try update.configuration.label.value.set("A different label");
                try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
                try std.testing.expect((try storage.configure(&update, .{})).accepted.replayed);
                try std.testing.expect((try storage.configure(&nested_command, .{})).accepted.replayed);
                try nested_command.configuration.parent.value.set(root.slice());
                try std.testing.expect(try storage.configure(&nested_command, .{}) == .conflict);
                var reparent = try childCommand("creator-reparent", root.slice());
                try reparent.session.set(child.slice());
                try std.testing.expect(try storage.configure(&reparent, .{}) == .rejected);
                try expectOrigin(&storage, child.slice(), root.slice(), parent, .all, true);
                try storage.close();
                opened = false;
                try testing.testingStore(case, &storage, &tmp, std.testing.io);
                opened = true;
                try expectOrigin(&storage, root.slice(), null, null, .all, true);
                try expectOrigin(&storage, child.slice(), root.slice(), parent, .all, true);
                try expectOrigin(&storage, nested.slice(), child.slice(), child.slice(), .all, true);
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

test "session creator Configure and Message births preserve origin across archive filters rollback and replay" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const root = try testing.configureTestSession(&storage, "creator-config-root");
            var command = try childCommand("creator-config-child", root.slice());
            try std.testing.expect(try storage.configure(&command, .{ .before_commit = true }) == .infrastructure_failure);
            try storage.close();
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            const child = (try storage.configure(&command, .{})).accepted.session;
            try std.testing.expect((try storage.configure(&command, .{})).accepted.replayed);
            var archive: protocol.SessionArchiveCommand = .{ .archived = true };
            try archive.key.set("creator-archive");
            try archive.session.set(child.slice());
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            inline for (.{ session_archive.Filter.active, .archived, .all }) |filter| {
                try expectOrigin(&storage, child.slice(), root.slice(), root.slice(), filter, filter != .active);
                try expectOrigin(&storage, root.slice(), null, null, filter, filter != .archived);
            }
            const file = try tmp.dir.createFile(std.testing.io, "creator-message", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, "hello");
            var message = try testing.completeMessage("creator-message", "", file, "hello");
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            message.configuration = (try childCommand("unused", root.slice())).configuration;
            const accepted = storage.submitMessageWithModel(&message, null, .{});
            try std.testing.expect(accepted == .accepted);
            try expectOrigin(&storage, accepted.accepted.session.slice(), root.slice(), root.slice(), .all, true);
            try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}).accepted.replayed);
            try std.testing.expectEqual(@as(u64, 3), try testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            const root_file = try tmp.dir.createFile(std.testing.io, "creator-person-message", .{ .read = true });
            try root_file.writeStreamingAll(std.testing.io, "person task");
            var person = try testing.completeMessage("creator-person-message", "", root_file, "person task");
            defer person.removeTemporaryContent(std.testing.io) catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try testing.canonicalCwd(std.testing.io, &workspace_buffer);
            person.configuration = (try testing.completeConfiguration("unused-person", "", workspace, "model-a")).configuration;
            const person_result = storage.submitMessageWithModel(&person, null, .{});
            try std.testing.expect(person_result == .accepted);
            try expectOrigin(&storage, person_result.accepted.session.slice(), null, null, .all, true);
        }
    }.run);
}

test "session creator names the Session that sent a creatorless Session's first Message" {
    try testing.forEachEngine(struct {
        fn send(storage: *Store, tmp: *std.testing.TmpDir, key: []const u8, target: []const u8, configuration: ?wire_request.Configuration, sender: ?[]const u8, handle: anytype) !protocol.Bounded(protocol.max_session_bytes) {
            const file = try tmp.dir.createFile(std.testing.io, key, .{ .read = true });
            try file.writeStreamingAll(std.testing.io, "work on this");
            var message = try testing.completeMessage(key, target, file, "work on this");
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            if (configuration) |value| message.configuration = value;
            if (sender) |reference| {
                message.sender = .{};
                try message.sender.?.store.set(storage.storeId());
                try message.sender.?.session.set(reference);
                message.sender_handle = handle;
            }
            const first = storage.submitMessageWithModel(&message, null, .{});
            try std.testing.expect(first == .accepted);
            // Replay keeps the saved outcome and changes no creator.
            try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}).accepted.replayed);
            return first.accepted.session;
        }

        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const other = try testing.configureTestSession(&storage, "creator-other");
            const sender_id = try testing.configureTestSession(&storage, "creator-sender");
            const sender = sender_id.slice();
            var tools: wire_request.ConfigureCommand = .{};
            try tools.key.set("creator-sender-tools");
            try tools.session.set(sender);
            tools.configuration.tools = try .of(&.{"bash"});
            tools.configuration.permission_mode.state = .value;
            try tools.configuration.permission_mode.value.set("bypass");
            try std.testing.expect(try storage.configure(&tools, .{}) == .accepted);
            try testing.submitTestMessage(&storage, &tmp, "creator-sender-seed", "creator-sender-seed", sender, "start chats");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try fixtures.settleTwoActionsForTesting(&storage, &tmp, model, "creator-sender-calls");
            const action = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?.permit.binding;
            var input: @import("domain/action.zig").ActionExecutionInput = undefined;
            try storage.readActionExecutionInput(.bash, action, &input);
            const handle = input.sender_handle;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try testing.canonicalCwd(std.testing.io, &workspace_buffer);
            const plain = (try testing.completeConfiguration("unused", "", workspace, "model-a")).configuration;

            // `rui session start` from the sender's Bash, without --parent: creator, no lifecycle parent.
            const started = try send(&storage, &tmp, "creator-started", "", plain, sender, handle);
            try expectOrigin(&storage, started.slice(), sender, null, .all, true);
            // Created by configure (no sender), then first messaged by the sender: the same rule.
            const configured = try testing.configureTestSession(&storage, "creator-configured");
            _ = try send(&storage, &tmp, "creator-configured-first", configured.slice(), null, sender, handle);
            try expectOrigin(&storage, configured.slice(), sender, null, .all, true);
            // A person's first Message leaves no creator, and a later peer Message adds none.
            const personal = try testing.configureTestSession(&storage, "creator-personal");
            _ = try send(&storage, &tmp, "creator-personal-first", personal.slice(), null, null, null);
            _ = try send(&storage, &tmp, "creator-personal-later", personal.slice(), null, sender, handle);
            try expectOrigin(&storage, personal.slice(), null, null, .all, true);
            // An explicit parent other than the sender stays the creator and attaches the child.
            const parented = try send(&storage, &tmp, "creator-parented", "", (try childCommand("unused-parented", other.slice())).configuration, sender, handle);
            try expectOrigin(&storage, parented.slice(), other.slice(), other.slice(), .all, true);
        }
    }.run);
}
