const std = @import("std");
const agent = @import("agent.zig");
const bash_tool = @import("bash_tool.zig");
const model_operation = @import("model_operation.zig");
const patch_tool = @import("patch_tool.zig");
const session_store = @import("session.zig");

const output_window_size = 4096;

const Arguments = struct {
    state_path: ?[]const u8 = null,
    repo_path: ?[]const u8 = null,
    model: ?[]const u8 = null,
    fixture_response: ?[]const u8 = null,
    fixture_bash_command: ?[]const u8 = null,
    fixture_patch_path: ?[]const u8 = null,
    bash_timeout_ms: u32 = 5000,
    allow_bash: bool = false,
    allow_patch: bool = false,
    deny_patch: bool = false,
    task: ?[]const u8 = null,
    resume_id: ?u64 = null,
};

const Output = struct {
    io: std.Io,

    fn sessionCreated(context: *anyopaque, session_id: u64) anyerror!void {
        const self: *Output = @ptrCast(@alignCast(context));
        var id_buffer: [16]u8 = undefined;
        const id = try session_store.formatId(session_id, &id_buffer);
        var line_buffer: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buffer, "Session: {s}\n", .{id});
        try std.Io.File.stdout().writeStreamingAll(self.io, line);
    }

    fn observer(self: *Output) agent.Observer {
        return .{ .context = self, .session_created = sessionCreated };
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    var host: agent.Host = .{};
    const raw_args = try init.minimal.args.toSlice(allocator);
    const arguments = try parseArguments(raw_args);

    const state_path = try resolveStatePath(
        init.minimal.environ,
        allocator,
        arguments.state_path,
    );
    defer allocator.free(state_path);
    var sessions = try std.Io.Dir.cwd().createDirPathOpen(
        init.io,
        state_path,
        .{ .permissions = .fromMode(0o700) },
    );
    defer sessions.close(init.io);
    var completed: agent.Completed = if (arguments.resume_id) |session_id|
        try agent.resumeSession(&host, sessions, init.io, allocator, session_id)
    else blk: {
        const model = arguments.model orelse return error.MissingModel;
        if (!std.mem.startsWith(u8, model, "fixture:")) return error.UnsupportedModel;
        const response = arguments.fixture_response orelse return error.MissingFixtureResponse;
        const task = arguments.task orelse return error.MissingTask;
        const workspace_path = try resolveWorkspacePath(init.io, allocator, arguments.repo_path);
        defer allocator.free(workspace_path);
        var output: Output = .{ .io = init.io };
        if (arguments.fixture_patch_path) |patch_path| {
            const patch = try std.Io.Dir.cwd().readFileAlloc(
                init.io,
                patch_path,
                allocator,
                .limited(patch_tool.max_patch_size),
            );
            defer allocator.free(patch);
            var fixture: model_operation.ToolFixture = .{
                .expected_task = task,
                .tool = .apply_patch,
                .tool_arguments = patch,
                .final_answer = response,
                .expected_patch_status = .denied,
            };
            var permission: InteractivePatchPolicy = .{
                .io = init.io,
                .mode = if (arguments.allow_patch)
                    .allow
                else if (arguments.deny_patch)
                    .deny
                else
                    .ask,
            };
            if (agent.runNew(
                &host,
                sessions,
                init.io,
                allocator,
                .{
                    .workspace_path = workspace_path,
                    .model = model,
                    .task = task,
                    .patch_policy = permission.policy(),
                },
                fixture.provider(),
                output.observer(),
            )) |value| {
                break :blk value;
            } else |err| switch (err) {
                error.PatchExecutionDeferred => {
                    try std.Io.File.stdout().writeStreamingAll(
                        init.io,
                        "Patch approved and durably bound; application is deferred to the next implementation step.\n",
                    );
                    return;
                },
                else => return err,
            }
        }
        if (arguments.fixture_bash_command) |command| {
            var call_buffer: [bash_tool.call_header_size + bash_tool.max_command_size]u8 = undefined;
            const encoded_call = try bash_tool.encodeCall(&call_buffer, .{
                .command = command,
                .timeout_ms = arguments.bash_timeout_ms,
            });
            var fixture: model_operation.ToolFixture = .{
                .expected_task = task,
                .tool_arguments = encoded_call,
                .final_answer = response,
            };
            var permission: InteractivePolicy = .{
                .io = init.io,
                .automatic = arguments.allow_bash,
            };
            break :blk try agent.runNew(
                &host,
                sessions,
                init.io,
                allocator,
                .{
                    .workspace_path = workspace_path,
                    .model = model,
                    .task = task,
                    .bash_policy = permission.policy(),
                },
                fixture.provider(),
                output.observer(),
            );
        }
        var fixture: model_operation.Fixture = .{
            .expected_task = task,
            .final_answer = response,
        };
        break :blk try agent.runNew(
            &host,
            sessions,
            init.io,
            allocator,
            .{ .workspace_path = workspace_path, .model = model, .task = task },
            fixture.provider(),
            output.observer(),
        );
    };
    defer completed.close();

    if (arguments.resume_id != null) {
        var output: Output = .{ .io = init.io };
        try Output.sessionCreated(&output, completed.session.session_id);
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "Final Answer:\n");
    try writeFinalAnswer(init.io, &completed);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

fn resolveStatePath(
    environ: std.process.Environ,
    allocator: std.mem.Allocator,
    configured: ?[]const u8,
) ![]u8 {
    if (configured) |path| return allocator.dupe(u8, path);
    var environment = try environ.createMap(allocator);
    defer environment.deinit();
    const home = environment.get("HOME") orelse return error.MissingHomeDirectory;
    return std.fs.path.join(allocator, &.{ home, ".onepage", "sessions" });
}

fn parseArguments(args: []const []const u8) !Arguments {
    if (args.len < 1) return error.InvalidArguments;
    var parsed: Arguments = .{};
    var index: usize = 1;
    while (index < args.len) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--state")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.state_path = args[index];
        } else if (std.mem.eql(u8, argument, "--repo")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.repo_path = args[index];
        } else if (std.mem.eql(u8, argument, "--model")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.model = args[index];
        } else if (std.mem.eql(u8, argument, "--fixture-response")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.fixture_response = args[index];
        } else if (std.mem.eql(u8, argument, "--fixture-bash-command")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.fixture_bash_command = args[index];
        } else if (std.mem.eql(u8, argument, "--fixture-patch")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.fixture_patch_path = args[index];
        } else if (std.mem.eql(u8, argument, "--bash-timeout-ms")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.bash_timeout_ms = try std.fmt.parseInt(u32, args[index], 10);
        } else if (std.mem.eql(u8, argument, "--allow-bash")) {
            parsed.allow_bash = true;
        } else if (std.mem.eql(u8, argument, "--allow-patch")) {
            parsed.allow_patch = true;
        } else if (std.mem.eql(u8, argument, "--deny-patch")) {
            parsed.deny_patch = true;
        } else if (std.mem.eql(u8, argument, "--resume")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.resume_id = try std.fmt.parseInt(u64, args[index], 16);
        } else if (std.mem.startsWith(u8, argument, "--")) {
            return error.UnknownOption;
        } else {
            if (parsed.task != null) return error.MultipleTasks;
            parsed.task = argument;
        }
        index += 1;
    }
    if (parsed.resume_id != null and
        (parsed.task != null or parsed.model != null or parsed.fixture_response != null or
            parsed.repo_path != null or parsed.fixture_bash_command != null or parsed.allow_bash or
            parsed.fixture_patch_path != null or parsed.allow_patch or parsed.deny_patch))
    {
        return error.ResumeArgumentsConflict;
    }
    if (parsed.allow_patch and parsed.deny_patch) return error.ConflictingPatchPolicy;
    if ((parsed.allow_patch or parsed.deny_patch) and parsed.fixture_patch_path == null) {
        return error.PatchPolicyWithoutPatch;
    }
    return parsed;
}

