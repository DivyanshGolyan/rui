const std = @import("std");
const completion_inbox = @import("completion_inbox.zig");
const host_store = @import("host_store.zig");
const session_transition = @import("session_transition.zig");
const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

test "a fresh Host Store retains an independently sequenced Session Ledger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );

    var owner = try host_store.StorageOwner.open(std.testing.io, path, .{});
    try owner.createSession(.{
        .session_id = 11,
        .agent_id = 12,
        .task_id = 13,
        .branch_id = 14,
    });
    try std.testing.expectEqual(@as(u64, 0), try owner.sessionHead(11));
    owner.close();

    var restored = try host_store.StorageOwner.open(std.testing.io, path, .{});
    defer restored.close();
    try std.testing.expectEqual(@as(u64, 0), try restored.sessionHead(11));
}

test "durable ownership epochs fence stale Session owners" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try host_store.StorageOwner.open(std.testing.io, path, .{});
    defer owner.close();
    try owner.createSession(.{
        .session_id = 15,
        .agent_id = 16,
        .task_id = 17,
        .branch_id = 18,
    });
    try owner.authorizeSession(.{ .session_id = 15, .epoch = 1 });
    try std.testing.expectEqual(@as(u64, 2), try owner.claimSession(15));
    try std.testing.expectError(
        error.StaleOwner,
        owner.authorizeSession(.{ .session_id = 15, .epoch = 1 }),
    );
    try owner.authorizeSession(.{ .session_id = 15, .epoch = 2 });
}

test "the Host Runtime lifetime lock excludes a second Storage Owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );

    var first = try host_store.StorageOwner.open(std.testing.io, path, .{});
    try std.testing.expectError(
        error.HostStoreBusy,
        host_store.StorageOwner.open(std.testing.io, path, .{}),
    );
    first.close();

    var next = try host_store.StorageOwner.open(std.testing.io, path, .{});
    next.close();
}

test "a canonical transition atomically advances one Session head" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try host_store.StorageOwner.open(std.testing.io, path, .{});
    defer owner.close();
    try owner.createSession(.{
        .session_id = 21,
        .agent_id = 22,
        .task_id = 23,
        .branch_id = 24,
    });
    var payload_buffer: [session_transition.max_payload_size]u8 = undefined;
    const payload = try session_transition.encode(&payload_buffer, 1, .{
        .kind = .task_admitted,
        .agent_id = 22,
        .agent_generation = 1,
        .ownership_epoch = 1,
        .subject = 23,
        .reference = 23,
    }, null);
    const digest = try session_transition.digest(payload);
    try std.testing.expectEqual(@as(u64, 1), try owner.appendTransition(.{
        .session_id = 21,
        .expected_sequence = 0,
        .payload_version = 1,
        .kind = .task_admitted,
        .payload = payload,
        .digest = digest,
    }));
    try std.testing.expectEqual(@as(u64, 1), try owner.sessionHead(21));
    try std.testing.expectError(
        error.SessionSequenceConflict,
        owner.appendTransition(.{
            .session_id = 21,
            .expected_sequence = 0,
            .payload_version = 1,
            .kind = .task_admitted,
            .payload = payload,
            .digest = digest,
        }),
    );

    var stored: host_store.StoredTransition = undefined;
    try owner.readTransition(21, 1, &stored);
    try std.testing.expectEqual(host_store.TransitionKind.task_admitted, stored.kind);
    try std.testing.expectEqual(@as(u16, 1), stored.payload_version);
    try std.testing.expectEqualSlices(u8, payload, stored.payloadSlice());
    try std.testing.expectEqualSlices(u8, &digest, &stored.digest);
}

