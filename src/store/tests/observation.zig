//! Observation Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const change_ring = @import("../../change_ring.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const command_domain = @import("../domain/command.zig");
const store_testing = @import("../testing.zig");
const AttemptBinding = store_core.AttemptBinding;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const submitTestMessage = store_testing.submitTestMessage;
const configureTestSessionWithMode = shared_fixtures.configureTestSessionWithMode;
const recoverPairForTesting = shared_fixtures.recoverPairForTesting;
const settleMessagesForTesting = shared_fixtures.settleMessagesForTesting;
const testingSessionReportWithExecution = shared_fixtures.testingSessionReportWithExecution;

test "Message request state has one Host precedence rule" {
    var observed: command_domain.CommandObservation = .{ .status = .rejected, .kind = .{ .message = null } };
    try std.testing.expectEqual(protocol.MessageRequestState.rejected, observed.requestState().?);
    observed.status = .accepted;
    observed.kind.message = .{
        .content = .{ .length = 0, .digest = @splat(0) },
        .queue = .{ .admission_id = 1, .state = .queued },
        .work = .{ .state = .{ .idle = .{ .since = 1 } } },
    };
    try std.testing.expectEqual(protocol.MessageRequestState.queued, observed.requestState().?);
    observed.kind.message.?.work.?.state = .{ .approval = .{ .since = 2 } };
    // A queued admission behind another Turn needing approval also waits.
    try std.testing.expectEqual(protocol.MessageRequestState.waiting_for_permission, observed.requestState().?);
    const binding: AttemptBinding = .{ .turn_id = 3, .operation_id = 4, .attempt_ordinal = 1 };
    observed.kind.message.?.queue.?.state = .{ .processing = binding };
    try std.testing.expectEqual(protocol.MessageRequestState.waiting_for_permission, observed.requestState().?);
    observed.kind.message.?.work.?.state = .{ .working = .{ .since = 3 } };
    try std.testing.expectEqual(protocol.MessageRequestState.processing, observed.requestState().?);
    observed.kind.message.?.work.?.state = .{ .approval = .{ .since = 2 } };
    observed.kind.message.?.queue.?.state = .{ .completed = .{ .binding = binding, .answer = .{ .length = 0, .digest = @splat(0) } } };
    try std.testing.expectEqual(protocol.MessageRequestState.completed, observed.requestState().?);
    observed.kind.message.?.queue.?.state = .{ .failed = .{ .binding = binding, .code = .{} } };
    try std.testing.expectEqual(protocol.MessageRequestState.failed, observed.requestState().?);
    observed.kind.message.?.queue.?.state = .{ .cancelled = .{ .binding = binding, .code = .{} } };
    try std.testing.expectEqual(protocol.MessageRequestState.cancelled, observed.requestState().?);
    observed.kind.message.?.queue.?.state = .{ .excluded = .{ .code = .{} } };
    try std.testing.expectEqual(protocol.MessageRequestState.cancelled, observed.requestState().?);
    observed.kind = .{ .configure = .{} };
    try std.testing.expect(observed.requestState() == null);
    observed.status = .absent;
    try std.testing.expect(observed.requestState() == null);
}

