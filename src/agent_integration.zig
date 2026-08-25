const std = @import("std");
const agent = @import("agent.zig");
const bash_tool = @import("bash_tool.zig");
const core_contract = @import("core_contract.zig");
const model_operation = @import("model_operation.zig");
const patch_tool = @import("patch_tool.zig");

const task = "Explain the fixture repository.";
const answer = "The fixture contains a durable one-page agent.";

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    var host: agent.Host = .{};
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
    try writeRepoFile(repo, init.io, "note.txt", "old\n");
    const git_add = try std.process.run(allocator, init.io, .{
        .argv = &.{ "/usr/bin/git", "-C", repo_path, "add", "note.txt" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(git_add.stdout);
    defer allocator.free(git_add.stderr);
    switch (git_add.term) {
        .exited => |code| if (code != 0) return error.GitAddFailed,
        else => return error.GitAddFailed,
    }

    var fixture: model_operation.Fixture = .{
        .expected_task = task,
        .final_answer = answer,
    };
    var completed = try agent.runNew(
        &host,
        sessions,
        init.io,
        allocator,
        .{ .workspace_path = repo_path, .model = "fixture:answer", .task = task },
        fixture.provider(),
        null,
    );
    const session_id = completed.session.session_id;
    try expectAnswer(&completed);
    completed.close();

    var resumed = try agent.resumeSession(&host, sessions, init.io, allocator, session_id);
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
            &host,
            sessions,
            init.io,
            allocator,
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
            &host,
            sessions,
            init.io,
            allocator,
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
        &host,
        sessions,
        init.io,
        allocator,
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
    var tool_resumed = try agent.resumeSession(&host, sessions, init.io, allocator, tool_session_id);
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
        &host,
        sessions,
        init.io,
        allocator,
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
        &host,
        sessions,
        init.io,
        allocator,
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
            &host,
            sessions,
            init.io,
            allocator,
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
            &host,
            sessions,
            init.io,
            allocator,
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
        &host,
        sessions,
        init.io,
        allocator,
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
        &host,
        sessions,
        init.io,
        allocator,
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
        &host,
        sessions,
        init.io,
        allocator,
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
    if (agent.resumeSession(&host, sessions, init.io, allocator, uncertain_capture.session_id)) |unexpected| {
        var value = unexpected;
        value.close();
        return error.UncertainBashResumed;
    } else |err| if (err != error.BashPossiblyExecuted) {
        return err;
    }
    if (agent.resumeSession(&host, sessions, init.io, allocator, uncertain_capture.session_id)) |unexpected| {
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

    const patch =
        "diff --git a/note.txt b/note.txt\n" ++
        "--- a/note.txt\n" ++
        "+++ b/note.txt\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+new\n";
    var patch_deny_fixture: model_operation.ToolFixture = .{
        .expected_task = task,
        .tool = .apply_patch,
        .tool_arguments = patch,
        .final_answer = "The exact patch was denied and the worktree was not changed.",
        .expected_patch_status = .denied,
    };
    var patch_deny: PatchDenyPolicy = .{};
    var patch_denied = try agent.runNew(
        &host,
        sessions,
        init.io,
        allocator,
        .{
            .workspace_path = repo_path,
            .model = "fixture:patch-denied",
            .task = task,
            .patch_policy = patch_deny.policy(),
        },
        patch_deny_fixture.provider(),
        null,
    );
    patch_denied.close();
    try expectRepoFile(repo, init.io, "note.txt", "old\n");

    var patch_stale_fixture: model_operation.ToolFixture = .{
        .expected_task = task,
        .tool = .apply_patch,
        .tool_arguments = patch,
        .final_answer = "The approved patch became stale and the external bytes were preserved.",
        .expected_patch_status = .stale,
    };
    var patch_stale: PatchStalePolicy = .{ .io = init.io, .repo = repo };
    var patch_stale_completed = try agent.runNew(
        &host,
        sessions,
        init.io,
        allocator,
        .{
            .workspace_path = repo_path,
            .model = "fixture:patch-stale",
            .task = task,
            .patch_policy = patch_stale.policy(),
        },
        patch_stale_fixture.provider(),
        null,
    );
    patch_stale_completed.close();
    try expectRepoFile(repo, init.io, "note.txt", "external\n");
    try writeRepoFile(repo, init.io, "note.txt", "old\n");

    var patch_allow_fixture: model_operation.ToolFixture = .{
        .expected_task = task,
        .tool = .apply_patch,
        .tool_arguments = patch,
        .final_answer = "must wait for the patch application step",
    };
    var patch_allow: PatchAllowPolicy = .{};
    var patch_allow_capture: SessionCapture = .{};
    if (agent.runNew(
        &host,
        sessions,
        init.io,
        allocator,
        .{
            .workspace_path = repo_path,
            .model = "fixture:patch-allowed",
            .task = task,
            .patch_policy = patch_allow.policy(),
        },
        patch_allow_fixture.provider(),
        patch_allow_capture.observer(),
    )) |unexpected| {
        var value = unexpected;
        value.close();
        return error.AllowedPatchExecutedDuringPermissionStep;
    } else |err| if (err != error.PatchExecutionDeferred) {
        return err;
    }
    try expectRepoFile(repo, init.io, "note.txt", "old\n");
    if (agent.resumeSession(&host, sessions, init.io, allocator, patch_allow_capture.session_id)) |unexpected| {
        var value = unexpected;
        value.close();
        return error.AllowedPatchResumedPastPermissionStep;
    } else |err| if (err != error.PatchExecutionDeferred) {
        return err;
    }

    var patch_ask_fixture: model_operation.ToolFixture = .{
        .expected_task = task,
        .tool = .apply_patch,
        .tool_arguments = patch,
        .final_answer = "must wait for approval",
    };
    var patch_ask: PatchAskCrashPolicy = .{};
    var patch_ask_capture: SessionCapture = .{};
    if (agent.runNew(
        &host,
        sessions,
        init.io,
        allocator,
        .{
            .workspace_path = repo_path,
            .model = "fixture:patch-approval",
            .task = task,
            .patch_policy = patch_ask.policy(),
        },
        patch_ask_fixture.provider(),
        patch_ask_capture.observer(),
    )) |unexpected| {
        var value = unexpected;
        value.close();
        return error.PatchApprovalDidNotSuspend;
    } else |err| if (err != error.InjectedApprovalCrash) {
        return err;
    }
    for (0..2) |_| {
        if (agent.resumeSession(&host, sessions, init.io, allocator, patch_ask_capture.session_id)) |unexpected| {
            var value = unexpected;
            value.close();
            return error.PatchApprovalProjectionMissing;
        } else |err| if (err != error.PatchApprovalRequired) {
            return err;
        }
    }
    try expectRepoFile(repo, init.io, "note.txt", "old\n");

    const permission_crash_cases = [_]struct {
        classification: patch_tool.Decision,
        answer: bool,
        allowed: bool,
    }{
        .{ .classification = .allow, .answer = false, .allowed = true },
        .{ .classification = .deny, .answer = false, .allowed = false },
        .{ .classification = .ask, .answer = true, .allowed = true },
        .{ .classification = .ask, .answer = false, .allowed = false },
    };
    for (permission_crash_cases) |case| {
        var crash_fixture: model_operation.ToolFixture = .{
            .expected_task = task,
            .tool = .apply_patch,
            .tool_arguments = patch,
            .final_answer = "The recovered permission decision reached turn two.",
            .expected_patch_status = .denied,
        };
        var crash_policy: PatchCrashPolicy = .{
            .classification = case.classification,
            .answer = case.answer,
        };
        var crash_capture: SessionCapture = .{};
        var permission_injection: CrashInjection = .{ .target = .after_patch_permission_binding };
        if (agent.runNew(
            &host,
            sessions,
            init.io,
            allocator,
            .{
                .workspace_path = repo_path,
                .model = "fixture:patch-permission-crash",
                .task = task,
                .patch_policy = crash_policy.policy(),
                .fault = permission_injection.hook(),
            },
            crash_fixture.provider(),
            crash_capture.observer(),
        )) |unexpected| {
            var value = unexpected;
            value.close();
            return error.PatchPermissionBindingCrashMissed;
        } else |err| if (err != error.InjectedCrash) {
            return err;
        }
        if (case.allowed) {
            if (agent.resumeSession(&host, sessions, init.io, allocator, crash_capture.session_id)) |unexpected| {
                var value = unexpected;
                value.close();
                return error.RecoveredPatchPermissionExecuted;
            } else |err| if (err != error.PatchExecutionDeferred) {
                return err;
            }
        } else {
            var recovered_permission = try agent.resumeWithProvider(
                &host,
                sessions,
                init.io,
                allocator,
                crash_capture.session_id,
                crash_fixture.provider(),
            );
            recovered_permission.close();
            if (crash_fixture.calls != 2) return error.RecoveredPatchDenialMissingFromTurnTwo;
        }
        try expectRepoFile(repo, init.io, "note.txt", "old\n");
    }

    var incomplete: model_operation.Fixture = .{
        .expected_task = task,
        .final_answer = "not published",
        .finish_response = false,
    };
    if (agent.runNew(
        &host,
        sessions,
        init.io,
        allocator,
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
        &host,
        sessions,
        init.io,
        allocator,
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

const PatchAllowPolicy = struct {
    fn policy(self: *PatchAllowPolicy) patch_tool.Policy {
        return .{ .context = self, .classify_fn = classify, .ask_fn = ask };
    }

    fn classify(_: *anyopaque, subject: patch_tool.PermissionSubject, patch: []const u8) anyerror!patch_tool.Decision {
        if (subject.validation.patch_digest == 0 or subject.operation_id == 0 or patch.len == 0) {
            return error.InvalidPermissionSubject;
        }
        return .allow;
    }

    fn ask(_: *anyopaque, _: patch_tool.PermissionSubject, _: []const u8) anyerror!bool {
        return error.UnexpectedApprovalPrompt;
    }
};

const PatchDenyPolicy = struct {
    fn policy(self: *PatchDenyPolicy) patch_tool.Policy {
        return .{ .context = self, .classify_fn = classify, .ask_fn = ask };
    }

    fn classify(_: *anyopaque, _: patch_tool.PermissionSubject, _: []const u8) anyerror!patch_tool.Decision {
        return .deny;
    }

    fn ask(_: *anyopaque, _: patch_tool.PermissionSubject, _: []const u8) anyerror!bool {
        return error.UnexpectedApprovalPrompt;
    }
};

const PatchStalePolicy = struct {
    io: std.Io,
    repo: std.Io.Dir,

    fn policy(self: *PatchStalePolicy) patch_tool.Policy {
        return .{ .context = self, .classify_fn = classify, .ask_fn = ask };
    }

    fn classify(_: *anyopaque, _: patch_tool.PermissionSubject, _: []const u8) anyerror!patch_tool.Decision {
        return .ask;
    }

    fn ask(context: *anyopaque, _: patch_tool.PermissionSubject, _: []const u8) anyerror!bool {
        const self: *PatchStalePolicy = @ptrCast(@alignCast(context));
        try writeRepoFile(self.repo, self.io, "note.txt", "external\n");
        return true;
    }
};

const PatchAskCrashPolicy = struct {
    fn policy(self: *PatchAskCrashPolicy) patch_tool.Policy {
        return .{ .context = self, .classify_fn = classify, .ask_fn = ask };
    }

    fn classify(_: *anyopaque, _: patch_tool.PermissionSubject, _: []const u8) anyerror!patch_tool.Decision {
        return .ask;
    }

    fn ask(_: *anyopaque, _: patch_tool.PermissionSubject, _: []const u8) anyerror!bool {
        return error.InjectedApprovalCrash;
    }
};

const PatchCrashPolicy = struct {
    classification: patch_tool.Decision,
    answer: bool,

    fn policy(self: *PatchCrashPolicy) patch_tool.Policy {
        return .{ .context = self, .classify_fn = classify, .ask_fn = ask };
    }

    fn classify(context: *anyopaque, _: patch_tool.PermissionSubject, _: []const u8) anyerror!patch_tool.Decision {
        const self: *PatchCrashPolicy = @ptrCast(@alignCast(context));
        return self.classification;
    }

    fn ask(context: *anyopaque, _: patch_tool.PermissionSubject, _: []const u8) anyerror!bool {
        const self: *PatchCrashPolicy = @ptrCast(@alignCast(context));
        return self.answer;
    }
};

fn cancelAgentBash(io: std.Io, cancellation: *std.atomic.Value(bool)) !void {
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    cancellation.store(true, .release);
}

fn writeRepoFile(repo: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try repo.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn expectRepoFile(repo: std.Io.Dir, io: std.Io, path: []const u8, expected: []const u8) !void {
    var file = try repo.openFile(io, path, .{});
    defer file.close(io);
    var buffer: [128]u8 = undefined;
    const count = try file.readPositionalAll(io, &buffer, 0);
    if (!std.mem.eql(u8, buffer[0..count], expected)) return error.RepositoryFileMismatch;
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