test "a rejected transition batch publishes none of its Session sequence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try host_store.StorageOwner.open(std.testing.io, path, .{});
    defer owner.close();
    try owner.createSession(.{
        .session_id = 31,
        .agent_id = 32,
        .task_id = 33,
        .branch_id = 34,
    });
    var task_buffer: [session_transition.max_payload_size]u8 = undefined;
    const task_payload = try session_transition.encode(&task_buffer, 1, .{
        .kind = .task_admitted,
        .agent_id = 32,
        .agent_generation = 1,
        .ownership_epoch = 1,
        .subject = 33,
        .reference = 33,
    }, null);
    const task_digest = try session_transition.digest(task_payload);
    var entry_buffer: [session_transition.max_payload_size]u8 = undefined;
    const entry_payload = try session_transition.encode(&entry_buffer, 2, .{
        .kind = .conversation_advanced,
        .agent_id = 32,
        .agent_generation = 1,
        .ownership_epoch = 1,
        .subject = 1,
        .reference = 33,
    }, null);
    try std.testing.expectError(
        error.PayloadDigestMismatch,
        owner.appendBatch(.{
            .session_id = 31,
            .expected_sequence = 0,
            .records = &.{
                .{
                    .payload_version = 1,
                    .kind = .task_admitted,
                    .payload = task_payload,
                    .digest = task_digest,
                },
                .{
                    .payload_version = 1,
                    .kind = .conversation_advanced,
                    .payload = entry_payload,
                    .digest = @splat(0),
                },
            },
        }),
    );
    try std.testing.expectEqual(@as(u64, 0), try owner.sessionHead(31));
    try std.testing.expectError(error.TransitionNotFound, owner.readTransition(31, 1, undefined));
}

test "the Storage Owner rejects a non-canonical transition payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try host_store.StorageOwner.open(std.testing.io, path, .{});
    defer owner.close();
    try owner.createSession(.{
        .session_id = 41,
        .agent_id = 42,
        .task_id = 43,
        .branch_id = 44,
    });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("not canonical", &digest, .{});
    try std.testing.expectError(error.InvalidTransitionEnvelope, owner.appendTransition(.{
        .session_id = 41,
        .expected_sequence = 0,
        .payload_version = 1,
        .kind = .task_admitted,
        .payload = "not canonical",
        .digest = digest,
    }));
    try std.testing.expectEqual(@as(u64, 0), try owner.sessionHead(41));
}

test "the relational transition kind cannot contradict the canonical envelope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try host_store.StorageOwner.open(std.testing.io, path, .{});
    defer owner.close();
    try owner.createSession(.{
        .session_id = 45,
        .agent_id = 46,
        .task_id = 47,
        .branch_id = 48,
    });
    var payload_buffer: [session_transition.max_payload_size]u8 = undefined;
    const payload = try session_transition.encode(&payload_buffer, 1, .{
        .kind = .task_admitted,
        .agent_id = 46,
        .agent_generation = 1,
        .ownership_epoch = 1,
        .subject = 47,
        .reference = 47,
    }, null);
    const digest = try session_transition.digest(payload);
    try std.testing.expectError(error.TransitionKindProjectionMismatch, owner.appendTransition(.{
        .session_id = 45,
        .expected_sequence = 0,
        .payload_version = session_transition.payload_version,
        .kind = .outcome,
        .payload = payload,
        .digest = digest,
    }));

    var second_buffer: [session_transition.max_payload_size]u8 = undefined;
    const second_payload = try session_transition.encode(&second_buffer, 2, .{
        .kind = .task_admitted,
        .agent_id = 46,
        .agent_generation = 1,
        .ownership_epoch = 1,
        .subject = 47,
        .reference = 47,
    }, null);
    const second_digest = try session_transition.digest(second_payload);
    try std.testing.expectError(error.TransitionSequenceProjectionMismatch, owner.appendTransition(.{
        .session_id = 45,
        .expected_sequence = 0,
        .payload_version = session_transition.payload_version,
        .kind = .task_admitted,
        .payload = second_payload,
        .digest = second_digest,
    }));
}

