const std = @import("std");
const agent = @import("agent.zig");
const bash_tool = @import("bash_tool.zig");
const core_contract = @import("core_contract.zig");
const model_operation = @import("model_operation.zig");

const task = "Explain the fixture repository.";
const answer = "The fixture contains a durable one-page agent.";

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.InvalidArguments;
    const wasm = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(wasm);
    try core_contract.verify(wasm);

    var random: [8]u8 = undefined;
    init.io.random(&random);
    var root_path_buffer: [96]u8 = undefined;
    const root_path = try std.fmt.bufPrint(
        &root_path_buffer,
        ".zig-cache/agent-integration-{x}",
        .{random},
    );
    var tmp = try std.Io.Dir.cwd().createDirPathOpen(init.io, root_path, .{});
    defer {
        tmp.close(init.io);
        std.Io.Dir.cwd().deleteTree(init.io, root_path) catch {};
    }
    try tmp.createDir(init.io, "sessions", .default_dir);
    try tmp.createDir(init.io, "repo", .default_dir);
    var repo = try tmp.openDir(init.io, "repo", .{});
    defer repo.close(init.io);
    var sessions = try tmp.openDir(init.io, "sessions", .{});
    defer sessions.close(init.io);
    var path_buffer: [128]u8 = undefined;
    const repo_path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/repo",
        .{root_path},
    );
    const git_init = try std.process.run(allocator, init.io, .{
        .argv = &.{ "git", "init", "--quiet", repo_path },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(git_init.stdout);
    defer allocator.free(git_init.stderr);
    switch (git_init.term) {
        .exited => |code| if (code != 0) return error.GitInitFailed,
        else => return error.GitInitFailed,
    }

    var incompatible = try allocator.dupe(u8, wasm);
    defer allocator.free(incompatible);
    const initialize_offset = std.mem.indexOf(u8, incompatible, "initialize") orelse
        return error.InitializeExportNotFound;
    incompatible[initialize_offset + "initialize".len - 1] = 'f';
    var rejected_capture: SessionCapture = .{};
    var rejected_fixture: model_operation.Fixture = .{
        .expected_task = task,
        .final_answer = answer,
    };
    if (agent.runNew(
        sessions,
        init.io,
        allocator,
        incompatible,
        .{ .workspace_path = repo_path, .model = "fixture:invalid", .task = task },
        rejected_fixture.provider(),
        rejected_capture.observer(),
    )) |unexpected| {
        var value = unexpected;
        value.close();
        return error.IncompatibleCoreAccepted;
    } else |err| if (err != error.JavaScriptFunctionUnavailable) {
        return err;
    }
    if (rejected_capture.session_id != 0) return error.InvalidCorePublishedSession;

    var misbound = try allocator.dupe(u8, wasm);
    defer allocator.free(misbound);
    const final_name = "finalEntryId";
    const context_name = "contextCount";
    comptime std.debug.assert(final_name.len == context_name.len);
    const final_offset = std.mem.indexOf(u8, misbound, final_name) orelse
        return error.FinalEntryExportNotFound;
    const context_offset = std.mem.indexOf(u8, misbound, context_name) orelse
        return error.ContextCountExportNotFound;
    var name_buffer: [final_name.len]u8 = undefined;
    @memcpy(&name_buffer, misbound[final_offset..][0..final_name.len]);
    @memcpy(misbound[final_offset..][0..final_name.len], misbound[context_offset..][0..context_name.len]);
    @memcpy(misbound[context_offset..][0..context_name.len], &name_buffer);
    var misbound_capture: SessionCapture = .{};
    var misbound_fixture: model_operation.Fixture = .{
        .expected_task = task,
        .final_answer = answer,
    };
    if (agent.runNew(
        sessions,
        init.io,
        allocator,
        misbound,
        .{ .workspace_path = repo_path, .model = "fixture:misbound", .task = task },
        misbound_fixture.provider(),
        misbound_capture.observer(),
    )) |unexpected| {
        var value = unexpected;
        value.close();
        return error.MisboundCoreAccepted;
    } else |err| if (err != error.CoreAbiMismatch) {
        return err;
    }
    if (misbound_capture.session_id != 0) return error.MisboundCorePublishedSession;

    var fixture: model_operation.Fixture = .{
        .expected_task = task,
        .final_answer = answer,
    };
    var completed = try agent.runNew(
        sessions,
        init.io,
        allocator,
        wasm,
        .{ .workspace_path = repo_path, .model = "fixture:answer", .task = task },
        fixture.provider(),
        null,
    );
    const session_id = completed.session.session_id;
    try expectAnswer(&completed);
    completed.close();

    if (agent.resumeSession(sessions, init.io, allocator, misbound, session_id)) |unexpected| {
        var value = unexpected;
        value.close();
        return error.MisboundResumeAccepted;
    } else |err| if (err != error.CoreAbiMismatch) {
        return err;
    }

    var resumed = try agent.resumeSession(sessions, init.io, allocator, wasm, session_id);
    defer resumed.close();
    if (resumed.session.ownership_epoch != 2) return error.ResumeEpochMismatch;
    try expectAnswer(&resumed);

    const crash_boundaries = [_]agent.FaultBoundary{
        .after_completion_persist,
        .after_final_blob,
        .after_assistant_entry,
    };
    for (crash_boundaries) |boundary| {
        var capture: SessionCapture = .{};
        var injection: CrashInjection = .{ .target = boundary };
        var crash_fixture: model_operation.Fixture = .{
            .expected_task = task,
            .final_answer = answer,
        };
        if (agent.runNew(
            sessions,
            init.io,
            allocator,
            wasm,
            .{
                .workspace_path = repo_path,
                .model = "fixture:crash",
                .task = task,
                .fault = injection.hook(),
            },
            crash_fixture.provider(),
            capture.observer(),
        )) |unexpected| {
            var value = unexpected;
            value.close();
            return error.CrashBoundaryNotReached;
        } else |err| if (err != error.InjectedCrash) {
            return err;
        }
        if (capture.session_id == 0) return error.SessionIdentityNotObserved;
        var recovered = try agent.resumeSession(
            sessions,
            init.io,
            allocator,
            wasm,
            capture.session_id,
        );
        try expectAnswer(&recovered);
        recovered.close();
    }

    var call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
    const tool_arguments = try bash_tool.encodeCall(&call_buffer, .{
        .command = "printf inspected > inspection.txt; git status --short",
        .timeout_ms = 5000,
    });
    var tool_fixture: model_operation.ToolFixture = .{
        .expected_task = task,
        .tool_arguments = tool_arguments,
        .final_answer = "Bash inspected the repository and the typed result reached turn two.",
    };
    var allow_policy: AllowPolicy = .{};
    var tool_completed = try agent.runNew(
        sessions,
        init.io,
        allocator,
        wasm,
        .{
            .workspace_path = repo_path,
            .model = "fixture:bash",
            .task = task,
            .bash_policy = allow_policy.policy(),
        },
        tool_fixture.provider(),
        null,
    );
    const tool_session_id = tool_completed.session.session_id;
    if (tool_fixture.calls != 2 or tool_completed.session.entry_count != 4) {
        return error.ToolConversationIncomplete;
    }
    var inspection = try repo.openFile(init.io, "inspection.txt", .{});
    inspection.close(init.io);
    var tool_answer_buffer: [128]u8 = undefined;
    const tool_answer = try tool_completed.session.readBlob(
        tool_completed.session.ownerToken(),
        tool_completed.final_ref,
        0,
        &tool_answer_buffer,
    );
    if (!std.mem.eql(u8, tool_answer, tool_fixture.final_answer)) return error.ToolFinalAnswerMismatch;
    tool_completed.close();
    var tool_resumed = try agent.resumeSession(sessions, init.io, allocator, wasm, tool_session_id);
    if (tool_resumed.session.ownership_epoch != 2) return error.ToolResumeEpochMismatch;
    tool_resumed.close();

    var denied_call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
    const denied_arguments = try bash_tool.encodeCall(&denied_call_buffer, .{
        .command = "printf denied > denied.txt",
        .timeout_ms = 5000,
    });
    var denied_fixture: model_operation.ToolFixture = .{
        .expected_task = task,
        .tool_arguments = denied_arguments,
        .final_answer = "The exact Bash call was denied without execution.",
        .expected_tool_status = .denied,
    };
    var deny_policy: DenyPolicy = .{};
    var denied_completed = try agent.runNew(
        sessions,
        init.io,
        allocator,
        wasm,
        .{
            .workspace_path = repo_path,
            .model = "fixture:denied-bash",
            .task = task,
            .bash_policy = deny_policy.policy(),
        },
        denied_fixture.provider(),
        null,
    );
    denied_completed.close();
    if (repo.access(init.io, "denied.txt", .{})) |_| {
        return error.DeniedBashExecuted;
    } else |err| if (err != error.FileNotFound) {
        return err;
    }

    var cancelled_call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
    const cancelled_arguments = try bash_tool.encodeCall(&cancelled_call_buffer, .{
        .command = "sleep 2",
        .timeout_ms = 5000,
    });
    var cancelled_fixture: model_operation.ToolFixture = .{
        .expected_task = task,
        .tool_arguments = cancelled_arguments,
        .final_answer = "The running Bash call was cancelled and reported to turn two.",
        .expected_tool_status = .cancelled,
    };
    var cancellation: std.atomic.Value(bool) = .init(false);
    var cancel_future = init.io.async(cancelAgentBash, .{ init.io, &cancellation });
    var cancelled_completed = try agent.runNew(
        sessions,
        init.io,
        allocator,
        wasm,
        .{
            .workspace_path = repo_path,
            .model = "fixture:cancelled-bash",
            .task = task,
            .bash_policy = allow_policy.policy(),
            .bash_cancelled = &cancellation,
        },
        cancelled_fixture.provider(),
        null,
    );
    try cancel_future.await(init.io);
    cancelled_completed.close();

    const result_boundaries = [_]agent.FaultBoundary{
        .after_bash_result,
        .after_tool_result_entry,
        .after_tool_checkpoint,
    };
    for (result_boundaries) |boundary| {
        var result_call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
        const result_arguments = try bash_tool.encodeCall(&result_call_buffer, .{
            .command = "printf r >> recovered-results.txt",
            .timeout_ms = 5000,
        });
        var result_fixture: model_operation.ToolFixture = .{
            .expected_task = task,
            .tool_arguments = result_arguments,
            .final_answer = "The durable Bash result resumed into turn two.",
        };
        var result_capture: SessionCapture = .{};
        var result_injection: CrashInjection = .{ .target = boundary };
        if (agent.runNew(
            sessions,
            init.io,
            allocator,
            wasm,
            .{
                .workspace_path = repo_path,
                .model = "fixture:recover-bash",
                .task = task,
                .bash_policy = allow_policy.policy(),
                .fault = result_injection.hook(),
            },
            result_fixture.provider(),
            result_capture.observer(),
        )) |unexpected| {
            var value = unexpected;
            value.close();
            return error.BashResultBoundaryNotReached;
        } else |err| if (err != error.InjectedCrash) {
            return err;
        }
        var result_recovered = try agent.resumeWithProvider(
            sessions,
            init.io,
            allocator,
            wasm,
            result_capture.session_id,
            result_fixture.provider(),
        );
        if (result_fixture.calls != 2) return error.BashResultDidNotReachTurnTwo;
        result_recovered.close();
    }
    var recovered_results = try repo.openFile(init.io, "recovered-results.txt", .{});
    defer recovered_results.close(init.io);
    var recovered_bytes: [4]u8 = undefined;
    const recovered_length = try recovered_results.readPositionalAll(init.io, &recovered_bytes, 0);
    if (recovered_length != result_boundaries.len) return error.BashResultReexecuted;

    var denied_recovery_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
    const denied_recovery_arguments = try bash_tool.encodeCall(&denied_recovery_buffer, .{
        .command = "printf bad > denied-recovery.txt",
        .timeout_ms = 5000,
    });
    var denied_recovery_fixture: model_operation.ToolFixture = .{
        .expected_task = task,
        .tool_arguments = denied_recovery_arguments,
        .final_answer = "The durable denial resumed into turn two.",
        .expected_tool_status = .denied,
    };
    var denied_recovery_capture: SessionCapture = .{};
    var denied_recovery_injection: CrashInjection = .{ .target = .after_bash_result };
    if (agent.runNew(
        sessions,
        init.io,
        allocator,
        wasm,
        .{
            .workspace_path = repo_path,
            .model = "fixture:recover-denial",
            .task = task,
            .bash_policy = deny_policy.policy(),
            .fault = denied_recovery_injection.hook(),
        },
        denied_recovery_fixture.provider(),
        denied_recovery_capture.observer(),
    )) |unexpected| {
        var value = unexpected;
        value.close();
        return error.DeniedResultBoundaryNotReached;
    } else |err| if (err != error.InjectedCrash) {
        return err;
    }
    var denied_recovered = try agent.resumeWithProvider(
        sessions,
        init.io,
        allocator,
        wasm,
        denied_recovery_capture.session_id,
        denied_recovery_fixture.provider(),
    );
    denied_recovered.close();
    if (repo.access(init.io, "denied-recovery.txt", .{})) |_| {
        return error.RecoveredDenialExecuted;
    } else |err| if (err != error.FileNotFound) {
        return err;
    }

    var uncertain_call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
    const uncertain_arguments = try bash_tool.encodeCall(&uncertain_call_buffer, .{
        .command = "printf x >> uncertain.txt",
        .timeout_ms = 5000,
    });
    var uncertain_fixture: model_operation.ToolFixture = .{
        .expected_task = task,
        .tool_arguments = uncertain_arguments,
        .final_answer = "must not be reached",
    };
    var uncertain_capture: SessionCapture = .{};
    var uncertain_injection: CrashInjection = .{ .target = .after_bash_execution };
    if (agent.runNew(
        sessions,
        init.io,
        allocator,
        wasm,
        .{
            .workspace_path = repo_path,
            .model = "fixture:uncertain-bash",
            .task = task,
            .bash_policy = allow_policy.policy(),
            .fault = uncertain_injection.hook(),
        },
        uncertain_fixture.provider(),
        uncertain_capture.observer(),
    )) |unexpected| {
        var value = unexpected;
        value.close();
        return error.UncertainBashDidNotCrash;
    } else |err| if (err != error.InjectedCrash) {
        return err;
    }
    if (agent.resumeSession(sessions, init.io, allocator, wasm, uncertain_capture.session_id)) |unexpected| {
        var value = unexpected;
        value.close();
        return error.UncertainBashResumed;
    } else |err| if (err != error.BashPossiblyExecuted) {
        return err;
    }
    if (agent.resumeSession(sessions, init.io, allocator, wasm, uncertain_capture.session_id)) |unexpected| {
        var value = unexpected;
        value.close();
        return error.IndeterminateBashResumed;
    } else |err| if (err != error.BashPossiblyExecuted) {
        return err;
    }
    var uncertain_file = try repo.openFile(init.io, "uncertain.txt", .{});
    defer uncertain_file.close(init.io);
    var uncertain_bytes: [2]u8 = undefined;
    const uncertain_length = try uncertain_file.readPositionalAll(init.io, &uncertain_bytes, 0);
    if (uncertain_length != 1 or uncertain_bytes[0] != 'x') return error.UncertainBashReplayed;

    var incomplete: model_operation.Fixture = .{
        .expected_task = task,
        .final_answer = "not published",
        .finish_response = false,
    };
    if (agent.runNew(
        sessions,
        init.io,
        allocator,
        wasm,
        .{ .workspace_path = repo_path, .model = "fixture:incomplete", .task = task },
        incomplete.provider(),
        null,
    )) |unexpected| {
        var value = unexpected;
        value.close();
        return error.IncompleteResponseAccepted;
    } else |err| if (err != error.ProviderResponseIncomplete) {
        return err;
    }

    var truncated: model_operation.Fixture = .{
        .expected_task = task,
        .final_answer = "partial",
        .status = .length_truncated,
    };
    if (agent.runNew(
        sessions,
        init.io,
        allocator,
        wasm,
        .{ .workspace_path = repo_path, .model = "fixture:truncated", .task = task },
        truncated.provider(),
        null,
    )) |unexpected| {
        var value = unexpected;
        value.close();
        return error.TruncatedResponseAccepted;
    } else |err| if (err != error.ModelResponseTruncated) {
        return err;
    }
}

const SessionCapture = struct {
    session_id: u64 = 0,

    fn observer(self: *SessionCapture) agent.Observer {
        return .{ .context = self, .session_created = created };
    }

    fn created(context: *anyopaque, session_id: u64) anyerror!void {
        const self: *SessionCapture = @ptrCast(@alignCast(context));
        self.session_id = session_id;
    }
};

const CrashInjection = struct {
    target: agent.FaultBoundary,

    fn hook(self: *CrashInjection) agent.FaultHook {
        return .{ .context = self, .reached = reached };
    }

    fn reached(context: *anyopaque, boundary: agent.FaultBoundary) anyerror!void {
        const self: *CrashInjection = @ptrCast(@alignCast(context));
        if (boundary == self.target) return error.InjectedCrash;
    }
};

const AllowPolicy = struct {
    fn policy(self: *AllowPolicy) bash_tool.Policy {
        return .{ .context = self, .classify_fn = classify, .ask_fn = ask };
    }

    fn classify(_: *anyopaque, digest: u64, call: bash_tool.Call) anyerror!bash_tool.Decision {
        if (digest == 0 or call.command.len == 0) return error.InvalidPermissionSubject;
        return .allow;
    }

    fn ask(_: *anyopaque, _: u64, _: bash_tool.Call) anyerror!bool {
        return error.UnexpectedApprovalPrompt;
    }
};

const DenyPolicy = struct {
    fn policy(self: *DenyPolicy) bash_tool.Policy {
        return .{ .context = self, .classify_fn = classify, .ask_fn = ask };
    }

    fn classify(_: *anyopaque, _: u64, _: bash_tool.Call) anyerror!bash_tool.Decision {
        return .deny;
    }

    fn ask(_: *anyopaque, _: u64, _: bash_tool.Call) anyerror!bool {
        return error.UnexpectedApprovalPrompt;
    }
};

fn cancelAgentBash(io: std.Io, cancellation: *std.atomic.Value(bool)) !void {
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    cancellation.store(true, .release);
}

fn expectAnswer(completed: *agent.Completed) !void {
    var buffer: [128]u8 = undefined;
    const actual = try completed.session.readBlob(
        completed.session.ownerToken(),
        completed.final_ref,
        0,
        &buffer,
    );
    if (!std.mem.eql(u8, actual, answer)) return error.FinalAnswerMismatch;
}
