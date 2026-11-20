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

test "session creator names the authenticated sender of a creating Message without parent input" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const sender_id = try testing.configureTestSession(&storage, "creator-sender");
            const sender = sender_id.slice();
            var tools: wire_request.ConfigureCommand = .{};
            try tools.key.set("creator-sender-tools");
            try tools.session.set(sender);
            tools.configuration.tools = try .of(&.{"bash"});
            tools.configuration.permission_mode.state = .value;
            try tools.configuration.permission_mode.value.set("bypass");
            try std.testing.expect(try storage.configure(&tools, .{}) == .accepted);
            try testing.submitTestMessage(&storage, &tmp, "creator-sender-seed", "creator-sender-seed", sender, "start a chat");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try fixtures.settleTwoActionsForTesting(&storage, &tmp, model, "creator-sender-calls");
            const action = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?.permit.binding;
            var input: @import("domain/action.zig").ActionExecutionInput = undefined;
            try storage.readActionExecutionInput(.bash, action, &input);
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try testing.canonicalCwd(std.testing.io, &workspace_buffer);

            // `rui session start` from the sender's Bash: a creating Message with its Host-issued handle.
            const file = try tmp.dir.createFile(std.testing.io, "creator-started", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, "work on this");
            var started = try testing.completeMessage("creator-started", "", file, "work on this");
            defer started.removeTemporaryContent(std.testing.io) catch unreachable;
            started.configuration = (try testing.completeConfiguration("unused-started", "", workspace, "model-a")).configuration;
            started.sender = .{};
            try started.sender.?.store.set(storage.storeId());
            try started.sender.?.session.set(sender);
            started.sender_handle = input.sender_handle;
            const accepted = storage.submitMessageWithModel(&started, null, .{});
            try std.testing.expect(accepted == .accepted);
            const child = accepted.accepted.session;
            try expectOrigin(&storage, child.slice(), sender, null, .all, true);
            try std.testing.expect(storage.submitMessageWithModel(&started, null, .{}).accepted.replayed);
            try expectOrigin(&storage, child.slice(), sender, null, .all, true);

            // An explicit parent still names the creator and attaches the child.
            const parented_file = try tmp.dir.createFile(std.testing.io, "creator-parented", .{ .read = true });
            try parented_file.writeStreamingAll(std.testing.io, "attached work");
            var parented = try testing.completeMessage("creator-parented", "", parented_file, "attached work");
            defer parented.removeTemporaryContent(std.testing.io) catch unreachable;
            parented.configuration = (try childCommand("unused-parented", sender)).configuration;
            parented.sender = started.sender;
            parented.sender_handle = input.sender_handle;
            const attached = storage.submitMessageWithModel(&parented, null, .{});
            try std.testing.expect(attached == .accepted);
            try expectOrigin(&storage, attached.accepted.session.slice(), sender, sender, .all, true);
        }
    }.run);
}