test "Completion evidence is durable idempotent and conflicting evidence fails closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try host_store.StorageOwner.open(std.testing.io, path, .{});
    defer owner.close();
    try owner.createSession(.{
        .session_id = 51,
        .agent_id = 52,
        .task_id = 53,
        .branch_id = 54,
    });
    const evidence: completion_inbox.Envelope = .{
        .kind = .model,
        .session_id = 51,
        .ownership_epoch = 1,
        .agent_id = 52,
        .agent_generation = 1,
        .operation_id = 55,
        .operation_generation = 2,
        .attempt_id = 56,
        .result_ref = 57,
        .result_digest = 58,
    };
    var wrong_kind = evidence;
    wrong_kind.kind = .bash;
    try std.testing.expectEqual(@as(u64, 1), try owner.publishCompletion(wrong_kind));

    const terminal: session_transition.Fact = .{
        .kind = .result,
        .evidence_kind = @intFromEnum(completion_inbox.EvidenceKind.model),
        .agent_id = 52,
        .agent_generation = 1,
        .ownership_epoch = 1,
        .operation_id = 55,
        .generation = 2,
        .attempt_id = 56,
        .reference = 57,
        .digest = 58,
        .recovery_class = .model,
        .disposition = .terminal,
    };
    var payload_buffer: [session_transition.max_payload_size]u8 = undefined;
    const payload = try session_transition.encode(&payload_buffer, 1, terminal, null);
    const transition_digest = try session_transition.digest(payload);
    const prepared: host_store.PreparedTransition = .{
        .session_id = 51,
        .expected_sequence = 0,
        .payload_version = session_transition.payload_version,
        .kind = .result,
        .payload = payload,
        .digest = transition_digest,
    };
    try std.testing.expectError(error.CompletionEvidenceMissing, owner.appendTransition(prepared));
    try std.testing.expectEqual(@as(u64, 0), try owner.sessionHead(51));
    const wrong_kind_pending = try owner.readCompletion(51, 1);
    try std.testing.expectEqual(@as(?u64, null), wrong_kind_pending.consumed_by_sequence);

    try std.testing.expectEqual(@as(u64, 2), try owner.publishCompletion(evidence));
    try std.testing.expectEqual(@as(u64, 2), try owner.publishCompletion(evidence));
    _ = try owner.appendTransition(prepared);
    const consumed = try owner.readCompletion(51, 2);
    try std.testing.expectEqual(@as(?u64, 1), consumed.consumed_by_sequence);
    const still_wrong_kind = try owner.readCompletion(51, 1);
    try std.testing.expectEqual(@as(?u64, null), still_wrong_kind.consumed_by_sequence);

    var conflicting = evidence;
    conflicting.result_ref = 59;
    try std.testing.expectError(
        error.ConflictingCompletionEvidence,
        owner.publishCompletion(conflicting),
    );
    try std.testing.expectEqual(@as(u64, 2), try owner.completionHead(51));
}

test "a State Checkpoint cannot lead its Session Ledger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try host_store.StorageOwner.open(std.testing.io, path, .{});
    defer owner.close();
    try owner.createSession(.{
        .session_id = 61,
        .agent_id = 62,
        .task_id = 63,
        .branch_id = 64,
    });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("checkpoint", &digest, .{});
    try std.testing.expectError(error.CheckpointAheadOfLedger, owner.putCheckpoint(.{
        .session_id = 61,
        .sequence = 1,
        .payload_version = 1,
        .payload = "checkpoint",
        .digest = digest,
    }));
    try owner.putCheckpoint(.{
        .session_id = 61,
        .sequence = 0,
        .payload_version = 1,
        .payload = "checkpoint",
        .digest = digest,
    });
    var payload: [32]u8 = undefined;
    const stored = try owner.readCheckpoint(61, &payload);
    try std.testing.expectEqual(@as(u64, 0), stored.sequence);
    try std.testing.expectEqual(@as(u16, 1), stored.payload_version);
    try std.testing.expectEqualSlices(u8, "checkpoint", payload[0..stored.payload_length]);
}

