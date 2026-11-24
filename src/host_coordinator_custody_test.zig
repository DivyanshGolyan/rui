const std = @import("std");
const coordinator = @import("host_coordinator.zig");
const restart_all = @import("host_restart_all.zig");
const report = @import("host_restart_report.zig");
const process = @import("os/process.zig");

const c = std.c;
var effect_fd: c_int = -1;
var release_fd: c_int = -1;
extern "c" fn getsid(c_int) c_int;

// The barrier stands where the Store's activation runs: it signals that the worker is
// detached, waits for the test's go, then reports a ready Host.
fn activate(init: std.process.Init, allocator: std.mem.Allocator, options: restart_all.Options) anyerror!report.Batch {
    _ = init;
    const directory = switch (options.scope) {
        .store => |store| store,
        .all => return error.BadFixtureScope,
    };
    if (!std.mem.eql(u8, directory, "/scratch/store")) return error.BadFixtureDirectory;
    if (getsid(0) != c.getpid()) return error.WorkerNotDetached;
    if (c.write(effect_fd, "S", 1) != 1) return error.FixturePipe;
    var token: [1]u8 = undefined;
    if (c.read(release_fd, &token, 1) != 1 or token[0] != 'G') return error.FixturePipe;
    if (c.write(effect_fd, "R", 1) != 1) return error.FixturePipe;
    const entries = try allocator.alloc(report.Entry, 1);
    entries[0] = .{ .directory = try allocator.dupe(u8, directory), .state = .{ .outcome = .{ .ready = .{ .instance = @splat(7), .pid = 321 } } } };
    return .{ .entries = entries };
}

fn pipe() ![2]c_int {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.FixturePipe;
    return fds;
}
fn close(fd: c_int) void {
    _ = c.close(fd);
}
fn readByte(fd: c_int) !u8 {
    var pollfd: std.posix.pollfd = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
    if (c.poll(@ptrCast(&pollfd), 1, 10000) <= 0) return error.FixtureTimeout;
    var byte: [1]u8 = undefined;
    if (c.read(fd, &byte, 1) != 1) return error.FixturePipe;
    return byte[0];
}

// SH-131 uses real process groups and pipes; the injected activation stops at a controlled barrier.
test "SH-131 detached start coordinator retains custody after caller departure" {
    const task = "{\"home\":\"/scratch\",\"scope\":{\"store\":\"/scratch/store\"},\"report\":\"events\"}";
    for ([_]enum { independent, host_owned, caller_departs, closed_reply, incomplete }{ .independent, .host_owned, .caller_departs, .closed_reply, .incomplete }) |scenario| {
        const input = try pipe();
        const output = try pipe();
        const effects = try pipe();
        const release = try pipe();
        const caller = c.fork();
        if (caller < 0) return error.FixtureFork;
        if (caller == 0) {
            if (c.setsid() < 0) c._exit(91);
            const worker = c.fork();
            if (worker < 0) c._exit(92);
            if (worker == 0) {
                close(input[1]);
                close(output[0]);
                close(effects[0]);
                close(release[1]);
                if (c.dup2(input[0], 0) < 0 or c.dup2(output[1], 1) < 0) c._exit(93);
                close(input[0]);
                close(output[1]);
                effect_fd = effects[1];
                release_fd = release[0];
                var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
                var env: std.process.Environ.Map = .init(std.heap.page_allocator);
                const init: std.process.Init = .{ .minimal = .{ .args = .{ .vector = &.{} }, .environ = .empty }, .arena = &arena, .gpa = std.heap.page_allocator, .io = std.Io.Threaded.global_single_threaded.io(), .environ_map = &env, .preopens = .empty };
                coordinator.runWith(init, std.heap.page_allocator, activate) catch c._exit(94);
                c._exit(0);
            }
            close(input[0]);
            close(input[1]);
            close(output[0]);
            close(output[1]);
            close(effects[0]);
            close(effects[1]);
            close(release[0]);
            close(release[1]);
            var status: c_int = 0;
            _ = c.waitpid(worker, &status, 0);
            c._exit(if (status == 0) 0 else 95);
        }
        close(input[0]);
        close(output[1]);
        close(effects[1]);
        close(release[0]);
        var reply_open = true;
        defer if (reply_open) close(output[0]);
        defer close(effects[0]);
        defer close(release[1]);
        const sent = if (scenario == .incomplete) task[0 .. task.len - 1] else task;
        try std.testing.expectEqual(@as(isize, @intCast(sent.len)), c.write(input[1], sent.ptr, sent.len));
        close(input[1]);
        if (scenario == .incomplete) {
            var status: c_int = 0;
            _ = c.waitpid(caller, &status, 0);
            var b: [1]u8 = undefined;
            try std.testing.expectEqual(@as(isize, 0), c.read(effects[0], &b, 1));
            continue;
        }
        try std.testing.expectEqual(@as(u8, 'S'), try readByte(effects[0]));
        if (scenario == .host_owned or scenario == .caller_departs) {
            try std.testing.expectEqual(process.GroupSignal.sent, process.signalGroup(caller, .TERM));
        }
        if (scenario == .closed_reply or scenario == .caller_departs) {
            close(output[0]);
            reply_open = false;
        }
        try std.testing.expectEqual(@as(isize, 1), c.write(release[1], "G", 1));
        try std.testing.expectEqual(@as(u8, 'R'), try readByte(effects[0]));
        if (reply_open) {
            var reply: [4096]u8 = undefined;
            const count = c.read(output[0], &reply, reply.len);
            try std.testing.expect(count > 0);
            try std.testing.expect(std.mem.indexOf(u8, reply[0..@intCast(count)], "\"ready\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, reply[0..@intCast(count)], "321") != null);
        }
        var pollfd: std.posix.pollfd = .{ .fd = effects[0], .events = std.posix.POLL.IN, .revents = 0 };
        try std.testing.expect(c.poll(@ptrCast(&pollfd), 1, 10000) > 0);
        var end: [1]u8 = undefined;
        try std.testing.expectEqual(@as(isize, 0), c.read(effects[0], &end, 1));
        var status: c_int = 0;
        _ = c.waitpid(caller, &status, 0);
        if (scenario == .independent or scenario == .closed_reply) try std.testing.expectEqual(@as(c_int, 0), status);
    }
}
