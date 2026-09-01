const std = @import("std");
const bash_tool = @import("bash_tool.zig");
const conversation = @import("conversation.zig");
const deterministic_provider = @import("deterministic_provider.zig");
const execution_cells = @import("execution_cells.zig");
const model_contract = @import("model_contract.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");
const model_request = @import("relational_model_request.zig");
const patch_tool = @import("patch_tool.zig");
const store = @import("host_store.zig");
const coordinator = @import("turn_coordinator.zig");
const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

test "Session and first Turn admission is atomic and enforces one active Turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/authority.sqlite", .{tmp.sub_path});
    var database = try store.Store.open(path);
    defer database.close();

    const scope = [_]u8{0x11} ** 32;
    const admission = store.semanticDigest(.turn, "Turn one");
    const first: store.AdmitTurn = .{
        .session_id = 10,
        .turn_id = 20,
        .turn_ordinal = 1,
        .entry_id = 30,
        .content_id = 40,
        .expected_conversation_revision = 0,
        .workspace_path = "/workspace",
        .access_scope_digest = scope,
        .admission_digest = admission,
        .user_text = "Turn one",
    };
    try std.testing.expectEqual(store.AdmissionResult.admitted, try database.admitTurn(first));
    try std.testing.expectEqual(store.AdmissionResult.replay, try database.admitTurn(first));
    var conflicting = first;
    conflicting.entry_id = 32;
    try std.testing.expectError(error.TurnConflict, database.admitTurn(conflicting));

    var second = first;
    second.turn_id = 21;
    second.turn_ordinal = 2;
    second.entry_id = 31;
    second.content_id = 41;
    second.expected_conversation_revision = 1;
    second.admission_digest = store.semanticDigest(.turn, "Turn two");
    second.user_text = "Turn two";
    try std.testing.expectError(error.SessionBusy, database.admitTurn(second));

    const snapshot = try database.loadDecisionSnapshot(first.turn_id);
    try std.testing.expectEqual(store.TurnCondition.runnable, store.classify(snapshot));
    try std.testing.expectEqual(@as(u64, 1), snapshot.conversation_revision);
    var entries: [4]store.ConversationEntry = undefined;
    const count = try database.readConversation(first.session_id, 0, &entries);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(store.ConversationKind.user_text, entries[0].kind);
    try std.testing.expectEqual(first.turn_id, entries[0].turn_id);
}

test "one Host owns the Store lifetime lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/locked.sqlite3", .{tmp.sub_path});
    var first = try store.Store.open(path);
    try std.testing.expectError(error.HostStoreBusy, store.Store.open(path));
    first.close();
    var second = try store.Store.open(path);
    second.close();
}

test "relational core permits correlated User input in the active Turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/correlated-input.sqlite", .{tmp.sub_path});
    var database = try store.Store.open(path);
    defer database.close();
    _ = try database.admitTurn(.{
        .session_id = 11,
        .turn_id = 21,
        .turn_ordinal = 1,
        .entry_id = 31,
        .content_id = 41,
        .expected_conversation_revision = 0,
        .workspace_path = "/workspace",
        .access_scope_digest = store.semanticDigest(.access_scope, "/workspace"),
        .admission_digest = store.semanticDigest(.turn, "initial"),
        .user_text = "initial",
    });
    // Issue #38 owns the validating admission command and request identity.
    // This schema-level proof ensures that command can append correlated User
    // input to the same nonterminal Turn without creating another Turn.
    const sql =
        "BEGIN IMMEDIATE;" ++
        "INSERT INTO content(content_id,byte_length,digest,payload) VALUES(42,10,X'BCE650CA81EBE50AF4EB7B13B6E496E23D1052041F2BFFCBFBDF8BB02CE9EA32',X'636F7272656C61746564');" ++
        "INSERT INTO conversation_entry(session_id,revision,entry_id,turn_id,kind,content_id) VALUES(11,2,32,21,1,42);" ++
        "COMMIT;";
    try std.testing.expectEqual(
        sqlite.SQLITE_OK,
        sqlite.sqlite3_exec(@ptrCast(database.database), sql, null, null, null),
    );
    var entries: [4]store.ConversationEntry = undefined;
    try std.testing.expectEqual(@as(usize, 2), try database.readConversation(11, 0, &entries));
    try std.testing.expectEqual(@as(u64, 21), entries[1].turn_id);
    try std.testing.expectEqual(store.ConversationKind.user_text, entries[1].kind);
    try std.testing.expectEqual(@as(?u64, 21), (try database.readSession(11)).active_turn_id);
}

