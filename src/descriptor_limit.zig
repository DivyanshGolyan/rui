const std = @import("std");
const builtin = @import("builtin");
const native = @cImport({
    @cInclude("sys/resource.h");
});

pub const Observation = struct {
    open_descriptors: usize,
    soft_limit: ?usize,
};

pub fn convertQuery(result: c_int, current: u128, infinity: u128) !?usize {
    if (result != 0) return error.DescriptorLimitQueryFailed;
    if (current == infinity) return null;
    if (current > std.math.maxInt(usize)) return error.InvalidDescriptorLimit;
    return @intCast(current);
}

/// Observe the inherited population and RLIMIT_NOFILE before Rui creates any
/// Host descriptor owner. The temporary enumeration directory is excluded.
pub fn observe(io: std.Io) !Observation {
    const directory_path = switch (builtin.os.tag) {
        .linux => "/proc/self/fd",
        .macos => "/dev/fd",
        else => return error.UnsupportedDescriptorPlatform,
    };
    var limit = std.mem.zeroes(native.struct_rlimit);
    const soft_limit = try convertQuery(
        native.getrlimit(native.RLIMIT_NOFILE, &limit),
        @intCast(limit.rlim_cur),
        @intCast(native.RLIM_INFINITY),
    );
    return .{
        .open_descriptors = try countOpenDescriptors(io, directory_path, soft_limit),
        .soft_limit = soft_limit,
    };
}

fn countOpenDescriptors(io: std.Io, directory_path: []const u8, soft_limit: ?usize) !usize {
    var descriptors = std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true }) catch |err| {
        if (builtin.os.tag == .linux) {
            if (soft_limit) |finite_limit| return countFiniteLimit(finite_limit);
        }
        return err;
    };
    defer descriptors.close(io);
    var count: usize = 0;
    var iterator = descriptors.iterate();
    while (try iterator.next(io)) |entry| {
        const descriptor = std.fmt.parseInt(std.posix.fd_t, entry.name, 10) catch continue;
        if (descriptor != descriptors.handle) count = try std.math.add(usize, count, 1);
    }
    return count;
}

fn countFiniteLimit(limit: usize) !usize {
    const fd_max: usize = @intCast(std.math.maxInt(std.posix.fd_t));
    const end = @min(limit, try std.math.add(usize, fd_max, 1));
    var count: usize = 0;
    for (0..end) |raw_fd| {
        const fd: std.posix.fd_t = @intCast(raw_fd);
        while (true) {
            const result = std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(usize, 0));
            switch (std.posix.errno(result)) {
                .SUCCESS => {
                    count = try std.math.add(usize, count, 1);
                    break;
                },
                .BADF => break,
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }
    return count;
}

test "native limit conversion preserves finite and unlimited results" {
    try std.testing.expectEqual(@as(?usize, 256), try convertQuery(0, 256, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(?usize, null), try convertQuery(0, std.math.maxInt(u64), std.math.maxInt(u64)));
}

test "native limit conversion rejects invalid queries and values" {
    try std.testing.expectError(error.DescriptorLimitQueryFailed, convertQuery(-1, 0, std.math.maxInt(u64)));
    if (@sizeOf(usize) < @sizeOf(u128)) {
        try std.testing.expectError(
            error.InvalidDescriptorLimit,
            convertQuery(0, @as(u128, std.math.maxInt(usize)) + 1, std.math.maxInt(u128)),
        );
    }
}

test "finite-limit scan observes the test process without procfs" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const observation = try observe(std.testing.io);
    if (observation.soft_limit) |limit| {
        try std.testing.expectEqual(
            observation.open_descriptors,
            try countOpenDescriptors(std.testing.io, "/rui-test-missing-procfs", limit),
        );
    }
}
