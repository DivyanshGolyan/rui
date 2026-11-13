//! Session Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const store_access = @import("../access.zig");
const rsql = @import("../rsql.zig");
const Store = store_core.Store;
const configuration_domain = @import("../domain/configuration.zig");
const store_testing = @import("../testing.zig");
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const completeSessionStop = shared_fixtures.completeSessionStop;
const testingBytesContent = shared_fixtures.testingBytesContent;

test "Store allocates six character IDs atomically retries collisions and replays creation" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // A rerun draws its Session ID again.
            if (case.rerun) return;
            const Entropy = struct {
                var draws: usize = 0;
                fn random(_: ?*anyopaque, bytes: []u8) std.Io.RandomSecureError!void {
                    std.debug.assert(bytes.len == protocol.session_id_bytes);
                    @memset(bytes, if (draws < 2) 0 else 255);
                    draws += 1;
                }
            };
            Entropy.draws = 0;
            var vtable = std.testing.io.vtable.*;
            vtable.randomSecure = Entropy.random;
            var io = std.testing.io;
            io.vtable = &vtable;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(io, &workspace_buffer);
            var first = try completeConfiguration("first-creation", "", workspace, "model-a");
            const first_reply = try storage.configure(&first, .{});
            try std.testing.expect(first_reply == .accepted);
            const a = first_reply.accepted;
            try std.testing.expect(a.created and !a.replayed);
            try std.testing.expectEqualStrings("000000", a.session.slice());
            var second = try completeConfiguration("second-creation", "", workspace, "model-b");
            const second_reply = try storage.configure(&second, .{});
            try std.testing.expect(second_reply == .accepted);
            const b = second_reply.accepted;
            try std.testing.expect(b.created and !b.replayed);
            try std.testing.expectEqualStrings("zzzzzz", b.session.slice());
            try std.testing.expectEqual(@as(usize, 3), Entropy.draws);
            try std.testing.expectEqualStrings("model-a", (try store_core.readSessionForTesting(&storage, a.session.slice())).?.model.slice());
            try std.testing.expectEqualStrings("model-b", (try store_core.readSessionForTesting(&storage, b.session.slice())).?.model.slice());
            const replay = (try storage.configure(&second, .{})).accepted;
            try std.testing.expect(replay.replayed and replay.created);
            try std.testing.expectEqualStrings(b.session.slice(), replay.session.slice());
            try std.testing.expectEqual(@as(usize, 3), Entropy.draws);
            // The schema refuses a noncanonical reference that the production
            // insert binds; "short" and "1234567" are not a SessionHead's 6 bytes.
            const current = (try store_core.readSessionForTesting(&storage, a.session.slice())).?;
            try insertSessionForTesting(&storage, &current, "k7m2qz");
            for ([_]*const [protocol.session_id_bytes]u8{ "K7m2qx", "k7m2qi", "k7m\x00qx" }) |invalid| {
                try std.testing.expectError(error.StatementFailed, insertSessionForTesting(&storage, &current, invalid));
            }
            var unknown = try completeConfiguration("unknown-update", "k7m2qx", workspace, "model-c");
            try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_session, (try storage.configure(&unknown, .{})).rejected.code);
            try std.testing.expect(try store_core.readSessionForTesting(&storage, "k7m2qx") == null);
            for ([_][]const u8{ "old/name", "K7m2qx", "k7m2qi", "k7\x00qx" }, 0..) |invalid, index| {
                var key: [32]u8 = undefined;
                var bad = try completeConfiguration(try std.fmt.bufPrint(&key, "invalid-id-{d}", .{index}), invalid, workspace, "model-c");
                try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_session_reference, (try storage.configure(&bad, .{})).rejected.code);
            }
            try std.testing.expectEqual(@as(usize, 3), Entropy.draws);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "Store distinguishes noncanonical Session references from canonical unknown messages and controls" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const content = try testingBytesContent(&tmp, "reference-input", "input\x00with\nbytes");
            defer content.file.?.close(std.testing.io);
            const references = [_][]const u8{ "", "short", "1234567", "K7m2qx", "k7m2qi", "k7\x00qx", "old/name", "k7m2qx" };
            for (references, 0..) |reference, index| {
                const canonical_unknown = index == references.len - 1;
                var key: [64]u8 = undefined;
                var message: wire_request.MessageCommand = .{ .text = content };
                try message.key.set(try std.fmt.bufPrint(&key, "reference-message-{d}", .{index}));
                try message.session.set(reference);
                const message_reply = storage.submitMessageWithModel(&message, null, .{});
                try std.testing.expect(message_reply == .rejected);
                try std.testing.expectEqual(if (canonical_unknown) protocol.MessageRejection.unknown_session else .invalid_session_reference, message_reply.rejected.code);
                const message_replay = storage.submitMessageWithModel(&message, null, .{});
                try std.testing.expect(message_replay == .rejected and message_replay.rejected.replayed);
                try std.testing.expectEqual(message_reply.rejected.code, message_replay.rejected.code);

                var stop = try completeSessionStop(try std.fmt.bufPrint(&key, "reference-stop-{d}", .{index}), reference);
                const stop_reply = storage.stopSession(&stop, .{});
                try std.testing.expect(stop_reply == .rejected);
                try std.testing.expectEqual(if (canonical_unknown) protocol.SessionStopRejection.unknown_session else .invalid_session_reference, stop_reply.rejected.code);
                const stop_replay = storage.stopSession(&stop, .{});
                try std.testing.expect(stop_replay == .rejected and stop_replay.rejected.replayed);
                try std.testing.expectEqual(stop_reply.rejected.code, stop_replay.rejected.code);

                var interrupt: protocol.ModelInterruptionCommand = .{ .turn_id = 1, .operation_id = 1 };
                try interrupt.key.set(try std.fmt.bufPrint(&key, "reference-interrupt-{d}", .{index}));
                try interrupt.session.set(reference);
                const interrupt_reply = storage.interruptModel(&interrupt, .{});
                try std.testing.expect(interrupt_reply == .rejected);
                try std.testing.expectEqual(if (canonical_unknown) protocol.ModelInterruptionRejection.unknown_session else .invalid_session_reference, interrupt_reply.rejected.code);
                const interrupt_replay = storage.interruptModel(&interrupt, .{});
                try std.testing.expect(interrupt_replay == .rejected and interrupt_replay.rejected.replayed);
                try std.testing.expectEqual(interrupt_reply.rejected.code, interrupt_replay.rejected.code);

                var permission: protocol.PermissionDecisionCommand = .{ .action_id = 1 };
                try permission.key.set(try std.fmt.bufPrint(&key, "reference-permission-{d}", .{index}));
                try permission.session.set(reference);
                const permission_reply = storage.decidePermission(&permission, .{});
                try std.testing.expect(permission_reply == .rejected);
                try std.testing.expectEqual(if (canonical_unknown) protocol.PermissionDecisionRejection.unknown_session else .invalid_session_reference, permission_reply.rejected.code);
                const permission_replay = storage.decidePermission(&permission, .{});
                try std.testing.expect(permission_replay == .rejected and permission_replay.rejected.replayed);
                try std.testing.expectEqual(permission_reply.rejected.code, permission_replay.rejected.code);
                try std.testing.expect(!storage.isFenced());
            }
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id NOT IN (SELECT description_content_id FROM tool_record) AND content_id NOT IN (SELECT input_schema_content_id FROM tool_record)", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
        }
    }.run);
}

/// Runs the production INSERT of a created Session under `ref`, then rolls
/// it back, so a test sees what the schema accepts without keeping it.
fn insertSessionForTesting(storage: *Store, current: *const configuration_domain.CurrentConfiguration, ref: *const [protocol.session_id_bytes]u8) !void {
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    var a: store_access.Access(.write, error{}) = .open(&entry);
    defer a.deinit();
    const head: rsql.SessionHead = .{ .ref = ref.*, .workspace_key = .of(current.workspace_key), .next_position = .of(1) };
    const digest = store_core.workspaceDigest(current.workspace.slice());
    configuration_domain.insertSession(&a, head, current, &digest, 1_000_000, null);
    const ran = a.run();
    try a.abandon(.{});
    return ran;
}

test "existing Store rejects a different canonical identity" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            try storage.close();
            var refused: Store = undefined;
            try std.testing.expectError(
                if (case.engine == .sqlite) error.StoreIdentityMismatch else error.WrongStoreIdentity,
                store_testing.testingStoreWith(case, &refused, &tmp, std.testing.io, .{ .identity = "/different/canonical/store" }),
            );
        }
    }.run);
}