test "SQLite accounting stays inside each supported cache profile allowance" {
    for ([_]u16{ 32, 64, 128 }) |cache_kib| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(
            &path_buffer,
            ".zig-cache/tmp/{s}/host.sqlite3",
            .{tmp.sub_path},
        );
        var owner = try host_store.StorageOwner.open(std.testing.io, path, .{
            .page_cache_kib = cache_kib,
        });
        defer owner.close();
        _ = try owner.memoryAccounting(true);
        for (0..256) |index| {
            const base: u64 = @intCast(index * 4 + 1);
            try owner.createSession(.{
                .session_id = base,
                .agent_id = base + 1,
                .task_id = base + 2,
                .branch_id = base + 3,
            });
        }
        const accounting = try owner.memoryAccounting(false);
        try std.testing.expect(accounting.heap_current_bytes <= accounting.allowance_bytes);
        try std.testing.expect(accounting.heap_highwater_bytes <= accounting.allowance_bytes);
        try std.testing.expect(accounting.page_cache_current_bytes > 0);
        try std.testing.expectEqual(@as(u64, 0), accounting.statements_current_bytes);
    }
}

test "new Session admission preserves the configured database page reserve" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try host_store.StorageOwner.open(std.testing.io, path, .{
        .maximum_page_count = 32,
        .admission_reserve_pages = 16,
    });
    defer owner.close();
    var rejected = false;
    var first_session_id: u64 = 0;
    var first_agent_id: u64 = 0;
    for (0..10_000) |index| {
        const base: u64 = @intCast(index * 4 + 1);
        owner.createSession(.{
            .session_id = base,
            .agent_id = base + 1,
            .task_id = base + 2,
            .branch_id = base + 3,
        }) catch |err| switch (err) {
            error.HostStoreCapacityReserved => {
                rejected = true;
                break;
            },
            else => return err,
        };
        if (first_session_id == 0) {
            first_session_id = base;
            first_agent_id = base + 1;
        }
    }
    try std.testing.expect(rejected);

    var payload_buffer: [session_transition.max_payload_size]u8 = undefined;
    const admission = try session_transition.encode(&payload_buffer, 1, .{
        .kind = .operation_submitted,
        .agent_id = first_agent_id,
        .agent_generation = 1,
        .ownership_epoch = 1,
        .operation_id = 1000,
        .generation = 1,
        .reference = 1001,
        .digest = 1002,
    }, null);
    try std.testing.expectError(error.HostStoreCapacityReserved, owner.appendTransition(.{
        .session_id = first_session_id,
        .expected_sequence = 0,
        .payload_version = session_transition.payload_version,
        .kind = .operation_submitted,
        .payload = admission,
        .digest = try session_transition.digest(admission),
    }));

    const settlement = try session_transition.encode(&payload_buffer, 1, .{
        .kind = .shutdown,
        .agent_id = first_agent_id,
        .agent_generation = 1,
        .ownership_epoch = 1,
    }, null);
    try std.testing.expectEqual(@as(u64, 1), try owner.appendTransition(.{
        .session_id = first_session_id,
        .expected_sequence = 0,
        .payload_version = session_transition.payload_version,
        .kind = .shutdown,
        .payload = settlement,
        .digest = try session_transition.digest(settlement),
    }));
}

test "an unrelated SQLite database is not adopted as a Host Store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/unrelated.sqlite3",
        .{tmp.sub_path},
    );
    try executeTestSql(path, "CREATE TABLE unrelated (value INTEGER)");
    try std.testing.expectError(
        error.InvalidHostStoreIdentity,
        host_store.StorageOwner.open(std.testing.io, path, .{}),
    );
}

test "an unsupported Host Store schema version fails before adoption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try host_store.StorageOwner.open(std.testing.io, path, .{});
    owner.close();
    try executeTestSql(path, "UPDATE host_store_identity SET schema_version = 2");
    try std.testing.expectError(
        error.UnsupportedHostStoreVersion,
        host_store.StorageOwner.open(std.testing.io, path, .{}),
    );
}

test "an existing Host Store missing a required index is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try host_store.StorageOwner.open(std.testing.io, path, .{});
    owner.close();
    try executeTestSql(path, "DROP INDEX completion_inbox_unconsumed");
    try std.testing.expectError(
        error.InvalidHostStoreSchema,
        host_store.StorageOwner.open(std.testing.io, path, .{}),
    );
}

