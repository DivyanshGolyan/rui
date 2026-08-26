const std = @import("std");
const completion_inbox = @import("completion_inbox.zig");
const host_store = @import("host_store.zig");
const transition = @import("session_transition.zig");

fn pathFor(tmp: *const std.testing.TmpDir, out: []u8) ![]const u8 {
    return std.fmt.bufPrint(out, ".zig-cache/tmp/{s}/host.sqlite3", .{tmp.sub_path});
}

fn create(owner: *host_store.StorageOwner, id: u64) !void {
    try owner.createSession(.{ .session_id = id, .agent_id = id + 1, .task_id = id + 2, .branch_id = id + 3 });
}

fn encode(out: *[transition.max_payload_size]u8, sequence: u64, facts: []const transition.Fact) ![]const u8 {
    var value: transition.Transaction = .{ .sequence = sequence, .fact_count = @intCast(facts.len) };
    @memcpy(value.facts[0..facts.len], facts);
    return transition.encode(out, value);
}

test "one semantic commit occupies one ledger sequence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var owner = try host_store.StorageOwner.open(std.testing.io, try pathFor(&tmp, &path_buffer), .{});
    defer owner.close();
    try create(&owner, 11);
    const facts = [_]transition.Fact{
        .{ .kind = .task_admitted, .agent_id = 12, .agent_generation = 1, .ownership_epoch = 1, .subject = 13, .reference = 13 },
        .{ .kind = .conversation_advanced, .agent_id = 12, .agent_generation = 1, .ownership_epoch = 1, .subject = 1, .reference = 13 },
    };
    var buffer: [transition.max_payload_size]u8 = undefined;
    const payload = try encode(&buffer, 1, &facts);
    try std.testing.expectEqual(@as(u64, 1), try owner.commit(.{
        .token = .{ .session_id = 11, .epoch = 1 },
        .expected_sequence = 0,
        .payload = payload,
        .capacity_class = .admission,
        .conversations = &.{.{ .entry_id = 1, .parent_id = 0, .kind = 1, .content_ref = 13 }},
    }));
    var stored: host_store.StoredTransition = undefined;
    try owner.readTransition(11, 1, &stored);
    try std.testing.expectEqual(@as(u8, 2), (try transition.decode(1, stored.payloadSlice())).fact_count);
    try std.testing.expectError(error.TransitionNotFound, owner.readTransition(11, 2, &stored));
}

test "epoch and head are fenced by the same commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var owner = try host_store.StorageOwner.open(std.testing.io, try pathFor(&tmp, &path_buffer), .{});
    defer owner.close();
    try create(&owner, 21);
    _ = try owner.claimSession(21);
    var buffer: [transition.max_payload_size]u8 = undefined;
    const payload = try encode(&buffer, 1, &.{.{ .kind = .cancellation, .agent_id = 22, .agent_generation = 1, .ownership_epoch = 1 }});
    try std.testing.expectError(error.StaleOwnerOrSequenceConflict, owner.commit(.{
        .token = .{ .session_id = 21, .epoch = 1 },
        .expected_sequence = 0,
        .payload = payload,
    }));
    try std.testing.expectEqual(@as(u64, 0), try owner.sessionHead(21));
}

test "Conversation metadata and ledger publication are atomic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var owner = try host_store.StorageOwner.open(std.testing.io, try pathFor(&tmp, &path_buffer), .{});
    defer owner.close();
    try create(&owner, 31);
    var buffer: [transition.max_payload_size]u8 = undefined;
    const payload = try encode(&buffer, 1, &.{.{ .kind = .conversation_advanced, .agent_id = 32, .agent_generation = 1, .ownership_epoch = 1, .subject = 2, .reference = 39 }});
    _ = try owner.commit(.{
        .token = .{ .session_id = 31, .epoch = 1 },
        .expected_sequence = 0,
        .payload = payload,
        .conversations = &.{.{ .entry_id = 2, .parent_id = 1, .kind = 2, .content_ref = 39 }},
    });
    const entry = try owner.readConversationEntry(31, 2);
    try std.testing.expectEqual(@as(?u64, 1), entry.committed_by_sequence);
    try std.testing.expectEqual(@as(u64, 1), entry.parent_id);
}

test "multiple Completion rows can be consumed by one semantic commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var owner = try host_store.StorageOwner.open(std.testing.io, try pathFor(&tmp, &path_buffer), .{});
    defer owner.close();
    try create(&owner, 41);
    const first: completion_inbox.Envelope = .{ .kind = .model, .session_id = 41, .ownership_epoch = 1, .agent_id = 42, .agent_generation = 1, .operation_id = 50, .operation_generation = 1, .attempt_id = 60, .result_ref = 70, .result_digest = 80 };
    var second = first;
    second.operation_id = 51;
    second.attempt_id = 61;
    second.result_ref = 71;
    second.result_digest = 81;
    _ = try owner.publishCompletion(first);
    _ = try owner.publishCompletion(second);
    const facts = [_]transition.Fact{
        .{ .kind = .result, .agent_id = 42, .agent_generation = 1, .ownership_epoch = 1, .operation_id = 50, .generation = 1, .attempt_id = 60, .reference = 70, .digest = 80, .recovery_class = .model, .disposition = .terminal, .evidence_kind = 1 },
        .{ .kind = .result, .agent_id = 42, .agent_generation = 1, .ownership_epoch = 1, .operation_id = 51, .generation = 1, .attempt_id = 61, .reference = 71, .digest = 81, .recovery_class = .model, .disposition = .terminal, .evidence_kind = 1 },
    };
    var buffer: [transition.max_payload_size]u8 = undefined;
    const payload = try encode(&buffer, 1, &facts);
    _ = try owner.commit(.{
        .token = .{ .session_id = 41, .epoch = 1 },
        .expected_sequence = 0,
        .payload = payload,
        .completions = &.{
            .{ .ownership_epoch = 1, .agent_id = 42, .agent_generation = 1, .operation_id = 50, .operation_generation = 1, .attempt_id = 60, .evidence_kind = 1, .result_reference = 70, .result_digest = 80 },
            .{ .ownership_epoch = 1, .agent_id = 42, .agent_generation = 1, .operation_id = 51, .operation_generation = 1, .attempt_id = 61, .evidence_kind = 1, .result_reference = 71, .result_digest = 81 },
        },
    });
    try std.testing.expectEqual(@as(?u64, 1), (try owner.readCompletion(41, 1)).consumed_by_sequence);
    try std.testing.expectEqual(@as(?u64, 1), (try owner.readCompletion(41, 2)).consumed_by_sequence);
}

test "the Host Store lock and memory envelope are host scoped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try pathFor(&tmp, &path_buffer);
    var first = try host_store.StorageOwner.open(std.testing.io, path, .{});
    try std.testing.expectError(error.HostStoreBusy, host_store.StorageOwner.open(std.testing.io, path, .{}));
    const accounting = try first.memoryAccounting(false);
    try std.testing.expect(accounting.heap_current_bytes <= accounting.allowance_bytes);
    first.close();
    var next = try host_store.StorageOwner.open(std.testing.io, path, .{});
    next.close();
}
