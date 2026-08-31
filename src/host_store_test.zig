const std = @import("std");
const binding = @import("binding.zig");
const completion_inbox = @import("completion_inbox.zig");
const host_store = @import("host_store.zig");
const transition = @import("session_transition.zig");

fn pathFor(tmp: *const std.testing.TmpDir, out: []u8) ![]const u8 {
    return std.fmt.bufPrint(out, ".zig-cache/tmp/{s}/host.sqlite3", .{tmp.sub_path});
}

fn create(owner: *host_store.StorageOwner, id: u64) !void {
    try owner.createSession(.{ .session_id = id, .agent_id = id + 1, .task_id = id + 2 });
}

fn transaction(sequence: u64, facts: []const transition.Fact) transition.Transaction {
    var value: transition.Transaction = .{ .sequence = sequence, .fact_count = @intCast(facts.len) };
    @memcpy(value.facts[0..facts.len], facts);
    return value;
}

fn content(reference: u64) host_store.ContentImport {
    const bytes = "host-store-test-content";
    return .{
        .reference = reference,
        .length = bytes.len,
        .digest = binding.hash(binding.Blob, bytes),
        .source = .{ .bytes = bytes },
    };
}

fn directContent(reference: u64) host_store.TransactionContentImport {
    return .{ .transaction_fact = content(reference) };
}

fn pendingPublication(
    envelope: completion_inbox.Envelope,
    result: host_store.CompletionResult,
) host_store.CompletionPublication {
    return .{ .pending = .{ .envelope = envelope, .result = result } };
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
        transition.conversationAdvanced(.{
            .agent = agent,
            .entry_id = 2,
            .parent_id = 1,
            .kind = .assistant_text,
            .content_ref = 14,
        }),
    };
    try std.testing.expectEqual(
        @as(u64, 2),
        try owner.commitPrepared(
            .{ .session_id = 11, .epoch = 1 },
            .{ .transaction = transaction(2, &facts), .content = &.{directContent(14)} },
        ),
    );
    var stored: host_store.StoredTransition = undefined;
    try owner.readTransition(11, 2, &stored);
    try std.testing.expectEqual(@as(u8, 1), stored.transaction.fact_count);
    try std.testing.expectError(error.TransitionNotFound, owner.readTransition(11, 3, &stored));
}

test "historical Completion scan rejects an Attempt admitted after its terminal Result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var owner = try host_store.StorageOwner.open(std.testing.io, try pathFor(&tmp, &path_buffer), .{});
    defer owner.close();
    try create(&owner, 15);
    const agent: transition.AgentContext = .{
        .agent_id = 16,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    const operation: transition.OperationContext = .{
        .agent = agent,
        .operation_id = 20,
        .generation = 1,
    };
    const descriptor: binding.Descriptor = .{
        .model = binding.hash(binding.ModelDescriptor, "historical-ordering"),
    };
    _ = try owner.commitPrepared(.{ .session_id = 15, .epoch = 1 }, .{
        .transaction = transaction(2, &.{
            transition.operationSubmitted(operation, 21, descriptor, .model),
            transition.result(.{
                .operation = operation,
                .result_ref = 22,
                .result_digest = binding.hash(binding.Result, "terminal-before-attempt"),
                .class = .ordinary,
                .evidence = .{ .immediate = .model },
            }),
        }),
        .content = &.{ directContent(21), directContent(22) },
    });
    _ = try owner.commit(.{ .session_id = 15, .epoch = 1 }, transaction(3, &.{
        transition.modelAttemptAdmitted(operation, 23, 21, descriptor, 0),
    }));

    var scan: host_store.CompletedAttemptScan = .{};
    try std.testing.expectError(
        error.InvalidHistoricalCompletionOrdering,
        owner.scanCompletedAttemptWindow(15, 20, 1, 23, 3, 3, &scan),
    );
}