test "crash hooks prove Turn admission rollback and acknowledgement loss" {
    const Fault = struct {
        target: store.CrashPoint,

        fn hook(self: *@This()) store.FaultHook {
            return .{ .context = self, .reach_fn = reach };
        }

        fn reach(context: *anyopaque, point: store.CrashPoint) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (point == self.target) return error.InjectedCrash;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/crash.sqlite", .{tmp.sub_path});
    var database = try store.Store.open(path);
    defer database.close();
    const command: store.AdmitTurn = .{
        .session_id = 15,
        .turn_id = 25,
        .turn_ordinal = 1,
        .entry_id = 35,
        .content_id = 45,
        .expected_conversation_revision = 0,
        .workspace_path = "/workspace",
        .access_scope_digest = store.semanticDigest(.access_scope, "/workspace"),
        .admission_digest = store.semanticDigest(.turn, "crash"),
        .user_text = "crash",
    };

    var before_commit: Fault = .{ .target = .after_turn_row };
    database.setFaultHook(before_commit.hook());
    try std.testing.expectError(error.InjectedCrash, database.admitTurn(command));
    database.setFaultHook(null);
    try std.testing.expectError(error.SessionNotFound, database.readSession(command.session_id));

    var after_commit: Fault = .{ .target = .after_turn_commit };
    database.setFaultHook(after_commit.hook());
    try std.testing.expectError(error.InjectedCrash, database.admitTurn(command));
    database.setFaultHook(null);
    const restored = try database.readSession(command.session_id);
    try std.testing.expectEqual(@as(?u64, command.turn_id), restored.active_turn_id);
    try std.testing.expectEqual(store.AdmissionResult.replay, try database.admitTurn(command));
}

test "relational facts reconstruct a multi-Tool-Call Turn and permit Session reuse" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/vertical.sqlite", .{tmp.sub_path});
    const scope = [_]u8{0x31} ** 32;
    var database = try store.Store.open(path);

    _ = try database.admitTurn(.{
        .session_id = 100,
        .turn_id = 200,
        .turn_ordinal = 1,
        .entry_id = 300,
        .content_id = 400,
        .expected_conversation_revision = 0,
        .workspace_path = "/workspace",
        .access_scope_digest = scope,
        .admission_digest = store.semanticDigest(.turn, "turn-one"),
        .user_text = "Use two tools",
    });
    _ = try database.admitOperation(.{
        .turn_id = 200,
        .operation_id = 500,
        .operation_ordinal = 1,
        .kind = .model,
        .descriptor_content_id = 401,
        .descriptor = "model request one",
        .descriptor_digest = store.semanticDigest(.operation, "model request one"),
    });
    const model_attempt = try database.admitAttempt(.{
        .operation_id = 500,
        .attempt_id = 600,
        .attempt_ordinal = 1,
        .dispatch_content_id = 401,
        .dispatch_request = "model request one",
        .dispatch_digest = store.semanticDigest(.dispatch, "model request one"),
        .parameters_content_id = 403,
        .parameters = "provider=fixture;model=test",
        .context_cutoff_revision = 1,
        .workspace_digest = store.semanticDigest(.workspace, "/workspace"),
        .external_idempotency_key = "model-600",
    });
    try std.testing.expectEqual(store.AdmissionResult.admitted, model_attempt);

    const bash_arguments = "{\"command\":\"pwd\",\"timeout_ms\":1000}";
    const second_bash_arguments = "{\"command\":\"echo hi\",\"timeout_ms\":1000}";
    var bash_call_buffer: [256]u8 = undefined;
    const bash_call = try conversation.encodeToolCall(&bash_call_buffer, .{
        .key = model_contract.bash_key,
        .arguments = .{
            .value = bash_arguments,
            .proof = model_contract.strictToolJsonDigest(bash_arguments),
        },
    });
    var second_bash_call_buffer: [256]u8 = undefined;
    const second_bash_call = try conversation.encodeToolCall(&second_bash_call_buffer, .{
        .key = model_contract.bash_key,
        .arguments = .{
            .value = second_bash_arguments,
            .proof = model_contract.strictToolJsonDigest(second_bash_arguments),
        },
    });
    var first_descriptor_buffer: [bash_tool.max_descriptor_size]u8 = undefined;
    const first_descriptor = try bash_tool.encodeDescriptor(&first_descriptor_buffer, .{
        .workspace_path = "/workspace",
        .working_directory = "/workspace",
        .call = .{ .command = "pwd", .timeout_ms = 1000 },
    });
    var second_descriptor_buffer: [bash_tool.max_descriptor_size]u8 = undefined;
    const second_descriptor = try bash_tool.encodeDescriptor(&second_descriptor_buffer, .{
        .workspace_path = "/workspace",
        .working_directory = "/workspace",
        .call = .{ .command = "echo hi", .timeout_ms = 1000 },
    });
    const calls = [_]store.ToolCallCandidate{
        .{
            .entry_id = 301,
            .content_id = 404,
            .content = bash_call,
            .action_operation_id = 501,
            .action_operation_ordinal = 2,
            .action_kind = .bash,
            .descriptor_content_id = 405,
            .descriptor = first_descriptor,
            .descriptor_digest = store.semanticDigest(.operation, first_descriptor),
        },
        .{
            .entry_id = 302,
            .content_id = 406,
            .content = second_bash_call,
            .action_operation_id = 502,
            .action_operation_ordinal = 3,
            .action_kind = .bash,
            .descriptor_content_id = 407,
            .descriptor = second_descriptor,
            .descriptor_digest = store.semanticDigest(.operation, second_descriptor),
        },
    };
    var captured_batch_buffer: [1024]u8 = undefined;
    const captured_batch = try model_protocol.encodeToolCalls(&captured_batch_buffer, &.{
        .{ .key = model_contract.bash_key, .arguments = bash_arguments },
        .{ .key = model_contract.bash_key, .arguments = second_bash_arguments },
    });
    try std.testing.expectEqual(store.AdmissionResult.admitted, try database.admitModelToolCalls(.{
        .turn_id = 200,
        .model_operation_id = 500,
        .attempt_id = 600,
        .completion_id = 700,
        .completion_content_id = 408,
        .captured_output = captured_batch,
        .completion_digest = store.semanticDigest(.completion, captured_batch),
        .expected_conversation_revision = 1,
        .calls = &calls,
    }));

    var action_ids: coordinator.IdentitySource = .{ .next_value = 800 };
    var visible_result: [256]u8 = undefined;
    try coordinator.denyAction(&database, &action_ids, .{
        .turn_id = 200,
        .parent_model_operation_id = 500,
        .operation_id = 501,
        .call_entry_id = 301,
        .kind = .bash,
    }, &visible_result);
    // The first child Resolution cannot publish a partial Tool Result wave.
    try std.testing.expectEqual(@as(u64, 3), try database.sessionConversationRevision(100));
    database.close();
    database = try store.Store.open(path);
    try coordinator.denyAction(&database, &action_ids, .{
        .turn_id = 200,
        .parent_model_operation_id = 500,
        .operation_id = 502,
        .call_entry_id = 302,
        .kind = .bash,
    }, &visible_result);
    try std.testing.expect(!(try coordinator.publishPendingToolResults(&database, &action_ids, 200)));
    var frontier: [8]store.OperationView = undefined;
    try std.testing.expectEqual(@as(usize, 0), try database.readUnresolvedOperations(200, &frontier));
    var entries: [8]store.ConversationEntry = undefined;
    try std.testing.expectEqual(@as(usize, 5), try database.readConversation(100, 0, &entries));
    try std.testing.expectEqual(store.ConversationKind.tool_call, entries[1].kind);
    try std.testing.expectEqual(store.ConversationKind.tool_call, entries[2].kind);
    try std.testing.expectEqual(@as(?u16, 0), entries[3].call_ordinal);
    try std.testing.expectEqual(@as(?u16, 1), entries[4].call_ordinal);

    _ = try database.admitOperation(.{
        .turn_id = 200,
        .operation_id = 503,
        .operation_ordinal = 4,
        .kind = .model,
        .descriptor_content_id = 440,
        .descriptor = "model request two",
        .descriptor_digest = store.semanticDigest(.operation, "model request two"),
    });
    _ = try database.admitAttempt(.{
        .operation_id = 503,
        .attempt_id = 612,
        .attempt_ordinal = 1,
        .dispatch_content_id = 440,
        .dispatch_request = "model request two",
        .dispatch_digest = store.semanticDigest(.dispatch, "model request two"),
        .parameters_content_id = 442,
        .parameters = "provider=fixture;model=test",
        .context_cutoff_revision = 5,
        .workspace_digest = store.semanticDigest(.workspace, "/workspace"),
        .external_idempotency_key = "model-612",
    });
    try std.testing.expectEqual(store.AdmissionResult.admitted, try database.completeTurn(.{
        .turn_id = 200,
        .model_operation_id = 503,
        .attempt_id = 612,
        .completion_id = 712,
        .completion_content_id = 443,
        .final_entry_id = 305,
        .final_content_id = 444,
        .captured_output = "done",
        .final_answer = "done",
        .completion_digest = store.semanticDigest(.completion, "done"),
        .expected_conversation_revision = 5,
    }));
    try std.testing.expectEqual(store.TurnCondition.completed, store.classify(try database.loadDecisionSnapshot(200)));

    try std.testing.expectEqual(store.AdmissionResult.admitted, try database.admitTurn(.{
        .session_id = 100,
        .turn_id = 201,
        .turn_ordinal = 2,
        .entry_id = 306,
        .content_id = 445,
        .expected_conversation_revision = 6,
        .workspace_path = "/workspace",
        .access_scope_digest = scope,
        .admission_digest = store.semanticDigest(.turn, "turn-two"),
        .user_text = "Continue",
    }));
    try std.testing.expectEqual(store.TurnCondition.runnable, store.classify(try database.loadDecisionSnapshot(201)));
    try std.testing.expectEqual(store.TurnCondition.completed, store.classify(try database.loadDecisionSnapshot(200)));
}

