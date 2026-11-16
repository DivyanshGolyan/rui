//! Alternate signal stacks in fresh anonymous pages. Zig's segfault handler
//! always asks for the alternate stack, so a stack overflow can still print a
//! trace. A signal stack's pages become resident only if a signal uses them.
//! Zig's own `signal_stack_size` would keep one in static TLS, which glibc
//! zeroes for every thread, so `cli.zig` disables that and threads use these.
const std = @import("std");

const size: usize = if (std.options.enable_segfault_handler) 1 << 18 else 0;

const Stack = []align(std.heap.page_size_min) u8;

pub fn attachMain() std.posix.MMapError!void {
    install(try map());
}

pub fn spawn(config: std.Thread.SpawnConfig, comptime function: anytype, args: anytype) std.Thread.SpawnError!std.Thread {
    const Args = @TypeOf(args);
    const Entry = struct {
        fn run(stack: Stack, entry_args: Args) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
            install(stack);
            defer release(stack);
            return @call(.auto, function, entry_args);
        }
    };
    const stack = map() catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.LockedMemoryLimitExceeded => error.LockedMemoryLimitExceeded,
        else => error.Unexpected,
    };
    errdefer if (stack.len != 0) std.posix.munmap(stack);
    return std.Thread.spawn(config, Entry.run, .{ stack, args });
}

fn map() std.posix.MMapError!Stack {
    if (size == 0) return &.{};
    return std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
}

noinline fn install(stack: Stack) void {
    if (stack.len == 0) return;
    std.posix.sigaltstack(&.{ .sp = stack.ptr, .flags = 0, .size = @intCast(stack.len) }, null) catch |err|
        std.debug.panic("sigaltstack install failed: {t} (size {d})", .{ err, stack.len });
}

fn release(stack: Stack) void {
    if (stack.len == 0) return;
    std.posix.sigaltstack(&.{ .sp = stack.ptr, .flags = std.c.SS.DISABLE, .size = @intCast(stack.len) }, null) catch |err|
        std.debug.panic("sigaltstack release failed: {t} (size {d})", .{ err, stack.len });
    std.posix.munmap(stack);
}
