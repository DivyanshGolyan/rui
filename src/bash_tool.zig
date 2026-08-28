const std = @import("std");
const binding = @import("binding.zig");

pub const version: u16 = 1;
pub const call_header_size = 16;
pub const descriptor_version: u16 = 1;
pub const descriptor_header_size = 32;
pub const result_header_size = 32;
pub const max_command_size = 2048;
pub const max_workspace_path_size = 1024;
pub const max_descriptor_size = descriptor_header_size + 2 * max_workspace_path_size +
    environment_authority.len + max_command_size;
pub const max_output_size = 64 * 1024;
pub const min_timeout_ms = 100;
pub const max_timeout_ms = 120_000;

const call_magic = "ONEBASH\x00";
const descriptor_magic = "ONEBDSC\x00";
const result_magic = "ONERES\x00\x00";
const environment_path = "/usr/bin:/bin";
const environment_locale = "C";
const environment_sanitized = "1";
pub const environment_authority = "PATH=" ++ environment_path ++ "\x00LC_ALL=" ++
    environment_locale ++ "\x00ONEPAGE_SANITIZED=" ++ environment_sanitized ++ "\x00";

pub const Call = struct {
    command: []const u8,
    timeout_ms: u32,
};

pub const Descriptor = struct {
    operation_id: u64,
    operation_generation: u32,
    workspace_path: []const u8,
    working_directory: []const u8,
    call: Call,
};

pub const Status = enum(u8) {
    success = 1,
    nonzero_exit = 2,
    timeout = 3,
    cancelled = 4,
    missing_executable = 5,
    truncated = 6,
    denied = 7,
    indeterminate = 8,
    spawn_error = 9,
};

pub const Execution = struct {
    allocator: std.mem.Allocator,
    status: Status,
    exit_code: u8 = 0,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *Execution) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

pub const ResultView = struct {
    status: Status,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

pub const ResultHeader = struct {
    status: Status,
    exit_code: u8,
    stdout_length: u32,
    stderr_length: u32,
};

pub const Control = struct {
    cancelled: ?*const std.atomic.Value(bool) = null,
    bash_path: []const u8 = "/bin/bash",
};

pub fn encodeCall(out: []u8, call: Call) ![]const u8 {
    try validate(call);
    const total = call_header_size + call.command.len;
    if (total > out.len) return error.CallBufferTooSmall;
    @memset(out[0..total], 0);
    @memcpy(out[0..call_magic.len], call_magic);
    write(u16, out, 8, version);
    write(u16, out, 10, call_header_size);
    write(u32, out, 12, call.timeout_ms);
    @memcpy(out[call_header_size..total], call.command);
    return out[0..total];
}

pub fn decodeCall(bytes: []const u8) !Call {
    if (bytes.len < call_header_size or bytes.len > call_header_size + max_command_size) {
        return error.InvalidBashCall;
    }
    if (!std.mem.eql(u8, bytes[0..call_magic.len], call_magic) or
        read(u16, bytes, 8) != version or read(u16, bytes, 10) != call_header_size)
    {
        return error.InvalidBashCall;
    }
    const call: Call = .{
        .timeout_ms = read(u32, bytes, 12),
        .command = bytes[call_header_size..],
    };
    try validate(call);
    return call;
}

pub fn encodeDescriptor(out: []u8, descriptor: Descriptor) ![]const u8 {
    try validateDescriptor(descriptor);
    const total = descriptor_header_size + descriptor.workspace_path.len +
        descriptor.working_directory.len + environment_authority.len + descriptor.call.command.len;
    if (total > out.len) return error.DescriptorBufferTooSmall;
    @memset(out[0..total], 0);
    @memcpy(out[0..descriptor_magic.len], descriptor_magic);
    write(u16, out, 8, descriptor_version);
    write(u16, out, 10, descriptor_header_size);
    write(u64, out, 12, descriptor.operation_id);
    write(u32, out, 20, descriptor.operation_generation);
    write(u32, out, 24, descriptor.call.timeout_ms);
    write(u16, out, 28, @intCast(descriptor.workspace_path.len));
    write(u16, out, 30, @intCast(descriptor.working_directory.len));
    var cursor: usize = descriptor_header_size;
    @memcpy(out[cursor..][0..descriptor.workspace_path.len], descriptor.workspace_path);
    cursor += descriptor.workspace_path.len;
    @memcpy(out[cursor..][0..descriptor.working_directory.len], descriptor.working_directory);
    cursor += descriptor.working_directory.len;
    @memcpy(out[cursor..][0..environment_authority.len], environment_authority);
    cursor += environment_authority.len;
    @memcpy(out[cursor..][0..descriptor.call.command.len], descriptor.call.command);
    return out[0..total];
}

pub fn decodeDescriptor(bytes: []const u8) !Descriptor {
    if (bytes.len < descriptor_header_size + environment_authority.len + 1 or
        bytes.len > max_descriptor_size or
        !std.mem.eql(u8, bytes[0..descriptor_magic.len], descriptor_magic) or
        read(u16, bytes, 8) != descriptor_version or
        read(u16, bytes, 10) != descriptor_header_size)
    {
        return error.InvalidBashDescriptor;
    }
    const workspace_length: usize = read(u16, bytes, 28);
    const working_directory_length: usize = read(u16, bytes, 30);
    const authority_offset = descriptor_header_size + workspace_length + working_directory_length;
    const command_offset = authority_offset + environment_authority.len;
    if (workspace_length == 0 or workspace_length > max_workspace_path_size or
        working_directory_length == 0 or working_directory_length > max_workspace_path_size or
        command_offset >= bytes.len or
        !std.mem.eql(u8, bytes[authority_offset..command_offset], environment_authority))
    {
        return error.InvalidBashDescriptor;
    }
    const descriptor: Descriptor = .{
        .operation_id = read(u64, bytes, 12),
        .operation_generation = read(u32, bytes, 20),
        .workspace_path = bytes[descriptor_header_size..][0..workspace_length],
        .working_directory = bytes[descriptor_header_size + workspace_length .. authority_offset],
        .call = .{
            .timeout_ms = read(u32, bytes, 24),
            .command = bytes[command_offset..],
        },
    };
    try validateDescriptor(descriptor);
    var canonical: [max_descriptor_size]u8 = undefined;
    const encoded = try encodeDescriptor(&canonical, descriptor);
    if (!std.mem.eql(u8, encoded, bytes)) return error.InvalidBashDescriptor;
    return descriptor;
}

pub fn descriptorDigest(bytes: []const u8) binding.BashDescriptor {
    return binding.hash(binding.BashDescriptor, bytes);
}

pub fn executeDescriptor(
    allocator: std.mem.Allocator,
    io: std.Io,
    descriptor: Descriptor,
    control: Control,
) !Execution {
    try validateDescriptor(descriptor);
    return executeControlled(allocator, io, descriptor.working_directory, descriptor.call, control);
}

pub fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    call: Call,
) !Execution {
    return executeControlled(allocator, io, workspace_path, call, .{});
}

