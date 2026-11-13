//! Preset Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const store_testing = @import("../testing.zig");
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = shared_fixtures.TestingCall;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;

test "core_tools presets retain caller narrowing after overrides resolve" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("preset-agent-parent", "", workspace, "model-a");
            create.configuration.tools = try .of(&.{"start_agent"});
            try create.configuration.permission_mode.value.set("ask");
            const parent = (try storage.configure(&create, .{})).accepted.session;
            try submitTestMessage(&storage, &tmp, "preset-agent-message", "preset-agent-key", parent.slice(), "start children");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer memory.deinit();
            const arena = memory.allocator();
            const core_tools = @import("../../core_tools.zig");
            const spec = (try std.json.parseFromSliceLeaky(std.json.Value, arena,
                \\{"model":"gpt-6.1-sol","effort":"low","compactAt":1000,"tools":["bash"],"permissionMode":"bypass"}
            , .{})).object;
            const presets = [_]core_tools.Preset{.{ .name = "worker", .spec = spec }};
            const arguments = [_][]const u8{
                "{\"task\":\"read\",\"attached\":false,\"preset\":\"worker\",\"spec\":{\"tools\":[],\"permissionMode\":\"ask\"}}",
                "{\"task\":\"read\",\"attached\":false,\"preset\":\"worker\"}",
                "{\"task\":\"read\",\"attached\":false,\"preset\":\"worker\",\"spec\":{\"tools\":[]}}",
            };
            var calls: [arguments.len]TestingCall = undefined;
            for (arguments, &calls, 0..) |bytes, *call, at| {
                const id = try std.fmt.allocPrint(arena, "preset-{d}", .{at});
                const encoded = try std.json.Stringify.valueAlloc(arena, bytes, .{});
                call.* = .{ .item_id = id, .name = "start_agent", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = encoded[1 .. encoded.len - 1], .decoded_arguments = bytes };
            }
            try settleCallsForTesting(&storage, &tmp, model, "preset-agent-calls", &calls);
            const start = try arena.create(core_tools.StartAgent);
            for (arguments, 0..) |bytes, at| {
                const action = (try storage.nextCoreWork()).?.action;
                try std.testing.expect(try core_tools.checkStartAgentWithPresets(arena, bytes, &presets, start) == .accepted);
                const result = try storage.startAgent(action.binding, parent.slice(), start.task, start.attached, &start.configuration, null, .{});
                if (at == 0) {
                    try std.testing.expect(result == .started);
                } else {
                    try std.testing.expect(result == .failed);
                    const reason = if (at == 1)
                        "spec.tools: bash is not one of your tools. Nothing was started."
                    else
                        "spec.permissionMode: you ask before running commands, so your agents ask too. Nothing was started.";
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code='failed' AND c.digest=?2", .{ action.binding.action_id, store_testing.Blob{ .bytes = &protocol.contentDigest(reason) } }));
                }
            }
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
        }
    }.run);
}

test "preset unknown rejection survives reopen and later resolution" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var request: wire_request.ConfigureCommand = .{ .preset = .{} };
            try request.key.set("preset-unknown-replay");
            try request.preset.?.set("review");
            request.configuration.label.state = .value;
            try request.configuration.label.value.set("Review");
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const refused = try storage.configureWithPreset(&request, &.{ .request_digest = request.presetRequestDigest(), .rejection = .unknown_preset }, .{});
                try std.testing.expect(refused == .rejected and !refused.rejected.replayed);
                try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_preset, refused.rejected.code);
                const saved = try store_testing.observeCommandForTesting(&storage, request.key.slice());
                try std.testing.expectEqual(protocol.CommandObservationStatus.rejected, saved.status);
                try std.testing.expectEqualStrings("unknown_preset", saved.code.slice());
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            }
            {
                var reopened: Store = undefined;
                try store_testing.testingStore(case, &reopened, &tmp, std.testing.io);
                defer reopened.close() catch unreachable;
                // The restarted Host now knows review, but the same original
                // request must replay its rejection, not admit this full spec.
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var resolved = try completeConfiguration(request.key.slice(), "", workspace, "model-a");
                resolved.configuration.label = request.configuration.label;
                const replay = try reopened.configureWithPreset(&resolved, &.{ .request_digest = request.presetRequestDigest() }, .{});
                try std.testing.expect(replay == .rejected and replay.rejected.replayed);
                try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_preset, replay.rejected.code);
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&reopened, "SELECT count(*) FROM session", .{}));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&reopened, "SELECT count(*) FROM core_command", .{}));
                // Neither a different name nor different overrides share that
                // rejection's identity, even if they resolve to the same spec.
                try request.preset.?.set("other");
                try std.testing.expect(try reopened.configureWithPreset(&resolved, &.{ .request_digest = request.presetRequestDigest() }, .{}) == .conflict);
                try request.preset.?.set("review");
                try request.configuration.label.value.set("Changed");
                try std.testing.expect(try reopened.configureWithPreset(&resolved, &.{ .request_digest = request.presetRequestDigest() }, .{}) == .conflict);
                try std.testing.expect(try reopened.configure(&resolved, .{}) == .conflict);
            }
        }
    }.run);
}

