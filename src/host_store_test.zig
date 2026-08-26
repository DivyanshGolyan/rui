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
    const agent: transition.AgentContext = .{
        .agent_id = 12,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    const facts = [_]transition.Fact{
        transition.taskAdmitted(agent, 13, 13),
        transition.conversationAdvanced(agent, 1, 13),
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
    const payload = try encode(&buffer, 1, &.{transition.cancellation(.{
        .agent_id = 22,
        .agent_generation = 1,
        .ownership_epoch = 1,
    })});
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
    const payload = try encode(&buffer, 1, &.{transition.conversationAdvanced(.{
        .agent_id = 32,
        .agent_generation = 1,
        .ownership_epoch = 1,
    }, 2, 39)});
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
    const agent: transition.AgentContext = .{
        .agent_id = 42,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    const facts = [_]transition.Fact{
        transition.result(.{
            .operation = .{ .agent = agent, .operation_id = 50, .generation = 1 },
            .result_ref = 70,
            .result_digest = 80,
            .class = .ordinary,
            .evidence = .{ .durable = .{ .model = 60 } },
        }),
        transition.result(.{
            .operation = .{ .agent = agent, .operation_id = 51, .generation = 1 },
            .result_ref = 71,
            .result_digest = 81,
            .class = .ordinary,
            .evidence = .{ .durable = .{ .model = 61 } },
        }),
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

test "the Host Store lock is host scoped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try pathFor(&tmp, &path_buffer);
    var first = try host_store.StorageOwner.open(std.testing.io, path, .{});
    try std.testing.expectError(error.HostStoreBusy, host_store.StorageOwner.open(std.testing.io, path, .{}));
    first.close();
    var next = try host_store.StorageOwner.open(std.testing.io, path, .{});
    next.close();
}

test "host memory remains bounded across cache profiles and Session populations" {
    inline for (.{ @as(u16, 32), @as(u16, 64), @as(u16, 128) }) |profile| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path_buffer: [256]u8 = undefined;
        var owner = try host_store.StorageOwner.open(
            std.testing.io,
            try pathFor(&tmp, &path_buffer),
            .{ .page_cache_kib = profile },
        );
        defer owner.close();
        _ = try owner.memoryAccounting(true);

        inline for (.{ @as(u64, 32), @as(u64, 128) }) |population| {
            var next_id: u64 = if (population == 32) 1 else 33;
            while (next_id <= population) : (next_id += 1) try create(&owner, next_id * 4);
            const accounting = try owner.memoryAccounting(false);
            try std.testing.expect(accounting.heap_current_bytes <= accounting.allowance_bytes);
            try std.testing.expect(accounting.heap_highwater_bytes <= accounting.allowance_bytes);
            try std.testing.expect(accounting.page_cache_current_bytes > 0);
            try std.testing.expect(accounting.page_cache_current_bytes <= @as(u64, profile) * 2048);
            try std.testing.expect(accounting.lookaside_current_slots <= accounting.lookaside_highwater_slots);
            try std.testing.expectEqual(@as(u64, 0), accounting.statements_current_bytes);
        }
    }
}