test "late evidence, cancellation, and conflicting replay stay relational" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/recovery.sqlite", .{tmp.sub_path});
    var database = try store.Store.open(path);
    const scope = [_]u8{0x51} ** 32;
    _ = try database.admitTurn(.{
        .session_id = 110,
        .turn_id = 210,
        .turn_ordinal = 1,
        .entry_id = 310,
        .content_id = 410,
        .expected_conversation_revision = 0,
        .workspace_path = "/workspace",
        .access_scope_digest = scope,
        .admission_digest = store.semanticDigest(.turn, "recover"),
        .user_text = "Recover evidence",
    });
    _ = try database.admitOperation(.{
        .turn_id = 210,
        .operation_id = 510,
        .operation_ordinal = 1,
        .kind = .model,
        .descriptor_content_id = 411,
        .descriptor = "echo once",
        .descriptor_digest = store.semanticDigest(.operation, "echo once"),
    });
    _ = try database.admitAttempt(.{
        .operation_id = 510,
        .attempt_id = 610,
        .attempt_ordinal = 1,
        .dispatch_content_id = 411,
        .dispatch_request = "echo once",
        .dispatch_digest = store.semanticDigest(.dispatch, "echo once"),
        .parameters_content_id = 413,
        .parameters = "local bash",
        .context_cutoff_revision = 1,
        .workspace_digest = store.semanticDigest(.workspace, "/workspace"),
        .external_idempotency_key = null,
    });
    try std.testing.expectEqual(store.AdmissionResult.admitted, try database.completeAndResolve(.{
        .operation_id = 510,
        .attempt_id = 610,
        .completion_id = 710,
        .completion_ordinal = 1,
        .evidence_kind = .success,
        .completion_content_id = 414,
        .completion_content = "observed once",
        .completion_digest = store.semanticDigest(.completion, "observed once"),
        .resolution_kind = .success,
        .result_content_id = 415,
        .result_content = "observed once",
        .resolution_digest = store.semanticDigest(.resolution, "observed once"),
    }));
    database.close();

    database = try store.Store.open(path);
    var frontier: [2]store.OperationView = undefined;
    try std.testing.expectEqual(@as(usize, 0), try database.readUnresolvedOperations(210, &frontier));
    try std.testing.expectEqual(store.AdmissionResult.admitted, try database.recordCompletion(.{
        .operation_id = 510,
        .attempt_id = 610,
        .completion_id = 711,
        .completion_ordinal = 2,
        .evidence_kind = .uncertain,
        .content_id = 416,
        .content = "late contradictory evidence",
        .completion_digest = store.semanticDigest(.completion, "late contradictory evidence"),
    }));
    try std.testing.expectError(error.ResolutionConflict, database.completeAndResolve(.{
        .operation_id = 510,
        .attempt_id = 610,
        .completion_id = 711,
        .completion_ordinal = 2,
        .evidence_kind = .uncertain,
        .completion_content_id = 416,
        .completion_content = "late contradictory evidence",
        .completion_digest = store.semanticDigest(.completion, "late contradictory evidence"),
        .resolution_kind = .indeterminate,
        .result_content_id = 417,
        .result_content = "late contradictory evidence",
        .resolution_digest = store.semanticDigest(.resolution, "late contradictory evidence"),
    }));
    try std.testing.expectEqual(store.AdmissionResult.admitted, try database.settleTurn(.{
        .turn_id = 210,
        .outcome = .cancelled,
    }));
    try std.testing.expectEqual(store.TurnCondition.cancelled, store.classify(try database.loadDecisionSnapshot(210)));
    try std.testing.expectEqual(store.AdmissionResult.admitted, try database.admitTurn(.{
        .session_id = 110,
        .turn_id = 211,
        .turn_ordinal = 2,
        .entry_id = 311,
        .content_id = 418,
        .expected_conversation_revision = 1,
        .workspace_path = "/workspace",
        .access_scope_digest = scope,
        .admission_digest = store.semanticDigest(.turn, "after-cancel"),
        .user_text = "Continue after cancellation",
    }));
}

