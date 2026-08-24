const std = @import("std");
const agent = @import("agent.zig");
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