pub fn executeControlled(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    call: Call,
    control: Control,
) !Execution {
    try validate(call);
    if (control.cancelled) |cancelled| {
        if (cancelled.load(.acquire)) return emptyExecution(allocator, .cancelled);
    }
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", environment_path);
    try environment.put("LC_ALL", environment_locale);
    try environment.put("ONEPAGE_SANITIZED", environment_sanitized);

    const run = runBounded(allocator, io, .{
        .argv = &.{ control.bash_path, "--noprofile", "--norc", "-c", call.command },
        .cwd = .{ .path = workspace_path },
        .environ_map = &environment,
        .timeout_ms = call.timeout_ms,
        .cancelled = control.cancelled,
    }) catch |err| switch (err) {
        error.FileNotFound => return emptyExecution(allocator, .missing_executable),
        else => return emptyExecution(allocator, .spawn_error),
    };
    const status: Status, const exit_code: u8 = switch (run.termination) {
        .timeout => .{ .timeout, 0 },
        .cancelled => .{ .cancelled, 0 },
        .truncated => .{ .truncated, 0 },
        .term => |term| switch (term) {
            .exited => |code| .{ if (code == 0) .success else .nonzero_exit, code },
            else => .{ .nonzero_exit, 255 },
        },
    };
    return .{
        .allocator = allocator,
        .status = status,
        .exit_code = exit_code,
        .stdout = run.stdout,
        .stderr = run.stderr,
    };
}

const RunOptions = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    environ_map: *const std.process.Environ.Map,
    timeout_ms: u32,
    cancelled: ?*const std.atomic.Value(bool),
};

const Termination = union(enum) {
    term: std.process.Child.Term,
    timeout,
    cancelled,
    truncated,
};

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    termination: Termination,
};