test "lost model custody resolves indeterminate and fails the Turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/lost-model.sqlite", .{tmp.sub_path});
    var database = try store.Store.open(path);
    defer database.close();
    _ = try database.admitTurn(.{
        .session_id = 120,
        .turn_id = 220,
        .turn_ordinal = 1,
        .entry_id = 320,
        .content_id = 420,
        .expected_conversation_revision = 0,
        .workspace_path = "/workspace",
        .access_scope_digest = store.semanticDigest(.access_scope, "/workspace"),
        .admission_digest = store.semanticDigest(.turn, "lost model"),
        .user_text = "Lose model custody",
    });
    _ = try database.admitOperation(.{
        .turn_id = 220,
        .operation_id = 520,
        .operation_ordinal = 1,
        .kind = .model,
        .descriptor_content_id = 421,
        .descriptor = "model request",
        .descriptor_digest = store.semanticDigest(.operation, "model request"),
    });
    _ = try database.admitAttempt(.{
        .operation_id = 520,
        .attempt_id = 620,
        .attempt_ordinal = 1,
        .dispatch_content_id = 421,
        .dispatch_request = "model request",
        .dispatch_digest = store.semanticDigest(.dispatch, "model request"),
        .parameters_content_id = 423,
        .parameters = "fixture:test",
        .context_cutoff_revision = 1,
        .workspace_digest = store.semanticDigest(.workspace, "/workspace"),
        .external_idempotency_key = null,
    });
    var ids: coordinator.IdentitySource = .{ .next_value = 700 };
    const Fault = struct {
        fn reach(_: *anyopaque, point: store.CrashPoint) anyerror!void {
            if (point == .after_failure_resolution) return error.InjectedCrash;
        }
    };
    var context: u8 = 0;
    database.setFaultHook(.{ .context = &context, .reach_fn = Fault.reach });
    try std.testing.expectError(
        error.InjectedCrash,
        coordinator.failLostModel(&database, &ids, 220, 520),
    );
    database.setFaultHook(null);
    try std.testing.expectEqual(
        store.TurnCondition.in_flight,
        store.classify(try database.loadDecisionSnapshot(220)),
    );
    try coordinator.failLostModel(&database, &ids, 220, 520);
    try std.testing.expectEqual(
        store.TurnCondition.failed,
        store.classify(try database.loadDecisionSnapshot(220)),
    );
}