test "preset refusal cannot replace an accepted configure key" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("preset-bound-key", "", workspace, "model-a");
            const first = try storage.configure(&create, .{});
            try std.testing.expect(first == .accepted);
            var request = create;
            request.preset = .{};
            try request.preset.?.set("missing");
            const result = try storage.configureWithPreset(&request, &.{ .request_digest = request.presetRequestDigest(), .rejection = .unknown_preset }, .{});
            try std.testing.expect(result == .conflict);
            const saved = try store_testing.observeCommandForTesting(&storage, create.key.slice());
            try std.testing.expectEqual(protocol.CommandObservationStatus.accepted, saved.status);
            try std.testing.expectEqualStrings(first.accepted.session.slice(), saved.target.slice());
            const replay = try storage.configure(&create, .{});
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            try std.testing.expectEqualStrings(first.accepted.session.slice(), replay.accepted.session.slice());
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
        }
    }.run);
}

test "preset on update rejection is durable and replayed before applying fields" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var request: wire_request.ConfigureCommand = .{ .preset = .{} };
            try request.key.set("preset-update-replay");
            try request.preset.?.set("review");
            request.configuration.label.state = .value;
            try request.configuration.label.value.set("Must not apply");
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var create = try completeConfiguration("preset-update-parent", "", workspace, "model-a");
                const first = try storage.configure(&create, .{});
                try std.testing.expect(first == .accepted);
                request.session = first.accepted.session;
                const refused = try storage.configureWithPreset(&request, &.{ .request_digest = request.presetRequestDigest(), .rejection = .preset_on_update }, .{});
                try std.testing.expect(refused == .rejected and !refused.rejected.replayed);
                try std.testing.expectEqual(protocol.ConfigurationRejection.preset_on_update, refused.rejected.code);
                const saved = try store_testing.observeCommandForTesting(&storage, request.key.slice());
                try std.testing.expectEqual(protocol.CommandObservationStatus.rejected, saved.status);
                try std.testing.expectEqualStrings("preset_on_update", saved.code.slice());
                try std.testing.expectEqualStrings(request.session.slice(), saved.target.slice());
                try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(request.session.slice())).revision);
            }
            {
                var reopened: Store = undefined;
                try store_testing.testingStore(case, &reopened, &tmp, std.testing.io);
                defer reopened.close() catch unreachable;
                const replay = try reopened.configureWithPreset(&request, &.{ .request_digest = request.presetRequestDigest(), .rejection = .preset_on_update }, .{});
                try std.testing.expect(replay == .rejected and replay.rejected.replayed);
                try std.testing.expectEqual(protocol.ConfigurationRejection.preset_on_update, replay.rejected.code);
                try request.preset.?.set("other");
                try std.testing.expect(try reopened.configureWithPreset(&request, &.{ .request_digest = request.presetRequestDigest(), .rejection = .preset_on_update }, .{}) == .conflict);
                request.preset = null;
                try std.testing.expect(try reopened.configure(&request, .{}) == .conflict);
                try std.testing.expectEqual(@as(u64, 1), (try reopened.inspectSessionForTesting(request.session.slice())).revision);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&reopened, "SELECT count(*) FROM session WHERE label IS NULL", .{}));
            }
        }
    }.run);
}