fn runBounded(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RunOptions,
) !RunResult {
    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    const process_group = child.id.?;
    var child_live = true;
    defer if (child_live) terminateGroup(&child, io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(
        allocator,
        io,
        multi_reader_buffer.toStreams(),
        &.{ child.stdout.?, child.stderr.? },
    );
    defer multi_reader.deinit();
    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const clock = std.Io.Clock.awake;
    const duration: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromMilliseconds(options.timeout_ms),
        .clock = clock,
    };
    const deadline = std.Io.Clock.Timestamp.now(io, clock).addDuration(duration);
    const poll: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(10),
        .clock = clock,
    } };
    var termination: ?Termination = null;
    var pipes_eof = false;
    while (termination == null) {
        if (options.cancelled) |cancelled| {
            if (cancelled.load(.acquire)) {
                termination = .cancelled;
                break;
            }
        }
        multi_reader.fill(4096, poll) catch |err| switch (err) {
            error.EndOfStream => {
                pipes_eof = true;
                break;
            },
            error.Timeout => {
                const now = std.Io.Clock.Timestamp.now(io, clock);
                if (!now.compare(.lt, deadline)) termination = .timeout;
                continue;
            },
            error.Canceled => {
                termination = .cancelled;
                break;
            },
            else => return err,
        };
        if (stdout_reader.buffered().len > max_output_size or
            stderr_reader.buffered().len > max_output_size)
        {
            termination = .truncated;
        }
    }
    if (termination) |_| {
        terminateGroup(&child, io);
        child_live = false;
    } else {
        std.debug.assert(pipes_eof);
        var wait_done: std.atomic.Value(bool) = .init(false);
        var wait_future = io.async(waitChild, .{ &child, io, &wait_done });
        while (!wait_done.load(.acquire)) {
            if (options.cancelled) |cancelled| {
                if (cancelled.load(.acquire)) {
                    termination = .cancelled;
                    break;
                }
            }
            const now = std.Io.Clock.Timestamp.now(io, clock);
            if (!now.compare(.lt, deadline)) {
                termination = .timeout;
                break;
            }
            try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), clock);
        }
        if (termination != null) std.posix.kill(-process_group, .KILL) catch {};
        const term = try wait_future.await(io);
        child_live = false;
        if (termination == null) termination = .{ .term = term };
    }
    var stdout = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    if (stdout.len > max_output_size) stdout = try allocator.realloc(stdout, max_output_size);
    var stderr = try multi_reader.toOwnedSlice(1);
    errdefer allocator.free(stderr);
    if (stderr.len > max_output_size) stderr = try allocator.realloc(stderr, max_output_size);
    return .{ .stdout = stdout, .stderr = stderr, .termination = termination.? };
}

fn waitChild(
    child: *std.process.Child,
    io: std.Io,
    done: *std.atomic.Value(bool),
) !std.process.Child.Term {
    defer done.store(true, .release);
    return child.wait(io);
}

fn terminateGroup(child: *std.process.Child, io: std.Io) void {
    const pid = child.id orelse return;
    std.posix.kill(-pid, .KILL) catch {};
    child.kill(io);
}

pub fn encodeResult(out: []u8, execution: Execution) ![]const u8 {
    const total = result_header_size + execution.stdout.len + execution.stderr.len;
    if (total > out.len) return error.ResultBufferTooSmall;
    _ = try encodeResultHeader(out[0..result_header_size], execution);
    const stdout_end = result_header_size + execution.stdout.len;
    @memcpy(out[result_header_size..stdout_end], execution.stdout);
    @memcpy(out[stdout_end..total], execution.stderr);
    return out[0..total];
}

pub fn encodeResultHeader(out: []u8, execution: Execution) ![]const u8 {
    if (out.len < result_header_size or execution.stdout.len > max_output_size or
        execution.stderr.len > max_output_size)
    {
        return error.InvalidBashResult;
    }
    @memset(out[0..result_header_size], 0);
    @memcpy(out[0..result_magic.len], result_magic);
    write(u16, out, 8, version);
    write(u16, out, 10, result_header_size);
    out[12] = @intFromEnum(execution.status);
    out[13] = execution.exit_code;
    write(u32, out, 16, @intCast(execution.stdout.len));
    write(u32, out, 20, @intCast(execution.stderr.len));
    return out[0..result_header_size];
}

pub fn decodeResult(bytes: []const u8) !ResultView {
    const header = try decodeResultHeader(bytes, bytes.len);
    return .{
        .status = header.status,
        .exit_code = header.exit_code,
        .stdout = bytes[result_header_size..][0..header.stdout_length],
        .stderr = bytes[result_header_size + header.stdout_length ..],
    };
}