test "model Operation without an Attempt resumes from its immutable request" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/operation-recovery.sqlite", .{tmp.sub_path});
    var database = try store.Store.open(path);
    defer database.close();
    _ = try database.admitTurn(.{
        .session_id = 125,
        .turn_id = 225,
        .turn_ordinal = 1,
        .entry_id = 325,
        .content_id = 425,
        .expected_conversation_revision = 0,
        .workspace_path = "/workspace",
        .access_scope_digest = store.semanticDigest(.access_scope, "/workspace"),
        .admission_digest = store.semanticDigest(.turn, "resume operation"),
        .user_text = "Resume operation",
    });
    var request_buffer: [64 * 1024]u8 = undefined;
    const encoded = try model_request.encode(&database, 125, "fixture:test", &request_buffer);
    _ = try database.admitOperation(.{
        .turn_id = 225,
        .operation_id = 525,
        .operation_ordinal = 1,
        .kind = .model,
        .descriptor_content_id = 426,
        .descriptor = encoded.bytes,
        .descriptor_digest = store.semanticDigest(.operation, encoded.bytes),
    });
    var fixture: deterministic_provider.Fixture = .{
        .expected_task = "Resume operation",
        .final_answer = "resumed",
    };
    var ids: coordinator.IdentitySource = .{ .next_value = 700 };
    var candidate: [model_protocol.max_response_size]u8 = undefined;
    var tool_call: [model_contract.max_tool_arguments_envelope_size + 128]u8 = undefined;
    var descriptor: [coordinator.max_patch_descriptor_size]u8 = undefined;
    var cell_pool = try execution_cells.Pool.init(std.testing.allocator, 1);
    defer cell_pool.deinit();
    const cell = try cell_pool.reserve();
    defer cell.release();
    const result = try coordinator.advanceModel(
        &database,
        &ids,
        225,
        "fixture:test",
        "/workspace",
        std.testing.io,
        fixture.provider(),
        cell,
        .{
            .request = &request_buffer,
            .candidate = &candidate,
            .tool_call = &tool_call,
            .descriptor = &descriptor,
        },
    );
    try std.testing.expect(result == .completed);
}

test "relational Conversation drives the production Provider seam" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/provider.sqlite", .{tmp.sub_path});
    var database = try store.Store.open(path);
    defer database.close();
    _ = try database.admitTurn(.{
        .session_id = 120,
        .turn_id = 220,
        .turn_ordinal = 1,
        .entry_id = 320,
        .content_id = 420,
        .expected_conversation_revision = 0,
        .workspace_path = "/workspace",
        .access_scope_digest = [_]u8{0x61} ** 32,
        .admission_digest = store.semanticDigest(.turn, "provider"),
        .user_text = "Answer this",
    });
    var request_bytes: [64 * 1024]u8 = undefined;
    const encoded = try model_request.encode(&database, 120, "fixture:test", &request_bytes);
    var request: model_operation.BufferedRequest = .{ .bytes = encoded.bytes };
    var candidate_bytes: [model_protocol.max_response_size]u8 = undefined;
    var candidate: model_operation.BufferedCandidate = .{ .bytes = &candidate_bytes };
    var fixture: deterministic_provider.Fixture = .{
        .expected_task = "Answer this",
        .final_answer = "done",
    };
    const provider = fixture.provider();
    const outcome = try provider.dispatch(provider.context, try request.cursor(), candidate.writer());
    try std.testing.expect(outcome == .candidate);
    var scratch: model_protocol.ValidationScratch = .{};
    const parsed = try model_protocol.decode(&scratch, candidate.slice());
    try std.testing.expectEqual(model_protocol.Disposition.final_answer, parsed.disposition);
    try std.testing.expectEqualStrings("done", candidate.slice()[parsed.text_offset..][0..parsed.text_length]);
}

