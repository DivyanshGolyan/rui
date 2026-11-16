const std = @import("std");
const core = @import("core_tools.zig");
const storage = @import("store.zig");
const action_read = @import("action_read.zig");
const host_reply = @import("host_reply.zig");
const protocol = @import("protocol.zig");

pub fn run(store: *storage.Store, arena: std.mem.Allocator, input: *const storage.CoreActionInput, faults: storage.Faults) !void {
    if (input.arguments.length > core.read_action_max_argument_bytes) return fail(store, arena, input, "arguments exceed 4096 bytes", faults);
    const bytes = try arena.alloc(u8, @intCast(input.arguments.length));
    try store.readCoreArguments(input, bytes);
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(store, arena, input, "expected an object containing only action", faults),
    };
    if (root != .object or root.object.count() != 1 or !root.object.contains("action")) return fail(store, arena, input, "expected an object containing only action", faults);
    var arguments: core.ReadAction = undefined;
    const check = try core.checkReadAction(arena, bytes, &arguments);
    if (check == .rejected) return fail(store, arena, input, check.rejected, faults);
    const stopped = try store.stopAction(input.binding, arguments.action, faults);
    switch (stopped) {
        .not_found => return fail(store, arena, input, "action names no Action in your own Session", faults),
        .invalid_target => return fail(store, arena, input, "an Action cannot stop itself", faults),
        .selected, .pending => return,
        .final => {},
    }
    const result = try arena.create(action_read.Read);
    try store.readAction(&.{ .session = input.session, .action_id = arguments.action }, result);
    const rendered = try arena.alloc(u8, protocol.action_read_reply.max_bytes);
    var writer: std.Io.Writer = .fixed(rendered);
    try host_reply.renderActionRead(.{ .writer = &writer }, result);
    _ = try store.succeedCoreCall(input.binding, writer.buffered(), faults);
}

fn fail(store: *storage.Store, arena: std.mem.Allocator, input: *const storage.CoreActionInput, reason: []const u8, faults: storage.Faults) !void {
    const text = try std.fmt.allocPrint(arena, "Rui could not stop the Action: {s}.", .{reason});
    _ = try store.failCoreCall(input.binding, text, faults);
}

fn queueCallsForTesting(database: *storage.Store, tmp: *std.testing.TmpDir, arena: std.mem.Allocator, binding: storage.AttemptBinding, prefix: []const u8, name: []const u8, arguments: []const []const u8) !void {
    const items = try arena.alloc(storage.TestingCall, arguments.len);
    for (items, arguments, 0..) |*item, text, ordinal| {
        const id = try std.fmt.allocPrint(arena, "{s}-{d}", .{ prefix, ordinal });
        const encoded = try std.json.Stringify.valueAlloc(arena, text, .{});
        item.* = .{ .item_id = id, .name = name, .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = encoded[1 .. encoded.len - 1], .decoded_arguments = text };
    }
    try storage.settleCallsForTesting(database, tmp, binding, prefix, items);
}