test "Session Ledger and Completion Inbox lifetime bounds fail closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try host_store.StorageOwner.open(std.testing.io, path, .{});
    try owner.createSession(.{
        .session_id = 91,
        .agent_id = 92,
        .task_id = 93,
        .branch_id = 94,
    });
    var payload_buffer: [session_transition.max_payload_size]u8 = undefined;
    const payload = try session_transition.encode(
        &payload_buffer,
        session_transition.max_transitions + 1,
        .{
            .kind = .task_admitted,
            .agent_id = 92,
            .agent_generation = 1,
            .ownership_epoch = 1,
            .subject = 93,
            .reference = 93,
        },
        null,
    );
    const digest = try session_transition.digest(payload);
    try std.testing.expectError(error.SessionSequenceExhausted, owner.appendTransition(.{
        .session_id = 91,
        .expected_sequence = session_transition.max_transitions,
        .payload_version = session_transition.payload_version,
        .kind = .task_admitted,
        .payload = payload,
        .digest = digest,
    }));
    owner.close();

    try executeTestSql(path, "UPDATE session SET inbox_head=4096 WHERE session_id=x'5b00000000000000'");
    owner = try host_store.StorageOwner.open(std.testing.io, path, .{});
    defer owner.close();
    try std.testing.expectError(error.CompletionSequenceExhausted, owner.publishCompletion(.{
        .kind = .model,
        .session_id = 91,
        .ownership_epoch = 1,
        .agent_id = 92,
        .agent_generation = 1,
        .operation_id = 95,
        .operation_generation = 1,
        .attempt_id = 96,
        .result_ref = 97,
        .result_digest = 98,
    }));
}

test "an existing Host Store with a noncanonical page size is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try host_store.StorageOwner.open(std.testing.io, path, .{});
    owner.close();
    try executeTestSql(path, "PRAGMA page_size=8192; VACUUM");
    try std.testing.expectError(
        error.UnsupportedHostStorePageSize,
        host_store.StorageOwner.open(std.testing.io, path, .{}),
    );
}

const InjectCommitFailure = struct {
    boundary: host_store.FaultBoundary,

    fn reached(context: *anyopaque, boundary: host_store.FaultBoundary) anyerror!void {
        const self: *InjectCommitFailure = @ptrCast(@alignCast(context));
        if (boundary == self.boundary) return error.InjectedCommitFailure;
    }
};

test "injected transition and Completion failures roll back every enclosed row" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var injection: InjectCommitFailure = .{ .boundary = .after_transition_insert };
    var owner = try host_store.StorageOwner.open(std.testing.io, path, .{
        .fault = .{ .context = &injection, .reached = InjectCommitFailure.reached },
    });
    defer owner.close();
    try owner.createSession(.{
        .session_id = 71,
        .agent_id = 72,
        .task_id = 73,
        .branch_id = 74,
    });
    var payload_buffer: [session_transition.max_payload_size]u8 = undefined;
    const payload = try session_transition.encode(&payload_buffer, 1, .{
        .kind = .task_admitted,
        .agent_id = 72,
        .agent_generation = 1,
        .ownership_epoch = 1,
        .subject = 73,
        .reference = 73,
    }, null);
    const digest = try session_transition.digest(payload);
    try std.testing.expectError(error.InjectedCommitFailure, owner.appendTransition(.{
        .session_id = 71,
        .expected_sequence = 0,
        .payload_version = session_transition.payload_version,
        .kind = .task_admitted,
        .payload = payload,
        .digest = digest,
    }));
    try std.testing.expectEqual(@as(u64, 0), try owner.sessionHead(71));
    try std.testing.expectError(error.TransitionNotFound, owner.readTransition(71, 1, undefined));

    injection.boundary = .after_completion_head_advance;
    const evidence: completion_inbox.Envelope = .{
        .kind = .model,
        .session_id = 71,
        .ownership_epoch = 1,
        .agent_id = 72,
        .agent_generation = 1,
        .operation_id = 75,
        .operation_generation = 1,
        .attempt_id = 76,
        .result_ref = 77,
        .result_digest = 78,
    };
    try std.testing.expectError(error.InjectedCommitFailure, owner.publishCompletion(evidence));
    try std.testing.expectEqual(@as(u64, 0), try owner.completionHead(71));
    try std.testing.expectError(error.CompletionNotFound, owner.readCompletion(71, 1));
}

