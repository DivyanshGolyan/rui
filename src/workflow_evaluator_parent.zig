const std = @import("std");
const protocol = @import("workflow_protocol.zig");

pub const RunResult = struct {
    output: []const u8,
    peak_rss_bytes: ?usize,
};

pub const RunError = error{
    DeadlineExceeded,
    OutputFrameExceeded,
    DiagnosticExceeded,
    AbnormalExit,
} || std.process.SpawnError || std.process.Child.WaitError || std.Io.File.Writer.Error ||
    std.Io.File.Reader.Error || std.Io.Cancelable || std.Io.ConcurrentError || std.posix.KillError;

const ReadResult = struct {
    length: usize,
    overflow: bool,
    read_error: ?std.Io.File.Reader.Error,
};

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    evaluator_path: []const u8,
    input: []const u8,
    output_storage: []u8,
    timeout_milliseconds: u64,
) RunError!RunResult {
    if (input.len > protocol.Limits.input_frame_bytes or
        output_storage.len < protocol.Limits.output_frame_bytes)
    {
        return error.OutputFrameExceeded;
    }

    var empty_environment = std.process.Environ.Map.init(allocator);
    defer empty_environment.deinit();
    var child = try std.process.spawn(io, .{
        .argv = &.{evaluator_path},
        .environ_map = &empty_environment,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .request_resource_usage_statistics = true,
    });
    defer child.kill(io);

    var stdout_future = try io.concurrent(readBounded, .{
        io,
        child.stdout.?,
        output_storage,
    });
    defer _ = stdout_future.cancel(io);
    var diagnostic_storage: [protocol.Limits.diagnostic_bytes]u8 = undefined;
    var stderr_future = try io.concurrent(readBounded, .{
        io,
        child.stderr.?,
        &diagnostic_storage,
    });
    defer _ = stderr_future.cancel(io);
    var timeout_future = try io.concurrent(killAfterTimeout, .{
        io,
        child.id.?,
        timeout_milliseconds,
    });
    defer _ = timeout_future.cancel(io) catch false;

    var input_write_error: ?std.Io.File.Writer.Error = null;
    {
        var writer = child.stdin.?.writer(io, &.{});
        writer.interface.writeAll(input) catch |err| switch (err) {
            error.WriteFailed => input_write_error = writer.err.?,
        };
        child.stdin.?.close(io);
        child.stdin = null;
    }

    const stdout_result = stdout_future.await(io);
    const stderr_result = stderr_future.await(io);
    const term = try child.wait(io);
    const timed_out = timeout_future.cancel(io) catch |err| switch (err) {
        error.Canceled => false,
        else => return err,
    };
    if (stdout_result.read_error) |err| return err;
    if (stderr_result.read_error) |err| return err;
    if (stdout_result.overflow) return error.OutputFrameExceeded;
    if (stderr_result.overflow) return error.DiagnosticExceeded;
    if (timed_out) return error.DeadlineExceeded;
    if (input_write_error) |err| return err;
    switch (term) {
        .exited => |code| if (code != 0) return error.AbnormalExit,
        else => return error.AbnormalExit,
    }
    return .{
        .output = output_storage[0..stdout_result.length],
        .peak_rss_bytes = child.resource_usage_statistics.getMaxRss(),
    };
}

fn readBounded(io: std.Io, file: std.Io.File, storage: []u8) ReadResult {
    var reader_buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    var length: usize = 0;
    var overflow = false;
    var discard: [1024]u8 = undefined;
    while (true) {
        const destination = if (length < storage.len) storage[length..] else &discard;
        const read = reader.interface.readSliceShort(destination) catch |err| switch (err) {
            error.ReadFailed => return .{
                .length = length,
                .overflow = overflow,
                .read_error = reader.err,
            },
        };
        if (read == 0) break;
        if (length < storage.len) {
            length += read;
        } else {
            overflow = true;
        }
    }
    return .{ .length = length, .overflow = overflow, .read_error = null };
}

fn killAfterTimeout(
    io: std.Io,
    child_id: std.process.Child.Id,
    milliseconds: u64,
) (std.Io.Cancelable || std.posix.KillError)!bool {
    try std.Io.sleep(
        io,
        .fromMilliseconds(@intCast(milliseconds)),
        .boot,
    );
    std.posix.kill(child_id, std.posix.SIG.KILL) catch |err| switch (err) {
        error.ProcessNotFound => return true,
        else => return err,
    };
    return true;
}