test "stop_action settles owned Actions once and suppresses background input" {
    try storage.testing.forEachEngine(struct {
        fn check(case: *storage.testing.Case) !void {
            for ([_]enum { running, restart, ended, waiting }{ .running, .restart, .ended, .waiting }) |mode| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var database: storage.Store = undefined;
                try storage.testing.testingStore(case, &database, &tmp, std.testing.io);
                defer database.close() catch unreachable;
                var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena_state.deinit();
                const arena = arena_state.allocator();
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try storage.testingCanonicalCwd(std.testing.io, &workspace_buffer);
                var configure = try storage.testingCompleteConfiguration("stop-test", "", workspace, "model-a");
                configure.configuration.tools = try .of(&.{ "bash", "read_action", "stop_action" });
                configure.configuration.permission_mode.state = .value;
                try configure.configuration.permission_mode.value.set(if (mode == .waiting) "ask" else "bypass");
                const session = (try database.configure(&configure, .{})).accepted.session;
                try storage.testingSubmitMessage(&database, &tmp, "stop-task", "stop-task", session.slice(), "run");
                const first = (try database.admitNextModelAttempt(.{})).?.permit.binding;
                try queueCallsForTesting(&database, &tmp, arena, first, "target", "bash", &.{"{\"cmd\":\"true\",\"description\":\"Held\"}"});
                const target = try storage.testing.queryU64(&database, "SELECT action_id FROM action_operation WHERE parent_operation_id=?1", .{first.operation_id});
                var background: @import("command_input.zig").ActionBackgroundCommand = .{ .session = session, .action_id = target };
                try background.key.set("stop-background");
                try std.testing.expect(database.backgroundAction(.{ .command = &background }, .{}) == .accepted);
                const effect = if (mode != .waiting) (try database.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding else null;
                if (mode == .ended) _ = try database.settleActionAttempt(effect.?, .succeeded, "finished before stop", .{});
                const second = (try database.admitNextModelAttempt(.{})).?.permit.binding;
                const args = try std.fmt.allocPrint(arena, "{{\"action\":\"{d}\"}}", .{target});
                try queueCallsForTesting(&database, &tmp, arena, second, "stop", "stop_action", &.{args});
                const stop = (try database.nextCoreWork(.fromFree(2, true))).?.action;
                try run(&database, arena, &stop, .{});
                if (mode == .running) {
                    try std.testing.expect((try database.actionSupersededByStop(effect.?)) != null);
                    _ = try database.settleActionAttempt(effect.?, .succeeded, "late result", .{});
                } else if (mode == .restart) {
                    try database.close();
                    try storage.testing.testingStore(case, &database, &tmp, std.testing.io);
                    try std.testing.expect(try database.recoverOneUncertainAction(.empty()));
                }
                if (mode != .ended) {
                    const resumed = (try database.nextCoreWork(.fromFree(2, true))).?.action;
                    try run(&database, arena, &resumed, .{});
                }
                try std.testing.expectEqual(@as(u64, 1), try storage.testing.queryU64(&database, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code=?2", .{ target, if (mode == .ended) "succeeded" else "cancelled" }));
                if (mode != .ended) try std.testing.expectEqual(@as(u64, 0), try storage.testing.queryU64(&database, "SELECT count(*) FROM message_admission WHERE source_action_id=?1", .{target}));
                try std.testing.expectEqual(@as(u64, 1), try storage.testing.queryU64(&database, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code='succeeded'", .{stop.binding.action_id}));
            }
        }
    }.check);
}

test "stop_action refuses another Session's Action" {
    try storage.testing.forEachEngine(struct {
        fn check(case: *storage.testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var database: storage.Store = undefined;
            try storage.testing.testingStore(case, &database, &tmp, std.testing.io);
            defer database.close() catch unreachable;
            var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try storage.testingCanonicalCwd(std.testing.io, &workspace_buffer);
            var configure = try storage.testingCompleteConfiguration("stop-owner", "", workspace, "model-a");
            configure.configuration.tools = try .of(&.{ "bash", "read_action", "stop_action" });
            configure.configuration.permission_mode.state = .value;
            try configure.configuration.permission_mode.value.set("bypass");
            const owner = (try database.configure(&configure, .{})).accepted.session;
            try storage.testingSubmitMessage(&database, &tmp, "owner-input", "owner-input", owner.slice(), "run");
            const first = (try database.admitNextModelAttempt(.{})).?.permit.binding;
            try queueCallsForTesting(&database, &tmp, arena, first, "target", "bash", &.{"{\"cmd\":\"true\",\"description\":\"Held\"}"});
            const target = try storage.testing.queryU64(&database, "SELECT action_id FROM action_operation WHERE parent_operation_id=?1", .{first.operation_id});
            const effect = (try database.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
            try configure.key.set("stop-foreign");
            const foreign = (try database.configure(&configure, .{})).accepted.session;
            try storage.testingSubmitMessage(&database, &tmp, "foreign-input", "foreign-input", foreign.slice(), "stop");
            const second = (try database.admitModelAttempt(.message, .{})).?.permit.binding;
            const args = try std.fmt.allocPrint(arena, "{{\"action\":\"{d}\"}}", .{target});
            try queueCallsForTesting(&database, &tmp, arena, second, "foreign", "stop_action", &.{args});
            const stop = (try database.nextCoreWork(.fromFree(2, true))).?.action;
            try run(&database, arena, &stop, .{});
            try std.testing.expectEqual(@as(u64, 1), try storage.testing.queryU64(&database, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code='failed'", .{stop.binding.action_id}));
            try std.testing.expectEqual(@as(u64, 0), try storage.testing.queryU64(&database, "SELECT count(*) FROM action_stop WHERE target_action_id=?1", .{target}));
            try std.testing.expect((try database.actionSupersededByStop(effect)) == null);
        }
    }.check);
}

test "stop_action cancellation races do not fence the Store" {
    try storage.testing.forEachEngine(struct {
        fn check(case: *storage.testing.Case) !void {
            for ([_]enum { stop, archive }{ .stop, .archive }) |mode| {
                for ([_]enum { before_selection, after_selection, after_stop_selection }{ .before_selection, .after_selection, .after_stop_selection }) |phase| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var database: storage.Store = undefined;
                    try storage.testing.testingStore(case, &database, &tmp, std.testing.io);
                    defer database.close() catch unreachable;
                    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
                    defer arena_state.deinit();
                    const arena = arena_state.allocator();
                    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                    const workspace = try storage.testingCanonicalCwd(std.testing.io, &workspace_buffer);
                    var configure = try storage.testingCompleteConfiguration("stale-stop", "", workspace, "model-a");
                    configure.configuration.tools = try .of(&.{ "bash", "read_action", "stop_action" });
                    configure.configuration.permission_mode.state = .value;
                    try configure.configuration.permission_mode.value.set("bypass");
                    const session = (try database.configure(&configure, .{})).accepted.session;
                    try storage.testingSubmitMessage(&database, &tmp, "stale-task", "stale-task", session.slice(), "run");
                    const first = (try database.admitNextModelAttempt(.{})).?.permit.binding;
                    try queueCallsForTesting(&database, &tmp, arena, first, "target", "bash", &.{"{\"cmd\":\"true\",\"description\":\"Held\"}"});
                    const target = try storage.testing.queryU64(&database, "SELECT action_id FROM action_operation WHERE parent_operation_id=?1", .{first.operation_id});
                    var background: @import("command_input.zig").ActionBackgroundCommand = .{ .session = session, .action_id = target };
                    try background.key.set("stale-background");
                    try std.testing.expect(database.backgroundAction(.{ .command = &background }, .{}) == .accepted);
                    const second = (try database.admitNextModelAttempt(.{})).?.permit.binding;
                    const args = try std.fmt.allocPrint(arena, "{{\"action\":\"{d}\"}}", .{target});
                    try queueCallsForTesting(&database, &tmp, arena, second, "stop", "stop_action", &.{args});
                    const source_id = try storage.testing.queryU64(&database, "SELECT action_id FROM action_operation WHERE parent_operation_id=?1", .{second.operation_id});
                    const source: storage.ActionAttemptBinding = .{ .action_id = source_id, .parent_operation_id = second.operation_id, .turn_id = second.turn_id };
                    if (phase != .before_selection) {
                        const selected = (try database.nextCoreWork(.fromFree(2, true))).?.action;
                        try std.testing.expectEqual(source_id, selected.binding.action_id);
                    }
                    if (phase == .after_stop_selection) try std.testing.expect((try database.stopAction(source, target, .{})) == .selected);
                    switch (mode) {
                        .stop => {
                            var stop: protocol.SessionStopCommand = .{ .session = session };
                            try stop.key.set("stale-session-stop");
                            try std.testing.expect(database.stopSession(&stop, .{}) == .accepted);
                        },
                        .archive => {
                            var archive: protocol.SessionArchiveCommand = .{ .session = session };
                            try archive.key.set("stale-session-archive");
                            try std.testing.expect(database.archiveSession(&archive, .{}) == .accepted);
                        },
                    }
                    if (phase == .before_selection) {
                        if (try database.nextCoreWork(.fromFree(2, true))) |work| {
                            if (work == .action) try std.testing.expect(work.action.binding.action_id != source_id);
                        }
                    }
                    try std.testing.expectError(error.StaleActionAttemptBinding, database.stopAction(source, target, .{}));
                    if (phase == .after_stop_selection) {
                        try std.testing.expectEqual(@as(u64, 1), try storage.testing.queryU64(&database, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code='cancelled'", .{target}));
                        try std.testing.expectEqual(@as(u64, 0), try storage.testing.queryU64(&database, "SELECT count(*) FROM message_admission WHERE source_action_id=?1", .{target}));
                    }
                    try std.testing.expect(!database.isFenced());
                    try configure.key.set("unrelated-still-works");
                    try std.testing.expect((try database.configure(&configure, .{})) == .accepted);
                }
            }
        }
    }.check);
}
