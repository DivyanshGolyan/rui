const std = @import("std");
const harness = @import("harness.zig");
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
    dangerously_bypass_permissions: bool = false,
    task: ?[]const u8 = null,
    resume_id: ?u64 = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    var host: harness.Host = .{};
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
    if (arguments.resume_id) |session_id| {
        var owner = try harness.Harness.open(.{
            .host = &host,
            .sessions = sessions,
            .io = init.io,
            .allocator = allocator,
            .permission_mode = if (arguments.dangerously_bypass_permissions) .bypass else .ask,
            .mode = .{ .restore = .{ .session_id = session_id } },
        });
        defer owner.close();
        const identified = try owner.drive();
        try renderProgress(init.io, &identified);
        try pumpOwner(init.io, &owner);
        return;
    }
    {
        const model = arguments.model orelse return error.MissingModel;
        if (!std.mem.startsWith(u8, model, "fixture:")) return error.UnsupportedModel;
        const response = arguments.fixture_response orelse return error.MissingFixtureResponse;
        const task = arguments.task orelse return error.MissingTask;
        const workspace_path = try resolveWorkspacePath(init.io, allocator, arguments.repo_path);
        defer allocator.free(workspace_path);
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
            try runCreate(init.io, allocator, &host, sessions, arguments.dangerously_bypass_permissions, .{
                .workspace_path = workspace_path,
                .model = model,
                .task = task,
                .provider = fixture.provider(),
            });
            return;
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
            try runCreate(init.io, allocator, &host, sessions, arguments.dangerously_bypass_permissions, .{
                .workspace_path = workspace_path,
                .model = model,
                .task = task,
                .provider = fixture.provider(),
            });
            return;
        }
        var fixture: model_operation.Fixture = .{
            .expected_task = task,
            .final_answer = response,
        };
        try runCreate(init.io, allocator, &host, sessions, arguments.dangerously_bypass_permissions, .{
            .workspace_path = workspace_path,
            .model = model,
            .task = task,
            .provider = fixture.provider(),
        });
    }
}

fn runCreate(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: *harness.Host,
    sessions: std.Io.Dir,
    bypass_permissions: bool,
    create: harness.Create,
) !void {
    var owner = try harness.Harness.open(.{
        .host = host,
        .sessions = sessions,
        .io = io,
        .allocator = allocator,
        .permission_mode = if (bypass_permissions) .bypass else .ask,
        .mode = .{ .create = create },
    });
    defer owner.close();
    const identified = try owner.drive();
    try renderProgress(io, &identified);
    if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
    try pumpOwner(io, &owner);
}

fn pumpOwner(io: std.Io, owner: *harness.Harness) !void {
    const recovery_drives = (harness.max_recovery_records +
        harness.default_recovery_quantum - 1) / harness.default_recovery_quantum;
    for (0..recovery_drives + 8) |_| {
        const progress = try owner.drive();
        try renderProgress(io, &progress);
        if (approvalProjection(&progress)) |approval| {
            const allow = try promptPermission(io, approval);
            if (owner.offer(.{ .permission = .{
                .operation_id = approval.operation_id,
                .operation_generation = approval.operation_generation,
                .descriptor_digest = approval.descriptor_digest,
                .allow = allow,
            } }) != .accepted) return error.PermissionOfferRejected;
            continue;
        }
        switch (progress.state) {
            .finished, .cancelled, .closed => return,
            .failed, .unavailable => return error.SessionFailed,
            else => {},
        }
        if (progress.consumed == 0 and progress.committed == 0 and
            progress.dispatched == 0 and !progress.more)
        {
            return;
        }
    }
    return error.DriveQuantumExceeded;
}

fn renderProgress(io: std.Io, progress: *const harness.Progress) !void {
    for (progress.projectionSlice()) |projection| switch (projection.kind) {
        .session => {
            var id_buffer: [16]u8 = undefined;
            const id = try session_store.formatId(projection.session_id, &id_buffer);
            var line_buffer: [32]u8 = undefined;
            const line = try std.fmt.bufPrint(&line_buffer, "Session: {s}\n", .{id});
            try std.Io.File.stdout().writeStreamingAll(io, line);
        },
        .final_answer => {
            try std.Io.File.stdout().writeStreamingAll(io, "Final Answer:\n");
            try writeFinalAnswer(io, projection);
            try std.Io.File.stdout().writeStreamingAll(io, "\n");
        },
        .approval_required => try std.Io.File.stdout().writeStreamingAll(
            io,
            "Approval required. Resume in ask mode to decide the exact Action.\n",
        ),
        .indeterminate => try std.Io.File.stdout().writeStreamingAll(
            io,
            "The Bash Attempt may have executed and will not be replayed.\n",
        ),
        .cancelled => try std.Io.File.stdout().writeStreamingAll(io, "Cancelled.\n"),
        .failure => try std.Io.File.stdout().writeStreamingAll(io, "Session failed.\n"),
        .task_admitted, .outcome, .closed => {},
    };
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
        } else if (std.mem.eql(u8, argument, "--dangerously-bypass-permissions")) {
            parsed.dangerously_bypass_permissions = true;
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
            parsed.repo_path != null or parsed.fixture_bash_command != null or
            parsed.fixture_patch_path != null))
    {
        return error.ResumeArgumentsConflict;
    }
    return parsed;
}

fn approvalProjection(progress: *const harness.Progress) ?harness.Projection {
    for (progress.projectionSlice()) |projection| {
        if (projection.kind == .approval_required) return projection;
    }
    return null;
}

fn promptPermission(io: std.Io, approval: harness.Projection) !bool {
    var header: [192]u8 = undefined;
    const prompt = try std.fmt.bufPrint(
        &header,
        "Action (operation {x:0>16}/{d}, digest {x:0>16}):\n",
        .{ approval.operation_id, approval.operation_generation, approval.descriptor_digest },
    );
    try std.Io.File.stdout().writeStreamingAll(io, prompt);
    var reader = try approval.openContent();
    defer reader.close();
    var window: [output_window_size]u8 = undefined;
    var offset: u64 = 0;
    while (offset < reader.length()) {
        const bytes = try reader.readWindow(offset, &window);
        if (bytes.len == 0) return error.TruncatedActionDescriptor;
        const escaped = try escapePatch(std.heap.page_allocator, bytes);
        defer std.heap.page_allocator.free(escaped);
        try std.Io.File.stdout().writeStreamingAll(io, escaped);
        offset += bytes.len;
    }
    try std.Io.File.stdout().writeStreamingAll(io, "\nAllow? [y/N] ");
    var answer: [8]u8 = undefined;
    const count = try std.Io.File.stdin().readStreaming(io, &.{&answer});
    return count > 0 and (answer[0] == 'y' or answer[0] == 'Y');
}

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

fn writeFinalAnswer(io: std.Io, projection: harness.Projection) !void {
    var reader = try projection.openContent();
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
        "--dangerously-bypass-permissions",
        "task",
    });
    try std.testing.expectEqualStrings("change.patch", patch.fixture_patch_path.?);
    try std.testing.expect(patch.dangerously_bypass_permissions);
}

test "patch display escapes terminal controls and backslashes losslessly" {
    const escaped = try escapePatch(std.testing.allocator, "safe\n\x1b[2J\\x1b\t\xff");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("safe\n\\x1b[2J\\\\x1b\\x09\\xff", escaped);
}