const InteractivePolicy = struct {
    io: std.Io,
    automatic: bool,

    fn policy(self: *InteractivePolicy) bash_tool.Policy {
        return .{ .context = self, .classify_fn = classify, .ask_fn = ask };
    }

    fn classify(context: *anyopaque, _: u64, _: bash_tool.Call) anyerror!bash_tool.Decision {
        const self: *InteractivePolicy = @ptrCast(@alignCast(context));
        return if (self.automatic) .allow else .ask;
    }

    fn ask(context: *anyopaque, digest: u64, call: bash_tool.Call) anyerror!bool {
        const self: *InteractivePolicy = @ptrCast(@alignCast(context));
        var header: [128]u8 = undefined;
        const prompt = try std.fmt.bufPrint(
            &header,
            "Bash ({d} ms, digest {x:0>16}):\n",
            .{ call.timeout_ms, digest },
        );
        try std.Io.File.stdout().writeStreamingAll(self.io, prompt);
        try std.Io.File.stdout().writeStreamingAll(self.io, call.command);
        try std.Io.File.stdout().writeStreamingAll(self.io, "\nAllow? [y/N] ");
        var answer: [8]u8 = undefined;
        const count = try std.Io.File.stdin().readStreaming(self.io, &.{&answer});
        return count > 0 and (answer[0] == 'y' or answer[0] == 'Y');
    }
};

