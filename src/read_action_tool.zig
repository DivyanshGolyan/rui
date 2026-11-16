const std = @import("std");
const core = @import("core_tools.zig");
const storage = @import("store.zig");
const action_read = @import("action_read.zig");
const host_reply = @import("host_reply.zig");
const protocol = @import("protocol.zig");

pub fn run(store: *storage.Store, arena: std.mem.Allocator, input: *const storage.CoreActionInput, faults: storage.Faults) !void {
    var arguments: core.ReadAction = undefined;
    const check: core.StartAgentCheck = if (input.arguments.length > core.read_action_max_argument_bytes)
        .{ .rejected = "the arguments take more than 4096 bytes" }
    else check: {
        const bytes = try arena.alloc(u8, @intCast(input.arguments.length));
        try store.readCoreArguments(input, bytes);
        break :check try core.checkReadAction(arena, bytes, &arguments);
    };
    if (check == .rejected) return fail(store, arena, input, check.rejected, faults);
    const result = try arena.create(action_read.Read);
    store.readAction(&.{ .session = input.session, .action_id = arguments.action, .offset = arguments.offset }, result) catch |err| switch (err) {
        error.ActionNotFound => return fail(store, arena, input, "action names no Action in your own Session", faults),
        error.InvalidCursor => return fail(store, arena, input, "offset must be within the result and on a UTF-8 character boundary; pending Actions require zero", faults),
        else => return err,
    };
    const bytes = try arena.alloc(u8, protocol.action_read_reply.max_bytes);
    var writer: std.Io.Writer = .fixed(bytes);
    try host_reply.renderActionRead(.{ .writer = &writer }, result);
    _ = try store.succeedCoreCall(input.binding, writer.buffered(), faults);
}

fn fail(store: *storage.Store, arena: std.mem.Allocator, input: *const storage.CoreActionInput, reason: []const u8, faults: storage.Faults) !void {
    const text = try std.fmt.allocPrint(arena, "Rui could not read the Action: {s}.", .{reason});
    _ = try store.failCoreCall(input.binding, text, faults);
}