test "production coordinator admits and replays one ordered multi-Tool-Call wave" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/batch.sqlite3", .{tmp.sub_path});
    var database = try store.Store.open(path);
    defer database.close();
    _ = try database.admitTurn(.{
        .session_id = 135,
        .turn_id = 235,
        .turn_ordinal = 1,
        .entry_id = 335,
        .content_id = 435,
        .expected_conversation_revision = 0,
        .workspace_path = "/workspace",
        .access_scope_digest = store.semanticDigest(.access_scope, "/workspace"),
        .admission_digest = store.semanticDigest(.turn, "batch"),
        .user_text = "Use both tools",
    });
    const calls = [_]model_protocol.ToolCall{
        .{ .key = model_contract.bash_key, .arguments = "{\"command\":\"pwd\",\"timeout_ms\":1000}" },
        .{ .key = model_contract.bash_key, .arguments = "{\"command\":\"echo hi\",\"timeout_ms\":1000}" },
    };
    var fixture: deterministic_provider.BatchToolFixture = .{
        .expected_task = "Use both tools",
        .calls = &calls,
    };
    var ids: coordinator.IdentitySource = .{ .next_value = 3000 };
    var request: [256 * 1024]u8 = undefined;
    var candidate: [model_protocol.max_response_size]u8 = undefined;
    const call_stride = conversation.call_header_size + model_contract.max_tool_key_size +
        model_contract.max_tool_arguments_envelope_size;
    var tool_calls: [2 * call_stride]u8 = undefined;
    var descriptors: [2 * coordinator.max_patch_descriptor_size]u8 = undefined;
    var pool = try execution_cells.Pool.init(std.testing.allocator, 1);
    defer pool.deinit();
    const lease = try pool.reserve();
    const CompletionCrash = struct {
        fn reach(_: *anyopaque, point: store.CrashPoint) anyerror!void {
            if (point == .after_completion_commit) return error.InjectedCompletionCrash;
        }
    };
    var crash_context: u8 = 0;
    database.setFaultHook(.{ .context = &crash_context, .reach_fn = CompletionCrash.reach });
    try std.testing.expectError(error.InjectedCompletionCrash, coordinator.advanceModel(
        &database,
        &ids,
        235,
        "fixture:batch",
        "/workspace",
        std.testing.io,
        fixture.provider(),
        lease,
        .{
            .request = &request,
            .candidate = &candidate,
            .tool_call = &tool_calls,
            .descriptor = &descriptors,
        },
    ));
    lease.release();
    try std.testing.expectEqual(@as(u8, 1), fixture.dispatch_count);
    database.setFaultHook(null);
    database.close();
    database = try store.Store.open(path);
    const recovery_lease = try pool.reserve();
    const advanced = try coordinator.advanceModel(
        &database,
        &ids,
        235,
        "fixture:batch",
        "/workspace",
        std.testing.io,
        fixture.provider(),
        recovery_lease,
        .{
            .request = &request,
            .candidate = &candidate,
            .tool_call = &tool_calls,
            .descriptor = &descriptors,
        },
    );
    recovery_lease.release();
    try std.testing.expectEqual(@as(u8, 1), fixture.dispatch_count);
    try std.testing.expect(advanced == .action);
    var frontier: [8]store.OperationView = undefined;
    const frontier_count = try database.readUnresolvedOperations(235, &frontier);
    try std.testing.expectEqual(@as(usize, 2), frontier_count);
    var visible: [256]u8 = undefined;
    for (frontier[0..frontier_count]) |item| {
        const operation = try database.readOperation(item.operation_id);
        try coordinator.denyAction(&database, &ids, .{
            .turn_id = 235,
            .parent_model_operation_id = operation.caused_by_operation_id.?,
            .operation_id = operation.operation_id,
            .call_entry_id = operation.caused_by_entry_id.?,
            .kind = operation.kind,
        }, &visible);
    }
    var entries: [8]store.ConversationEntry = undefined;
    const count = try database.readConversation(135, 0, &entries);
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqual(store.ConversationKind.tool_call, entries[1].kind);
    try std.testing.expectEqual(store.ConversationKind.tool_call, entries[2].kind);
    try std.testing.expectEqual(store.ConversationKind.tool_result, entries[3].kind);
    try std.testing.expectEqual(store.ConversationKind.tool_result, entries[4].kind);

    const encoded = try model_request.encode(&database, 135, "fixture:batch", &request);
    var owner: model_operation.BufferedRequest = .{ .bytes = encoded.bytes };
    var cursor = try owner.cursor();
    _ = (try cursor.next()).?;
    const call0 = (try cursor.next()).?.tool_call;
    const call1 = (try cursor.next()).?.tool_call;
    const result0 = (try cursor.next()).?.tool_result;
    const result1 = (try cursor.next()).?.tool_result;
    try std.testing.expectEqual(call0.entry_id, result0.call_entry_id);
    try std.testing.expectEqual(call1.entry_id, result1.call_entry_id);
    try std.testing.expect((try cursor.next()) == null);
}