test "Message observation keeps bounded newest Action recovery across continuation and completion" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionWithMode(&storage, "recovery-config", "bypass");
            try submitTestMessage(&storage, &tmp, "recovery-input", "recovery-message", session.slice(), "run commands");
            var observation = try store_testing.observeCommandForTesting(&storage, "recovery-message");
            try std.testing.expectEqual(protocol.MessageRequestState.queued, observation.requestState().?);
            try std.testing.expect(observation.kind.message.?.admitted_at > 0);
            try std.testing.expect(observation.kind.message.?.work != null);
            try std.testing.expectEqual(@as(u8, 0), observation.kind.message.?.recovery.count);
            var ids: [6]u64 = undefined;
            var operations: [3]u64 = undefined;
            var turn: u64 = 0;
            for (0..3) |i| {
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                if (i == 0) turn = binding.turn_id;
                try std.testing.expectEqual(turn, binding.turn_id);
                operations[i] = binding.operation_id;
                var prefix: [32]u8 = undefined;
                const pair = try recoverPairForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&prefix, "recovery-{d}", .{i}));
                @memcpy(ids[i * 2 ..][0..2], &pair);
                observation = try store_testing.observeCommandForTesting(&storage, "recovery-message");
                const recovery = &observation.kind.message.?.recovery;
                try std.testing.expectEqual(@as(u8, @intCast(@min((i + 1) * 2, 4))), recovery.count);
                try std.testing.expectEqual(i == 2, recovery.more);
                try std.testing.expectEqual(pair[1], recovery.calls[0].action_id);
                try std.testing.expectEqual(binding.operation_id, recovery.calls[0].operation_id);
                try std.testing.expectEqual(@as(u64, 1), recovery.calls[0].call);
                try std.testing.expectEqualStrings("Run second command", recovery.calls[0].description.?.slice());
                try std.testing.expect(recovery.calls[0].at > 0);
            }
            const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleMessagesForTesting(&storage, &tmp, continuation, 1, false, null);
            observation = try store_testing.observeCommandForTesting(&storage, "recovery-message");
            try std.testing.expectEqual(protocol.MessageRequestState.completed, observation.requestState().?);
            try std.testing.expect(observation.kind.message.?.work == null);
            try std.testing.expectEqual(continuation.operation_id, observation.kind.message.?.queue.?.state.completed.binding.operation_id);
            const recovery = &observation.kind.message.?.recovery;
            for (recovery.calls[0..recovery.count], 0..) |call, i| {
                try std.testing.expectEqual(ids[5 - i], call.action_id);
                try std.testing.expectEqual(operations[(5 - i) / 2], call.operation_id);
            }
            // A later Turn does not inherit old recovery, and its own recovery
            // cannot backfill this completed request's bounded Operation range.
            try submitTestMessage(&storage, &tmp, "recovery-next-input", "recovery-next", session.slice(), "next");
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var newer = try store_testing.observeCommandForTesting(&storage, "recovery-next");
            try std.testing.expectEqual(@as(u8, 0), newer.kind.message.?.recovery.count);
            _ = try recoverPairForTesting(&storage, &tmp, next, "recovery-next-calls");
            newer = try store_testing.observeCommandForTesting(&storage, "recovery-next");
            try std.testing.expectEqual(@as(u8, 2), newer.kind.message.?.recovery.count);
            observation = try store_testing.observeCommandForTesting(&storage, "recovery-message");
            try std.testing.expectEqual(ids[5], observation.kind.message.?.recovery.calls[0].action_id);
        }
    }.run);
}

test "observation since sibling Session commit advances an unchanged token" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("observe-parent", "", workspace, "model-a");
            const parent = try storage.configure(&create, .{});
            try std.testing.expect(parent == .accepted);
            var observed: store_core.Observed = undefined;
            try storage.observeCommand("observe-parent", null, &observed);
            try std.testing.expect(observed == .full);
            const token = observed.full.token.?;
            try std.testing.expectEqualSlices(u8, parent.accepted.session.slice(), &token.session);
            try std.testing.expectEqual(storage.commit_generation.load(.acquire), token.generation);
            try storage.observeCommand("observe-parent", token, &observed);
            try std.testing.expect(observed == .not_modified);
            try std.testing.expectEqualDeep(token, observed.not_modified);

            var sibling = try completeConfiguration("observe-sibling", "", workspace, "model-a");
            try std.testing.expect(try storage.configure(&sibling, .{}) == .accepted);
            const generation = storage.commit_generation.load(.acquire);
            try std.testing.expect(generation > token.generation);
            try storage.observeCommand("observe-parent", token, &observed);
            try std.testing.expect(observed == .not_modified);
            try std.testing.expectEqualDeep(token.at(generation), observed.not_modified);
        }
    }.run);
}

test "observation since own Session commit reads full at its generation" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("observe-own", "", workspace, "model-a");
            const parent = try storage.configure(&create, .{});
            try std.testing.expect(parent == .accepted);
            var observed: store_core.Observed = undefined;
            try storage.observeCommand("observe-own", null, &observed);
            try std.testing.expect(observed == .full);
            const token = observed.full.token.?;
            var update = try completeConfiguration("observe-update", parent.accepted.session.slice(), workspace, "model-a");
            update.configuration.label.state = .value;
            try update.configuration.label.value.set("Changed");
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            const generation = storage.commit_generation.load(.acquire);
            try std.testing.expect(generation > token.generation);
            try storage.observeCommand("observe-own", token, &observed);
            try std.testing.expect(observed == .full);
            try std.testing.expectEqualDeep(token.at(generation), observed.full.token.?);
            try std.testing.expectEqual(protocol.CommandObservationStatus.accepted, observed.full.observation.status);
            try std.testing.expectEqualStrings(parent.accepted.session.slice(), observed.full.observation.target.slice());
        }
    }.run);
}