test "read_action core reads own pending and immutable final windows without credit" {
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
            var configure = try storage.testingCompleteConfiguration("action-reader", "", workspace, "model-a");
            configure.configuration.tools = try .of(&.{ "bash", "read_action" });
            configure.configuration.permission_mode.state = .value;
            try configure.configuration.permission_mode.value.set("ask");
            const configured = try database.configure(&configure, .{});
            try std.testing.expect(configured == .accepted);
            const session = configured.accepted.session;
            try storage.testingSubmitMessage(&database, &tmp, "read-task", "read-task", session.slice(), "run and inspect");
            const first_model = ((try database.admitNextModelAttempt(.{})) orelse return error.ExpectedInitialModelAdmission).permit.binding;
            try queueCallsForTesting(&database, &tmp, arena, first_model, "target", "bash", &.{"{\"cmd\":\"true\",\"description\":\"Held original\"}"});
            const target = try storage.testing.queryU64(&database, "SELECT action_id FROM action_operation WHERE parent_operation_id=?1", .{first_model.operation_id});
            var background: @import("command_input.zig").ActionBackgroundCommand = .{ .session = session, .action_id = target };
            try background.key.set("read-background");
            const free: usize = 2;
            const capacity: storage.ActionCapacityView = .{ .total = 2, .context = &free, .freeFn = struct {
                fn read(context: *const anyopaque) usize {
                    return @as(*const usize, @ptrCast(@alignCast(context))).*;
                }
            }.read };
            try std.testing.expect(database.backgroundAction(&background, capacity, .{}) == .accepted);
            var own: action_read.Read = undefined;
            try database.readAction(&.{ .session = session, .action_id = target }, &own);
            try std.testing.expect(own.status == .pending and own.status.pending == .waiting_approval);
            const foreign = try storage.testing.configureTestSession(&database, "reader-foreign");
            var changed = configure;
            try changed.key.set("foreign-reader-tools");
            changed.session = foreign;
            changed.configuration.tools = try .of(&.{"read_action"});
            try std.testing.expect(try database.configure(&changed, .{}) == .accepted);
            try storage.testingSubmitMessage(&database, &tmp, "foreign-task", "foreign-task", foreign.slice(), "inspect another Session");
            const pending_args = try std.fmt.allocPrint(arena, "{{\"action\":\"{d}\"}}", .{target});
            const pending_cursor = try std.fmt.allocPrint(arena, "{{\"action\":\"{d}\",\"offset\":\"1\"}}", .{target});
            const pending_model = ((try database.admitModelAttempt(.tool_continuation, .{})) orelse return error.ExpectedReadContinuation).permit.binding;
            try queueCallsForTesting(&database, &tmp, arena, pending_model, "pending", "read_action", &.{ pending_args, pending_cursor, "{}" });
            const pending = (try database.nextCoreWork(.{ .free_credit = .none, .mcp_open = false })).?.action;
            try run(&database, arena, &pending, .{});
            const bytes = try callResultForTesting(&database, arena, pending.binding.action_id);
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
            try std.testing.expectEqualStrings(session.slice(), parsed.object.get("session").?.string);
            try std.testing.expectEqualStrings("waiting_approval", parsed.object.get("state").?.string);
            try std.testing.expect(parsed.object.get("final").? == .null);
            for (0..2) |_| {
                const invalid = (try database.nextCoreWork(.{ .free_credit = .none, .mcp_open = false })).?.action;
                try run(&database, arena, &invalid, .{});
                try expectCallCode(&database, invalid.binding.action_id, "failed");
            }
            const foreign_model = ((try database.admitModelAttempt(.message, .{})) orelse return error.ExpectedForeignReadAdmission).permit.binding;
            try queueCallsForTesting(&database, &tmp, arena, foreign_model, "foreign", "read_action", &.{pending_args});
            const foreign_read = (try database.nextCoreWork(.{ .free_credit = .none, .mcp_open = false })).?.action;
            try std.testing.expectEqualStrings(foreign.slice(), foreign_read.session.slice());
            try run(&database, arena, &foreign_read, .{});
            try expectCallCode(&database, foreign_read.binding.action_id, "failed");
            try std.testing.expectEqualStrings("Rui could not read the Action: action names no Action in your own Session.", try callResultForTesting(&database, arena, foreign_read.binding.action_id));
            var allow: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = target, .decision = .allow_once };
            try allow.key.set("read-target-allow");
            try std.testing.expect(database.decidePermission(&allow, .{}) == .accepted);
            const admitted = (try database.admitNextActionAttempt(.{ .free_credit = .multiple, .mcp_open = true }, 30_000, .{})) orelse return error.ExpectedApprovedBackgroundAttempt;
            const binding = admitted.permit.binding;
            const repeats = action_read.window_bytes / 3 + 3;
            const text = "a" ++ @as([3 * repeats]u8, @bitCast(@as([repeats][3]u8, @splat("雪".*))));
            _ = try database.settleActionAttempt(binding, .succeeded, text, .{});
            try database.readAction(&.{ .session = session, .action_id = target }, &own);
            const final = own.status.resolved.resolution;
            const continuation = try std.fmt.allocPrint(arena, "{{\"action\":\"{d}\",\"offset\":\"4096\"}}", .{target});
            const eof = try std.fmt.allocPrint(arena, "{{\"action\":\"{d}\",\"offset\":\"{d}\"}}", .{ target, text.len });
            const invalid_utf8 = try std.fmt.allocPrint(arena, "{{\"action\":\"{d}\",\"offset\":\"2\"}}", .{target});
            const final_model = ((try database.admitModelAttempt(.tool_continuation, .{})) orelse return error.ExpectedFinalReadContinuation).permit.binding;
            try queueCallsForTesting(&database, &tmp, arena, final_model, "final", "read_action", &.{ pending_args, continuation, eof, invalid_utf8, pending_args });
            var first: []const u8 = undefined;
            for (0..5) |index| {
                const read = (try database.nextCoreWork(.{ .free_credit = .none, .mcp_open = false })).?.action;
                try run(&database, arena, &read, .{});
                const output = try callResultForTesting(&database, arena, read.binding.action_id);
                if (index == 3) {
                    try expectCallCode(&database, read.binding.action_id, "failed");
                    continue;
                }
                try expectCallCode(&database, read.binding.action_id, "succeeded");
                if (index == 0) first = output;
                if (index == 4) try std.testing.expectEqualStrings(first, output);
                const value = (try std.json.parseFromSliceLeaky(std.json.Value, arena, output, .{})).object;
                try std.testing.expectEqualStrings("resolved", value.get("state").?.string);
                const resolved = value.get("final").?.object;
                try std.testing.expectEqual(final.position, try std.fmt.parseInt(u64, resolved.get("position").?.string, 10));
                try std.testing.expectEqualStrings("succeeded", resolved.get("code").?.string);
                try std.testing.expectEqual(text.len, try std.fmt.parseInt(u64, resolved.get("content").?.object.get("bytes").?.string, 10));
                const digest = std.fmt.bytesToHex(protocol.contentDigest(text), .lower);
                try std.testing.expectEqualStrings(&digest, resolved.get("content").?.object.get("sha256").?.string);
                const window = resolved.get("window").?.object;
                const start: usize = switch (index) {
                    1 => 4096,
                    2 => text.len,
                    else => 0,
                };
                const end: usize = if (index == 0 or index == 4) 4096 else text.len;
                try std.testing.expectEqualStrings(text[start..end], window.get("text").?.string);
                try std.testing.expectEqual(start, try std.fmt.parseInt(u64, window.get("offset").?.string, 10));
                try std.testing.expectEqual(end, try std.fmt.parseInt(u64, window.get("next").?.string, 10));
                try std.testing.expectEqual(end < text.len, window.get("more").?.bool);
            }
            try database.readAction(&.{ .session = session, .action_id = target }, &own);
            try std.testing.expectEqualDeep(final, own.status.resolved.resolution);
            try std.testing.expect(try database.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 30_000, .{}) == null);
        }
    }.check);
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