test "Turn coordinator dispatches Bash only after Attempt commit and preserves ordered Conversation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var relative_buffer: [256]u8 = undefined;
    const relative = try std.fmt.bufPrint(&relative_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var workspace_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const workspace_length = try std.Io.Dir.cwd().realPathFile(std.testing.io, relative, &workspace_buffer);
    const workspace = workspace_buffer[0..workspace_length];
    var database_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const database_path = try std.fmt.bufPrint(&database_path_buffer, "{s}/coordinator.sqlite", .{workspace});
    var database = try store.Store.open(database_path);
    defer database.close();
    _ = try database.admitTurn(.{
        .session_id = 130,
        .turn_id = 230,
        .turn_ordinal = 1,
        .entry_id = 330,
        .content_id = 430,
        .expected_conversation_revision = 0,
        .workspace_path = workspace,
        .access_scope_digest = [_]u8{0x71} ** 32,
        .admission_digest = store.semanticDigest(.turn, "bash"),
        .user_text = "Inspect",
    });
    var call_buffer: [bash_tool.call_header_size + 32]u8 = undefined;
    const call = try bash_tool.encodeCall(&call_buffer, .{ .command = "pwd", .timeout_ms = 1000 });
    var fixture: deterministic_provider.ToolFixture = .{
        .expected_task = "Inspect",
        .tool_arguments = call,
        .final_answer = "finished",
    };
    var ids: coordinator.IdentitySource = .{ .next_value = 1000 };
    var request: [256 * 1024]u8 = undefined;
    var candidate: [model_protocol.max_response_size]u8 = undefined;
    var tool_call: [model_contract.max_tool_arguments_envelope_size + 128]u8 = undefined;
    var descriptor: [bash_tool.max_descriptor_size]u8 = undefined;
    var model_pool = try execution_cells.Pool.init(std.testing.allocator, 1);
    defer model_pool.deinit();
    const model_cell = try model_pool.reserve();
    defer model_cell.release();
    const first = try coordinator.advanceModel(
        &database,
        &ids,
        230,
        "fixture:test",
        workspace,
        std.testing.io,
        fixture.provider(),
        model_cell,
        .{
            .request = &request,
            .candidate = &candidate,
            .tool_call = &tool_call,
            .descriptor = &descriptor,
        },
    );
    const action = switch (first) {
        .action => |value| value,
        else => return error.ExpectedAction,
    };
    var action_descriptor: [bash_tool.max_descriptor_size]u8 = undefined;
    var completion: [bash_tool.result_header_size + bash_tool.max_output_size]u8 = undefined;
    var visible: [@import("conversation.zig").result_header_size + 2 * bash_tool.max_output_size + 256]u8 = undefined;
    var action_pool = try execution_cells.Pool.init(std.testing.allocator, 1);
    defer action_pool.deinit();
    const action_cell = try action_pool.reserve();
    defer action_cell.release();
    try coordinator.executeBashAction(
        &database,
        &ids,
        std.testing.io,
        std.testing.allocator,
        action,
        action_cell,
        .{
            .descriptor = &action_descriptor,
            .completion = &completion,
            .visible_result = &visible,
        },
    );
    var final_pool = try execution_cells.Pool.init(std.testing.allocator, 1);
    defer final_pool.deinit();
    const final_cell = try final_pool.reserve();
    defer final_cell.release();
    const second = try coordinator.advanceModel(
        &database,
        &ids,
        230,
        "fixture:test",
        workspace,
        std.testing.io,
        fixture.provider(),
        final_cell,
        .{
            .request = &request,
            .candidate = &candidate,
            .tool_call = &tool_call,
            .descriptor = &descriptor,
        },
    );
    try std.testing.expect(second == .completed);
    try std.testing.expectEqual(store.TurnCondition.completed, store.classify(try database.loadDecisionSnapshot(230)));
    var entries: [8]store.ConversationEntry = undefined;
    try std.testing.expectEqual(@as(usize, 4), try database.readConversation(130, 0, &entries));
    try std.testing.expectEqual(store.ConversationKind.tool_call, entries[1].kind);
    try std.testing.expectEqual(store.ConversationKind.tool_result, entries[2].kind);
    try std.testing.expectEqual(store.ConversationKind.assistant_text, entries[3].kind);
}