test "observation since falls back for foreign future uncovered and restarted tokens" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var saved: change_ring.SessionToken = undefined;
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var create = try completeConfiguration("observe-fallback", "", workspace, "model-a");
                try std.testing.expect(try storage.configure(&create, .{}) == .accepted);
                var observed: store_core.Observed = undefined;
                try storage.observeCommand("observe-fallback", null, &observed);
                try std.testing.expect(observed == .full);
                saved = observed.full.token.?;
                var foreign = saved;
                foreign.instance[0] ^= 1;
                try expectFull(&storage, foreign, saved, &observed);
                try expectFull(&storage, saved.at(saved.generation + 1), saved, &observed);

                // An older token is uncovered after the ring has forgotten a
                // generation, even when that generation only names a sibling.
                var sibling = try completeConfiguration("observe-fallback-sibling", "", workspace, "model-a");
                try std.testing.expect(try storage.configure(&sibling, .{}) == .accepted);
                const generation = storage.commit_generation.load(.acquire);
                storage.changes.forget(generation);
                try std.testing.expect(!storage.changes.covers(saved.generation));
                try expectFull(&storage, saved, saved.at(generation), &observed);
            }
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var observed: store_core.Observed = undefined;
                try storage.observeCommand("observe-fallback", saved, &observed);
                try std.testing.expect(observed == .full);
                const token = observed.full.token.?;
                try std.testing.expect(!std.mem.eql(u8, &saved.instance, &token.instance));
                try std.testing.expectEqualSlices(u8, &storage.instance, &token.instance);
                try std.testing.expectEqualSlices(u8, &saved.session, &token.session);
                try std.testing.expectEqual(storage.commit_generation.load(.acquire), token.generation);
            }
        }

        fn expectFull(storage: *Store, since: change_ring.SessionToken, expected: change_ring.SessionToken, observed: *store_core.Observed) !void {
            try storage.observeCommand("observe-fallback", since, observed);
            try std.testing.expect(observed.* == .full);
            try std.testing.expectEqualDeep(expected, observed.full.token.?);
            try std.testing.expectEqual(protocol.CommandObservationStatus.accepted, observed.full.observation.status);
        }
    }.run);
}

test "observation since leaves absent and non Session targets untokened and reports fencing" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var observed: store_core.Observed = undefined;
            try storage.observeCommand("observe-absent", null, &observed);
            try std.testing.expect(observed == .full);
            try std.testing.expectEqual(protocol.CommandObservationStatus.absent, observed.full.observation.status);
            try std.testing.expect(observed.full.token == null);
            var request: wire_request.ConfigureCommand = .{ .preset = .{} };
            try request.key.set("observe-no-session");
            try request.preset.?.set("missing");
            const rejected = try storage.configureWithPreset(&request, &.{ .request_digest = request.presetRequestDigest(), .rejection = .unknown_preset }, .{});
            try std.testing.expect(rejected == .rejected);
            try storage.observeCommand("observe-no-session", null, &observed);
            try std.testing.expect(observed == .full);
            try std.testing.expectEqual(protocol.CommandObservationStatus.rejected, observed.full.observation.status);
            try std.testing.expect(!protocol.validSessionId(observed.full.observation.target.slice()));
            try std.testing.expect(observed.full.token == null);

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("observe-before-fence", "", workspace, "model-a");
            try std.testing.expect(try storage.configure(&create, .{}) == .accepted);
            try storage.observeCommand("observe-before-fence", null, &observed);
            try std.testing.expect(observed == .full);
            const token = observed.full.token.?;
            var failed = try completeConfiguration("observe-fence", "", workspace, "model-a");
            try std.testing.expect(try storage.configure(&failed, .{ .before_commit = true }) == .infrastructure_failure);
            try std.testing.expectError(error.StoreFenced, storage.observeCommand("observe-before-fence", token, &observed));
            try std.testing.expectError(error.StoreFenced, storage.observeCommand("observe-before-fence", null, &observed));
        }
    }.run);
}