test "incremental backup copies a bounded number of pages per Storage Owner turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source_buffer: [256]u8 = undefined;
    const source = try std.fmt.bufPrint(
        &source_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var backup_buffer: [256]u8 = undefined;
    const backup = try std.fmt.bufPrint(
        &backup_buffer,
        ".zig-cache/tmp/{s}/backup.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try host_store.StorageOwner.open(std.testing.io, source, .{});
    try owner.createSession(.{
        .session_id = 81,
        .agent_id = 82,
        .task_id = 83,
        .branch_id = 84,
    });
    try owner.beginBackup(backup);
    var turns: u32 = 0;
    while (true) {
        const progress = try owner.driveBackup(1);
        turns += 1;
        try std.testing.expect(progress.copied_pages <= turns);
        if (progress.complete) break;
    }
    owner.close();

    var restored = try host_store.StorageOwner.open(std.testing.io, backup, .{});
    defer restored.close();
    try std.testing.expectEqual(@as(u64, 0), try restored.sessionHead(81));
}

test "lifecycle point reads and bounded Inbox scans use declared indexes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try host_store.StorageOwner.open(std.testing.io, path, .{});
    owner.close();
    try expectIndexedTestPlan(
        path,
        "EXPLAIN QUERY PLAN SELECT payload_version, kind, payload, digest FROM session_transition WHERE session_id=x'0100000000000000' AND sequence=1",
    );
    try expectIndexedTestPlan(
        path,
        "EXPLAIN QUERY PLAN SELECT inbox_sequence FROM completion_inbox WHERE session_id=x'0100000000000000' AND consumed_by_sequence IS NULL ORDER BY inbox_sequence LIMIT 8",
    );
}

fn executeTestSql(path: []const u8, sql: [:0]const u8) !void {
    var terminated_path: [257:0]u8 = undefined;
    if (path.len > 256) return error.TestPathTooLong;
    @memcpy(terminated_path[0..path.len], path);
    terminated_path[path.len] = 0;
    var database: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open_v2(
        &terminated_path,
        &database,
        sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE,
        null,
    ) != sqlite.SQLITE_OK) return error.TestDatabaseOpenFailed;
    defer _ = sqlite.sqlite3_close_v2(database);
    if (sqlite.sqlite3_exec(database, sql.ptr, null, null, null) != sqlite.SQLITE_OK) {
        return error.TestSqlFailed;
    }
}

fn expectIndexedTestPlan(path: []const u8, sql: [:0]const u8) !void {
    var terminated_path: [257:0]u8 = undefined;
    if (path.len > 256) return error.TestPathTooLong;
    @memcpy(terminated_path[0..path.len], path);
    terminated_path[path.len] = 0;
    var database: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open_v2(&terminated_path, &database, sqlite.SQLITE_OPEN_READONLY, null) !=
        sqlite.SQLITE_OK) return error.TestDatabaseOpenFailed;
    defer _ = sqlite.sqlite3_close_v2(database);
    var statement: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(database, sql.ptr, -1, &statement, null) != sqlite.SQLITE_OK) {
        return error.TestSqlFailed;
    }
    defer _ = sqlite.sqlite3_finalize(statement);
    var found_search = false;
    while (true) {
        const result = sqlite.sqlite3_step(statement);
        if (result == sqlite.SQLITE_DONE) break;
        if (result != sqlite.SQLITE_ROW) return error.TestSqlFailed;
        const detail = sqlite.sqlite3_column_text(statement, 3) orelse return error.TestSqlFailed;
        const length = sqlite.sqlite3_column_bytes(statement, 3);
        if (length <= 0) return error.TestSqlFailed;
        if (std.mem.indexOf(u8, detail[0..@intCast(length)], "SEARCH") != null) {
            found_search = true;
        }
    }
    try std.testing.expect(found_search);
}