test "Turn coordinator prepares and reconciles one immutable Patch Intent" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "note.txt", "old\n");
    var relative_buffer: [256]u8 = undefined;
    const relative = try std.fmt.bufPrint(&relative_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var workspace_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const workspace_length = try std.Io.Dir.cwd().realPathFile(io, relative, &workspace_buffer);
    const workspace = workspace_buffer[0..workspace_length];
    try expectGit(io, workspace, &.{ "init", "-q" });
    try expectGit(io, workspace, &.{ "add", "note.txt" });
    const patch =
        "diff --git a/note.txt b/note.txt\n" ++
        "index 3367afd..3e75765 100644\n" ++
        "--- a/note.txt\n" ++
        "+++ b/note.txt\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+new\n";

    var database_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const database_path = try std.fmt.bufPrint(&database_path_buffer, "{s}/coordinator.sqlite", .{workspace});
    var database = try store.Store.open(database_path);
    defer database.close();
    _ = try database.admitTurn(.{
        .session_id = 140,
        .turn_id = 240,
        .turn_ordinal = 1,
        .entry_id = 340,
        .content_id = 440,
        .expected_conversation_revision = 0,
        .workspace_path = workspace,
        .access_scope_digest = [_]u8{0x81} ** 32,
        .admission_digest = store.semanticDigest(.turn, "patch"),
        .user_text = "Edit",
    });
    var fixture: deterministic_provider.ToolFixture = .{
        .expected_task = "Edit",
        .tool = .apply_patch,
        .tool_arguments = patch,
        .expected_patch_status = .applied,
        .final_answer = "edited",
    };
    var ids: coordinator.IdentitySource = .{ .next_value = 2000 };
    var request: [256 * 1024]u8 = undefined;
    var candidate: [model_protocol.max_response_size]u8 = undefined;
    var tool_call: [model_contract.max_tool_arguments_envelope_size + 128]u8 = undefined;
    var descriptor: [coordinator.max_patch_descriptor_size]u8 = undefined;
    var model_pool = try execution_cells.Pool.init(std.testing.allocator, 1);
    defer model_pool.deinit();
    const model_cell = try model_pool.reserve();
    defer model_cell.release();
    const first = try coordinator.advanceModel(
        &database,
        &ids,
        240,
        "fixture:test",
        workspace,
        io,
        fixture.provider(),
        model_cell,
        .{
            .request = &request,
            .candidate = &candidate,
            .tool_call = &tool_call,
            .descriptor = &descriptor,
        },
    );
    const action = switch (first) {
        .action => |value| value,
        else => return error.ExpectedAction,
    };
    try expectTestFile(tmp.dir, io, "note.txt", "old\n");

    // Simulate a process dying after the durable dispatch fence but before it
    // can record Completion. Recovery must use a new, explicitly duplicate-
    // possible Attempt against the same immutable Patch Intent.
    const lost_operation = try database.readOperation(action.operation_id);
    const lost_length = try database.contentLength(lost_operation.descriptor_content_id);
    var lost_descriptor: [coordinator.max_patch_descriptor_size]u8 = undefined;
    const lost_dispatch = try database.readContent(
        lost_operation.descriptor_content_id,
        lost_descriptor[0..lost_length],
    );
    const lost_attempt_id = try ids.take();
    const lost_admission = try database.admitAttempt(.{
        .operation_id = action.operation_id,
        .attempt_id = lost_attempt_id,
        .attempt_ordinal = 1,
        .dispatch_content_id = lost_operation.descriptor_content_id,
        .dispatch_request = lost_dispatch,
        .dispatch_digest = store.semanticDigest(.dispatch, lost_dispatch),
        .parameters_content_id = try ids.take(),
        .parameters = "local-patch-v1",
        .context_cutoff_revision = (try database.loadDecisionSnapshot(action.turn_id)).conversation_revision,
        .workspace_digest = store.semanticDigest(.workspace, workspace),
        .external_idempotency_key = null,
    });
    try std.testing.expectEqual(store.AdmissionResult.admitted, lost_admission);

    var action_descriptor: [coordinator.max_patch_descriptor_size]u8 = undefined;
    var completion: [patch_tool.result_size]u8 = undefined;
    var visible: [256]u8 = undefined;
    var action_pool = try execution_cells.Pool.init(std.testing.allocator, 1);
    defer action_pool.deinit();
    const action_cell = try action_pool.reserve();
    defer action_cell.release();
    try coordinator.executePatchAction(
        &database,
        &ids,
        io,
        action,
        action_cell,
        .{
            .descriptor = &action_descriptor,
            .completion = &completion,
            .visible_result = &visible,
        },
    );
    try expectTestFile(tmp.dir, io, "note.txt", "new\n");
    var final_pool = try execution_cells.Pool.init(std.testing.allocator, 1);
    defer final_pool.deinit();
    const final_cell = try final_pool.reserve();
    defer final_cell.release();
    const second = try coordinator.advanceModel(
        &database,
        &ids,
        240,
        "fixture:test",
        workspace,
        io,
        fixture.provider(),
        final_cell,
        .{
            .request = &request,
            .candidate = &candidate,
            .tool_call = &tool_call,
            .descriptor = &descriptor,
        },
    );
    try std.testing.expect(second == .completed);
    try std.testing.expectEqual(store.TurnCondition.completed, store.classify(try database.loadDecisionSnapshot(240)));
    var entries: [8]store.ConversationEntry = undefined;
    try std.testing.expectEqual(@as(usize, 4), try database.readConversation(140, 0, &entries));
    try std.testing.expectEqual(store.ConversationKind.tool_call, entries[1].kind);
    try std.testing.expectEqual(store.ConversationKind.tool_result, entries[2].kind);
    try std.testing.expectEqual(store.ConversationKind.assistant_text, entries[3].kind);
}

fn writeTestFile(dir: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn expectTestFile(dir: std.Io.Dir, io: std.Io, path: []const u8, expected: []const u8) !void {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buffer: [128]u8 = undefined;
    const count = try file.readPositionalAll(io, &buffer, 0);
    try std.testing.expectEqualStrings(expected, buffer[0..count]);
}

fn expectGit(io: std.Io, path: []const u8, arguments: []const []const u8) !void {
    var argv: [8][]const u8 = undefined;
    if (arguments.len + 1 > argv.len) return error.InvalidGitFixture;
    argv[0] = "/usr/bin/git";
    @memcpy(argv[1..][0..arguments.len], arguments);
    var environment = std.process.Environ.Map.init(std.heap.page_allocator);
    defer environment.deinit();
    try environment.put("PATH", "/usr/bin:/bin");
    try environment.put("LC_ALL", "C");
    try environment.put("GIT_CONFIG_NOSYSTEM", "1");
    try environment.put("GIT_CONFIG_GLOBAL", "/dev/null");
    var child = try std.process.spawn(io, .{
        .argv = argv[0 .. arguments.len + 1],
        .cwd = .{ .path = path },
        .environ_map = &environment,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const result = try child.wait(io);
    switch (result) {
        .exited => |code| if (code != 0) return error.GitFixtureFailed,
        else => return error.GitFixtureFailed,
    }
}