test "historical Completion scan requires the Result to share the Attempt context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var owner = try host_store.StorageOwner.open(std.testing.io, try pathFor(&tmp, &path_buffer), .{});
    defer owner.close();
    try create(&owner, 25);
    const admitted_operation: transition.OperationContext = .{
        .agent = .{ .agent_id = 26, .agent_generation = 1, .ownership_epoch = 1 },
        .operation_id = 30,
        .generation = 1,
    };
    const descriptor: binding.Descriptor = .{
        .model = binding.hash(binding.ModelDescriptor, "historical-relationship"),
    };
    _ = try owner.commitPrepared(.{ .session_id = 25, .epoch = 1 }, .{
        .transaction = transaction(2, &.{
            transition.operationSubmitted(admitted_operation, 31, descriptor, .model),
            transition.modelAttemptAdmitted(admitted_operation, 32, 31, descriptor, 0),
        }),
        .content = &.{directContent(31)},
    });
    const claimed_epoch = try owner.claimSession(25);
    var terminal_operation = admitted_operation;
    terminal_operation.agent.ownership_epoch = claimed_epoch;
    _ = try owner.commitPrepared(.{ .session_id = 25, .epoch = claimed_epoch }, .{
        .transaction = transaction(3, &.{transition.result(.{
            .operation = terminal_operation,
            .result_ref = 33,
            .result_digest = binding.hash(binding.Result, "mismatched-terminal-context"),
            .class = .ordinary,
            .evidence = .{ .immediate = .model },
        })}),
        .content = &.{directContent(33)},
    });

    var scan: host_store.CompletedAttemptScan = .{};
    try std.testing.expectError(
        error.InvalidHistoricalCompletionRelationship,
        owner.scanCompletedAttemptWindow(25, 30, 1, 32, 3, 3, &scan),
    );
}

test "epoch and head are fenced by the same commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var owner = try host_store.StorageOwner.open(std.testing.io, try pathFor(&tmp, &path_buffer), .{});
    defer owner.close();
    try create(&owner, 21);
    _ = try owner.claimSession(21);
    const value = transaction(2, &.{transition.cancellation(.{
        .agent_id = 22,
        .agent_generation = 1,
        .ownership_epoch = 1,
    })});
    try std.testing.expectError(
        error.StaleOwnerOrSequenceConflict,
        owner.commit(.{ .session_id = 21, .epoch = 1 }, value),
    );
    try std.testing.expectEqual(@as(u64, 1), try owner.sessionHead(21));
}

test "Storage Owner rejects malformed or mismatched typed commit identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var owner = try host_store.StorageOwner.open(std.testing.io, try pathFor(&tmp, &path_buffer), .{});
    defer owner.close();
    try create(&owner, 25);

    const oversized: transition.Transaction = .{
        .sequence = 2,
        .fact_count = transition.max_facts + 1,
    };
    try std.testing.expectError(
        error.InvalidTransaction,
        owner.commit(.{ .session_id = 25, .epoch = 1 }, oversized),
    );

    const wrong_agent = transaction(2, &.{transition.cancellation(.{
        .agent_id = 999,
        .agent_generation = 1,
        .ownership_epoch = 1,
    })});
    try std.testing.expectError(
        error.StaleOwnerOrSequenceConflict,
        owner.commit(.{ .session_id = 25, .epoch = 1 }, wrong_agent),
    );
    try std.testing.expectEqual(@as(u64, 1), try owner.sessionHead(25));
}

test "Completion publication validates the Session Agent identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var owner = try host_store.StorageOwner.open(std.testing.io, try pathFor(&tmp, &path_buffer), .{});
    defer owner.close();
    try create(&owner, 27);

    try std.testing.expectError(error.InvalidCompletionIdentity, owner.publishCompletion(pendingPublication(completion_inbox.bind(.{
        .kind = .model,
        .session_id = 27,
        .ownership_epoch = 1,
        .agent_id = 999,
        .agent_generation = 1,
        .operation_id = 30,
        .operation_generation = 1,
        .attempt_id = 31,
        .result_ref = 32,
        .result_digest = binding.hash(binding.Result, "result-33"),
    }), .existing)));
    try std.testing.expectEqual(@as(u64, 0), try owner.completionHead(27));
}