pub fn decodeResultHeader(bytes: []const u8, total_length: u64) !ResultHeader {
    if (bytes.len < result_header_size or
        !std.mem.eql(u8, bytes[0..result_magic.len], result_magic) or
        read(u16, bytes, 8) != version or read(u16, bytes, 10) != result_header_size or
        bytes[14] != 0 or bytes[15] != 0 or read(u64, bytes, 24) != 0)
    {
        return error.InvalidBashResult;
    }
    const status: Status = switch (bytes[12]) {
        1 => .success,
        2 => .nonzero_exit,
        3 => .timeout,
        4 => .cancelled,
        5 => .missing_executable,
        6 => .truncated,
        7 => .denied,
        8 => .indeterminate,
        9 => .spawn_error,
        else => return error.InvalidBashResult,
    };
    const header: ResultHeader = .{
        .status = status,
        .exit_code = bytes[13],
        .stdout_length = read(u32, bytes, 16),
        .stderr_length = read(u32, bytes, 20),
    };
    if (result_header_size + @as(u64, header.stdout_length) + header.stderr_length != total_length) {
        return error.InvalidBashResult;
    }
    return header;
}

fn emptyExecution(allocator: std.mem.Allocator, status: Status) !Execution {
    return .{
        .allocator = allocator,
        .status = status,
        .stdout = try allocator.alloc(u8, 0),
        .stderr = try allocator.alloc(u8, 0),
    };
}

fn validate(call: Call) !void {
    if (call.command.len == 0 or call.command.len > max_command_size or
        call.timeout_ms < min_timeout_ms or call.timeout_ms > max_timeout_ms or
        std.mem.indexOfScalar(u8, call.command, 0) != null or !std.unicode.utf8ValidateSlice(call.command))
    {
        return error.InvalidBashCall;
    }
}

fn validateDescriptor(descriptor: Descriptor) !void {
    try validate(descriptor.call);
    if (descriptor.operation_id == 0 or descriptor.operation_generation == 0 or
        descriptor.workspace_path.len == 0 or
        descriptor.workspace_path.len > max_workspace_path_size or
        descriptor.working_directory.len == 0 or
        descriptor.working_directory.len > max_workspace_path_size or
        descriptor.workspace_path[0] != '/' or descriptor.working_directory[0] != '/' or
        !std.mem.eql(u8, descriptor.workspace_path, descriptor.working_directory) or
        std.mem.indexOfScalar(u8, descriptor.workspace_path, 0) != null or
        std.mem.indexOfScalar(u8, descriptor.working_directory, 0) != null)
    {
        return error.InvalidBashDescriptor;
    }
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

test "bash call is canonical, bounded, and digest bound" {
    var buffer: [call_header_size + max_command_size]u8 = undefined;
    const encoded = try encodeCall(&buffer, .{ .command = "git status --short", .timeout_ms = 5000 });
    const decoded = try decodeCall(encoded);
    try std.testing.expectEqualStrings("git status --short", decoded.command);
    try std.testing.expectEqual(@as(u32, 5000), decoded.timeout_ms);
    try std.testing.expectEqual(@as(usize, 32), descriptorDigest(encoded).bytes.len);
    try std.testing.expectError(error.InvalidBashCall, decodeCall("not a call"));
}

test "Bash descriptor binds complete execution authority canonically" {
    const expected: Descriptor = .{
        .operation_id = 17,
        .operation_generation = 3,
        .workspace_path = "/work/onepage",
        .working_directory = "/work/onepage",
        .call = .{ .command = "git status --short", .timeout_ms = 5000 },
    };
    var bytes: [max_descriptor_size]u8 = undefined;
    const encoded = try encodeDescriptor(&bytes, expected);
    const decoded = try decodeDescriptor(encoded);
    try std.testing.expectEqualDeep(expected, decoded);
    const expected_digest = descriptorDigest(encoded);
    const environment_offset = descriptor_header_size + expected.workspace_path.len +
        expected.working_directory.len;
    bytes[environment_offset] ^= 1;
    try std.testing.expectError(error.InvalidBashDescriptor, decodeDescriptor(encoded));
    bytes[environment_offset] ^= 1;

    const mismatches = [_]Descriptor{
        .{ .operation_id = 19, .operation_generation = 3, .workspace_path = "/work/onepage", .working_directory = "/work/onepage", .call = expected.call },
        .{ .operation_id = 17, .operation_generation = 4, .workspace_path = "/work/onepage", .working_directory = "/work/onepage", .call = expected.call },
        .{ .operation_id = 17, .operation_generation = 3, .workspace_path = "/work/other", .working_directory = "/work/other", .call = expected.call },
        .{ .operation_id = 17, .operation_generation = 3, .workspace_path = "/work/onepage", .working_directory = "/work/onepage", .call = .{ .command = expected.call.command, .timeout_ms = 6000 } },
        .{ .operation_id = 17, .operation_generation = 3, .workspace_path = "/work/onepage", .working_directory = "/work/onepage", .call = .{ .command = "git diff", .timeout_ms = 5000 } },
    };
    for (mismatches) |mismatch| {
        const mismatch_bytes = try encodeDescriptor(&bytes, mismatch);
        try std.testing.expect(!binding.eql(
            binding.BashDescriptor,
            expected_digest,
            descriptorDigest(mismatch_bytes),
        ));
    }
}

test "bash runs in its workspace with a sanitized environment" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var result = try execute(
        allocator,
        io,
        path,
        .{ .command = "pwd; test -z \"$OPENAI_API_KEY\"; printf %s \"$ONEPAGE_SANITIZED\"", .timeout_ms = 5000 },
    );
    defer result.deinit();
    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expect(std.mem.endsWith(u8, result.stdout, "1"));
}

