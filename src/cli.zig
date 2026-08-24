const std = @import("std");
const agent = @import("agent.zig");
const core_contract = @import("core_contract.zig");
const model_operation = @import("model_operation.zig");
const session_store = @import("session.zig");

const max_core_size = 1024 * 1024;
const output_window_size = 4096;

const Arguments = struct {
    core_path: ?[]const u8 = null,
    state_path: ?[]const u8 = null,
    repo_path: ?[]const u8 = null,
    model: ?[]const u8 = null,
    fixture_response: ?[]const u8 = null,
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
    const raw_args = try init.minimal.args.toSlice(allocator);
    const arguments = try parseArguments(raw_args);
    const core_path = try resolveCorePath(init.io, allocator, arguments.core_path);
    defer allocator.free(core_path);
    const wasm = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        core_path,
        allocator,
        .limited(max_core_size),
    );
    defer allocator.free(wasm);
    try core_contract.verify(wasm);

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
        try agent.resumeSession(sessions, init.io, allocator, wasm, session_id)
    else blk: {
        const model = arguments.model orelse return error.MissingModel;
        if (!std.mem.startsWith(u8, model, "fixture:")) return error.UnsupportedModel;
        const response = arguments.fixture_response orelse return error.MissingFixtureResponse;
        const task = arguments.task orelse return error.MissingTask;
        const workspace_path = try resolveWorkspacePath(init.io, allocator, arguments.repo_path);
        defer allocator.free(workspace_path);
        var fixture: model_operation.Fixture = .{
            .expected_task = task,
            .final_answer = response,
        };
        var output: Output = .{ .io = init.io };
        break :blk try agent.runNew(
            sessions,
            init.io,
            allocator,
            wasm,
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
        if (std.mem.eql(u8, argument, "--core")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            parsed.core_path = args[index];
        } else if (std.mem.eql(u8, argument, "--state")) {
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
            parsed.repo_path != null))
    {
        return error.ResumeArgumentsConflict;
    }
    return parsed;
}

fn resolveCorePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    configured: ?[]const u8,
) ![]u8 {
    if (configured) |path| return allocator.dupe(u8, path);
    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);
    const directory = std.fs.path.dirname(executable) orelse return error.InvalidExecutablePath;
    return std.fs.path.join(allocator, &.{ directory, "onepage-core.wasm" });
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
        "--core",
        "core.wasm",
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
        "--core",
        "core.wasm",
        "--state",
        "state",
        "--resume",
        "000000000000000a",
    });
    try std.testing.expectEqual(@as(u64, 10), resumed.resume_id.?);
}