test "Conversation metadata and ledger publication are atomic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var owner = try host_store.StorageOwner.open(std.testing.io, try pathFor(&tmp, &path_buffer), .{});
    defer owner.close();
    try create(&owner, 31);
    const value = transaction(2, &.{transition.conversationAdvanced(.{
        .agent = .{
            .agent_id = 32,
            .agent_generation = 1,
            .ownership_epoch = 1,
        },
        .entry_id = 2,
        .parent_id = 1,
        .kind = .assistant_text,
        .content_ref = 39,
    })});
    _ = try owner.commitPrepared(.{ .session_id = 31, .epoch = 1 }, .{
        .transaction = value,
        .content = &.{directContent(39)},
    });
    const entry = try owner.readConversationEntry(31, 2);
    try std.testing.expectEqual(@as(u64, 2), entry.committed_by_sequence);
    try std.testing.expectEqual(@as(u64, 1), entry.parent_id);
}

test "multiple Completion rows can be consumed by one semantic commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var owner = try host_store.StorageOwner.open(std.testing.io, try pathFor(&tmp, &path_buffer), .{});
    defer owner.close();
    try create(&owner, 41);
    const first = completion_inbox.bind(.{ .kind = .model, .session_id = 41, .ownership_epoch = 1, .agent_id = 42, .agent_generation = 1, .operation_id = 50, .operation_generation = 1, .attempt_id = 60, .result_ref = 70, .result_digest = binding.hash(binding.Result, "result-80") });
    var second = first;
    second.operation_id = 51;
    second.attempt_id = 61;
    second.result_ref = 71;
    second.result_digest = binding.hash(binding.Result, "result-81");
    second = completion_inbox.bind(.{
        .kind = second.kind,
        .session_id = second.session_id,
        .ownership_epoch = second.ownership_epoch,
        .agent_id = second.agent_id,
        .agent_generation = second.agent_generation,
        .operation_id = second.operation_id,
        .operation_generation = second.operation_generation,
        .attempt_id = second.attempt_id,
        .result_ref = second.result_ref,
        .result_digest = second.result_digest,
    });
    _ = try owner.publishCompletion(pendingPublication(first, .{ .first_import = content(70) }));
    _ = try owner.publishCompletion(pendingPublication(second, .{ .first_import = content(71) }));
    const agent: transition.AgentContext = .{
        .agent_id = 42,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    const facts = [_]transition.Fact{
        transition.result(.{
            .operation = .{ .agent = agent, .operation_id = 50, .generation = 1 },
            .result_ref = 70,
            .result_digest = binding.hash(binding.Result, "result-80"),
            .class = .ordinary,
            .evidence = .{ .durable = .{ .model = 60 } },
        }),
        transition.result(.{
            .operation = .{ .agent = agent, .operation_id = 51, .generation = 1 },
            .result_ref = 71,
            .result_digest = binding.hash(binding.Result, "result-81"),
            .class = .ordinary,
            .evidence = .{ .durable = .{ .model = 61 } },
        }),
    };
    _ = try owner.commit(.{ .session_id = 41, .epoch = 1 }, transaction(2, &facts));
    try std.testing.expectEqual(@as(?u64, 2), (try owner.readCompletion(41, 1)).consumed_by_sequence);
    try std.testing.expectEqual(@as(?u64, 2), (try owner.readCompletion(41, 2)).consumed_by_sequence);
    try std.testing.expectEqual(@as(u64, 0), try owner.completionHead(41));
    try std.testing.expect((try owner.readCompletionAfter(41, 0, 2)) == null);
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

test "Storage Owner serializes a complete transaction against concurrent reads" {
    const Gate = struct {
        entered: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),

        fn reached(context: *anyopaque, boundary: host_store.FaultBoundary) !void {
            if (boundary != .after_transition_head_advance) return;
            const self: *@This() = @ptrCast(@alignCast(context));
            self.entered.store(true, .release);
            while (!self.release.load(.acquire)) std.atomic.spinLoopHint();
        }
    };
    const CommitThread = struct {
        fn run(owner: *host_store.StorageOwner) void {
            const value = transaction(2, &.{transition.cancellation(.{
                .agent_id = 52,
                .agent_generation = 1,
                .ownership_epoch = 1,
            })});
            _ = owner.commit(.{ .session_id = 51, .epoch = 1 }, value) catch unreachable;
        }
    };
    const ReadThread = struct {
        fn run(
            owner: *host_store.StorageOwner,
            started: *std.atomic.Value(bool),
            finished: *std.atomic.Value(bool),
        ) void {
            started.store(true, .release);
            _ = owner.sessionHead(51) catch unreachable;
            finished.store(true, .release);
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var gate: Gate = .{};
    var path_buffer: [256]u8 = undefined;
    var owner = try host_store.StorageOwner.open(
        std.testing.io,
        try pathFor(&tmp, &path_buffer),
        .{ .fault = .{ .context = &gate, .reached = Gate.reached } },
    );
    defer owner.close();
    try create(&owner, 51);

    const commit_thread = try std.Thread.spawn(.{}, CommitThread.run, .{&owner});
    while (!gate.entered.load(.acquire)) std.atomic.spinLoopHint();
    var read_started: std.atomic.Value(bool) = .init(false);
    var read_finished: std.atomic.Value(bool) = .init(false);
    const read_thread = try std.Thread.spawn(
        .{},
        ReadThread.run,
        .{ &owner, &read_started, &read_finished },
    );
    while (!read_started.load(.acquire)) std.atomic.spinLoopHint();
    for (0..10_000) |_| std.atomic.spinLoopHint();
    try std.testing.expect(!read_finished.load(.acquire));
    gate.release.store(true, .release);
    commit_thread.join();
    read_thread.join();
    try std.testing.expect(read_finished.load(.acquire));
    try std.testing.expectEqual(@as(u64, 2), try owner.sessionHead(51));
}

test "host memory remains bounded across cache profiles and Session populations" {
    try host_store.configureProcessHeapLimit(8 * 1024 * 1024);
    defer host_store.disableProcessHeapLimit();
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

test "storage accounting attributes SQLite page work without changing policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var owner = try host_store.StorageOwner.open(
        std.testing.io,
        try pathFor(&tmp, &path_buffer),
        .{},
    );
    defer owner.close();
    const before = try owner.sqlitePagerAccounting(false);
    try create(&owner, 4);
    const after = try owner.sqlitePagerAccounting(false);
    try std.testing.expect(after.cache_pages_written > before.cache_pages_written);
    try std.testing.expect(after.cache_spill_events >= before.cache_spill_events);
    try std.testing.expect(after.page_count >= before.page_count);
    _ = try owner.sqlitePagerAccounting(true);
    const reset = try owner.sqlitePagerAccounting(false);
    try std.testing.expectEqual(@as(u64, 0), reset.cache_pages_written);
    try std.testing.expectEqual(@as(u64, 0), reset.cache_spill_events);
}

test "memory accounting resets only the SQLite high-water boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var owner = try host_store.StorageOwner.open(
        std.testing.io,
        try pathFor(&tmp, &path_buffer),
        .{},
    );
    defer owner.close();
    _ = try owner.memoryAccounting(true);
    try create(&owner, 4);
    const after = try owner.memoryAccounting(false);
    try std.testing.expect(after.heap_highwater_bytes >= after.heap_current_bytes);
    try std.testing.expect(after.page_cache_current_bytes > 0);
}