test "bash distinguishes nonzero, missing Bash, and timeout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const cases = [_]struct { command: []const u8, timeout: u32, expected: Status }{
        .{ .command = "exit 9", .timeout = 5000, .expected = .nonzero_exit },
        .{ .command = "sleep 2", .timeout = 100, .expected = .timeout },
    };
    for (cases) |case| {
        var result = try execute(allocator, io, path, .{ .command = case.command, .timeout_ms = case.timeout });
        defer result.deinit();
        try std.testing.expectEqual(case.expected, result.status);
    }
    var exit_127 = try execute(allocator, io, path, .{ .command = "exit 127", .timeout_ms = 5000 });
    defer exit_127.deinit();
    try std.testing.expectEqual(Status.nonzero_exit, exit_127.status);
    var missing = try executeControlled(
        allocator,
        io,
        path,
        .{ .command = "true", .timeout_ms = 5000 },
        .{ .bash_path = "/onepage/missing/bash" },
    );
    defer missing.deinit();
    try std.testing.expectEqual(Status.missing_executable, missing.status);
}

test "truncation and cancellation are distinct typed results" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var truncated = try execute(
        allocator,
        io,
        path,
        .{ .command = "head -c 70000 /dev/zero", .timeout_ms = 5000 },
    );
    defer truncated.deinit();
    try std.testing.expectEqual(Status.truncated, truncated.status);
    const encoded_buffer = try allocator.alloc(u8, result_header_size + 2 * max_output_size);
    defer allocator.free(encoded_buffer);
    _ = try encodeResult(encoded_buffer, truncated);

    var cancellation: std.atomic.Value(bool) = .init(false);
    var cancel_future = io.async(cancelAfter, .{ io, &cancellation });
    var cancelled = try executeControlled(
        allocator,
        io,
        path,
        .{ .command = "sleep 2", .timeout_ms = 5000 },
        .{ .cancelled = &cancellation },
    );
    defer cancelled.deinit();
    try cancel_future.await(io);
    try std.testing.expectEqual(Status.cancelled, cancelled.status);
}

fn cancelAfter(io: std.Io, cancellation: *std.atomic.Value(bool)) !void {
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    cancellation.store(true, .release);
}

test "timeout kills Bash descendants and Bash syntax is supported" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var timeout = try execute(
        allocator,
        io,
        path,
        .{ .command = "(sleep 1; printf late > late.txt) & wait", .timeout_ms = 100 },
    );
    defer timeout.deinit();
    try std.testing.expectEqual(Status.timeout, timeout.status);
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1100), .awake);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "late.txt", .{}));

    var bash_only = try execute(
        allocator,
        io,
        path,
        .{ .command = "[[ -n onepage ]]", .timeout_ms = 5000 },
    );
    defer bash_only.deinit();
    try std.testing.expectEqual(Status.success, bash_only.status);
}

test "timeout still applies after Bash closes its output pipes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var result = try execute(
        allocator,
        io,
        path,
        .{ .command = "exec >/dev/null 2>&1; sleep 1; printf late > late-after-eof.txt", .timeout_ms = 100 },
    );
    defer result.deinit();
    try std.testing.expectEqual(Status.timeout, result.status);
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1100), .awake);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "late-after-eof.txt", .{}));
}