const InteractivePatchPolicy = struct {
    const Mode = enum { ask, allow, deny };

    io: std.Io,
    mode: Mode,

    fn policy(self: *InteractivePatchPolicy) patch_tool.Policy {
        return .{ .context = self, .classify_fn = classify, .ask_fn = ask };
    }

    fn classify(context: *anyopaque, _: patch_tool.PermissionSubject, _: []const u8) anyerror!patch_tool.Decision {
        const self: *InteractivePatchPolicy = @ptrCast(@alignCast(context));
        return switch (self.mode) {
            .ask => .ask,
            .allow => .allow,
            .deny => .deny,
        };
    }

    fn ask(context: *anyopaque, subject: patch_tool.PermissionSubject, patch: []const u8) anyerror!bool {
        const self: *InteractivePatchPolicy = @ptrCast(@alignCast(context));
        var header: [256]u8 = undefined;
        const prompt = try std.fmt.bufPrint(
            &header,
            "apply_patch (operation {x:0>16}/{d}, digest {x:0>16}, workspace {x:0>16}):\n",
            .{
                subject.operation_id,
                subject.operation_generation,
                subject.validation.patch_digest,
                subject.validation.workspace_digest,
            },
        );
        try std.Io.File.stdout().writeStreamingAll(self.io, prompt);
        const escaped = try escapePatch(std.heap.page_allocator, patch);
        defer std.heap.page_allocator.free(escaped);
        try std.Io.File.stdout().writeStreamingAll(self.io, escaped);
        try std.Io.File.stdout().writeStreamingAll(self.io, "Allow? [y/N] ");
        var answer: [8]u8 = undefined;
        const count = try std.Io.File.stdin().readStreaming(self.io, &.{&answer});
        return count > 0 and (answer[0] == 'y' or answer[0] == 'Y');
    }
};

fn escapePatch(allocator: std.mem.Allocator, patch: []const u8) ![]u8 {
    const capacity = try std.math.mul(usize, patch.len, 4);
    const out = try allocator.alloc(u8, capacity);
    errdefer allocator.free(out);
    const hex = "0123456789abcdef";
    var cursor: usize = 0;
    for (patch) |byte| {
        if (byte == '\n') {
            out[cursor] = '\n';
            cursor += 1;
        } else if (byte == '\\') {
            @memcpy(out[cursor..][0..2], "\\\\");
            cursor += 2;
        } else if (byte >= 0x20 and byte <= 0x7e) {
            out[cursor] = byte;
            cursor += 1;
        } else {
            out[cursor] = '\\';
            out[cursor + 1] = 'x';
            out[cursor + 2] = hex[byte >> 4];
            out[cursor + 3] = hex[byte & 0x0f];
            cursor += 4;
        }
    }
    return allocator.realloc(out, cursor);
}

fn resolveWorkspacePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    configured: ?[]const u8,
) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const path = configured orelse return allocator.dupe(u8, cwd);
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn writeFinalAnswer(io: std.Io, completed: *agent.Completed) !void {
    const token = completed.session.ownerToken();
    var reader = try completed.session.openBlob(token, completed.final_ref);
    defer reader.close();
    var window: [output_window_size]u8 = undefined;
    var safe: [output_window_size]u8 = undefined;
    var offset: u64 = 0;
    while (offset < reader.length()) {
        const bytes = try reader.readWindow(offset, &window);
        if (bytes.len == 0) return error.TruncatedFinalAnswer;
        for (bytes, 0..) |byte, index| {
            safe[index] = if ((byte < 0x20 and byte != '\n' and byte != '\t') or byte == 0x7f)
                '?'
            else
                byte;
        }
        try std.Io.File.stdout().writeStreamingAll(io, safe[0..bytes.len]);
        offset += bytes.len;
    }
}

test "CLI arguments distinguish create from exact resume" {
    const create = try parseArguments(&.{
        "onepage",
        "--state",
        "state",
        "--model",
        "fixture:answer",
        "--fixture-response",
        "done",
        "task",
    });
    try std.testing.expectEqualStrings("task", create.task.?);
    const resumed = try parseArguments(&.{
        "onepage",
        "--state",
        "state",
        "--resume",
        "000000000000000a",
    });
    try std.testing.expectEqual(@as(u64, 10), resumed.resume_id.?);

    const patch = try parseArguments(&.{
        "onepage",
        "--fixture-patch",
        "change.patch",
        "--deny-patch",
        "task",
    });
    try std.testing.expectEqualStrings("change.patch", patch.fixture_patch_path.?);
    try std.testing.expect(patch.deny_patch);
    try std.testing.expectError(error.ConflictingPatchPolicy, parseArguments(&.{
        "onepage",
        "--fixture-patch",
        "change.patch",
        "--allow-patch",
        "--deny-patch",
        "task",
    }));
}

test "patch display escapes terminal controls and backslashes losslessly" {
    const escaped = try escapePatch(std.testing.allocator, "safe\n\x1b[2J\\x1b\t\xff");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("safe\n\\x1b[2J\\\\x1b\\x09\\xff", escaped);
}