fn callResultForTesting(database: *storage.Store, arena: std.mem.Allocator, action: u64) ![]const u8 {
    const id = try storage.testing.queryU64(database, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1", .{action});
    const reference = try storage.testingContentReference(database, id);
    const bytes = try arena.alloc(u8, @intCast(reference.length));
    var reader: storage.ContentReader = undefined;
    reader.open(try database.openContent(reference));
    defer reader.close();
    try std.testing.expectEqual(bytes.len, try reader.readRange(0, bytes));
    return bytes;
}

fn expectCallCode(database: *storage.Store, action: u64, code: []const u8) !void {
    try std.testing.expectEqual(@as(u64, 1), try storage.testing.queryU64(database, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code=?2", .{ action, code }));
}

test "read_action core refuses a source call resolved by Session stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var database: storage.Store = undefined;
    try storage.testing.testingSqliteStore(&database, &tmp, std.testing.io);
    defer database.close() catch unreachable;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try storage.testingCanonicalCwd(std.testing.io, &workspace_buffer);
    var configure = try storage.testingCompleteConfiguration("stopped-reader", "", workspace, "model-a");
    configure.configuration.tools = try .of(&.{"read_action"});
    const session = (try database.configure(&configure, .{})).accepted.session;
    try storage.testingSubmitMessage(&database, &tmp, "stopped-input", "stopped-input", session.slice(), "read");
    const model = (try database.admitNextModelAttempt(.{})).?.permit.binding;
    try queueCallsForTesting(&database, &tmp, arena, model, "stopped-call", "read_action", &.{"{\"action\":\"1\"}"});
    const selected = (try database.nextCoreWork(.{ .free_credit = .none, .mcp_open = false })).?.action;
    var stop = try storage.testingCompleteSessionStop("stop-reader", session.slice());
    try std.testing.expect(database.stopSession(&stop, .{}) == .accepted);
    const original = try callResultForTesting(&database, arena, selected.binding.action_id);
    try expectCallCode(&database, selected.binding.action_id, "cancelled");
    try std.testing.expectError(error.StaleActionAttemptBinding, run(&database, arena, &selected, .{}));
    try expectCallCode(&database, selected.binding.action_id, "cancelled");
    try std.testing.expectEqualStrings(original, try callResultForTesting(&database, arena, selected.binding.action_id));
}