test "activity since sibling commit preserves end and own commit returns new items" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("activity-token-parent", "", workspace, "model-a");
            const parent = (try storage.configure(&create, .{})).accepted.session;
            var request: protocol.ActivityPage = .{};
            try request.session.set(parent.slice());
            var page: protocol.ActivityFacts = undefined;
            try storage.activityPage(&request, &page);
            try std.testing.expect(!page.not_modified);
            const token = page.token.?;
            const end = page.end;
            request.position = end;
            request.since = token;
            try storage.activityPage(&request, &page);
            try std.testing.expect(page.not_modified);
            try std.testing.expectEqualDeep(token, page.token.?);
            // The unchanged answer deliberately leaves the caller's page intact.
            try std.testing.expectEqual(end, page.end);
            // Bounded and backward traversals must not reuse a follow hint.
            request.end = end;
            try storage.activityPage(&request, &page);
            try std.testing.expect(!page.not_modified);
            try std.testing.expect(page.token == null);
            request.end = null;
            request.direction = .backward;
            try storage.activityPage(&request, &page);
            try std.testing.expect(!page.not_modified);
            try std.testing.expect(page.token == null);
            request.direction = .forward;
            var sibling = try completeConfiguration("activity-token-sibling", "", workspace, "model-a");
            const sibling_session = (try storage.configure(&sibling, .{})).accepted.session;
            try storage.activityPage(&request, &page);
            try std.testing.expect(page.not_modified);
            try std.testing.expectEqualDeep(token.at(storage.commit_generation.load(.acquire)), page.token.?);
            try std.testing.expectEqual(end, page.end);
            var update = try completeConfiguration("activity-token-update", parent.slice(), workspace, "model-a");
            update.configuration.label.state = .value;
            try update.configuration.label.value.set("Own change");
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try storage.activityPage(&request, &page);
            try std.testing.expect(!page.not_modified);
            try std.testing.expect(page.count > 0);
            try std.testing.expectEqualDeep(token.at(storage.commit_generation.load(.acquire)), page.token.?);
            // A second changed field gives this fixture two actual public rows.
            var second_update = try completeConfiguration("activity-token-second-update", parent.slice(), workspace, "model-a");
            second_update.configuration.label.state = .value;
            try second_update.configuration.label.value.set("Second own change");
            try std.testing.expect(try storage.configure(&second_update, .{}) == .accepted);
            // A page with unread lookahead cannot issue a follow token.
            request.position = 0;
            request.limit = 1;
            request.since = null;
            try storage.activityPage(&request, &page);
            try std.testing.expect(page.more);
            try std.testing.expect(page.token == null);
            request.position = end;
            request.limit = protocol.ActivityPage.items;
            request.since = token;
            try submitTestMessage(&storage, &tmp, "activity-token-message", "activity-token-message", parent.slice(), "new item");
            try storage.activityPage(&request, &page);
            try std.testing.expect(!page.not_modified);
            try std.testing.expect(page.end > end);
            try std.testing.expect(page.count > 0);
            // A queued message is pending: it cannot grant a token because
            // pending also represents a retry whose deadline has elapsed.
            try std.testing.expect(page.token == null);
            var found = false;
            for (page.items[0..page.count]) |*item| {
                found = found or item.value == .admission;
            }
            try std.testing.expect(found);
            // A token for the sibling must never suppress this Session's read.
            request.since.?.session = sibling_session.slice()[0..protocol.session_id_bytes].*;
            try storage.activityPage(&request, &page);
            try std.testing.expect(!page.not_modified);
        }
    }.run);
}

test "Current remains full when execution changes without a Session commit" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("current-uncacheable", "", workspace, "model-a");
            const session = (try storage.configure(&create, .{})).accepted.session;
            const generation = storage.commit_generation.load(.acquire);
            for ([_]usize{ 0, 1 }) |occupied| {
                const bytes = try testingSessionReportWithExecution(&storage, &tmp, session.slice(), 1024 * 1024, .current, .{
                    .dispatch_fenced = occupied != 0,
                    .custody_occupied = occupied,
                    .scratch_used_bytes = occupied * 4096,
                });
                defer std.testing.allocator.free(bytes);
                const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                defer parsed.deinit();
                const object = parsed.value.object;
                try std.testing.expectEqualStrings("full", object.get("delta").?.string);
                try std.testing.expect(object.get("since").? == .null);
                const execution = object.get("execution").?.object;
                try std.testing.expectEqual(occupied != 0, execution.get("dispatch_fenced").?.bool);
                try std.testing.expectEqualStrings(if (occupied == 0) "0" else "1", execution.get("custody_occupied").?.string);
                try std.testing.expectEqualStrings(if (occupied == 0) "0" else "4096", execution.get("scratch_used_bytes").?.string);
                try std.testing.expectEqual(generation, storage.commit_generation.load(.acquire));
            }
        }
    }.run);
}
