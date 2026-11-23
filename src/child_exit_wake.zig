//! Owns the Host's SIGCHLD disposition. A child's exit wakes the execution
//! loop at once, so Bash retirement starts when the command ends rather than
//! at the loop's next 25 ms timeout (#2085). The handler never reaps: the
//! disposition is a handler, not SIG_IGN, so exited children stay waitable
//! and Bash still observes its leader without reaping it.
const std = @import("std");

pub const Wake = struct {
    event: *std.Io.Event,
    io: std.Io,
};

var wake: std.atomic.Value(?*const Wake) = .init(null);
var writing: std.atomic.Value(u32) = .init(0);

/// Replaces any inherited SIGCHLD disposition, including SIG_IGN, which would
/// let the kernel reap Bash leaders before Rui observes them.
pub fn install() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handle },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART | std.posix.SA.NOCLDSTOP,
    };
    std.posix.sigaction(.CHLD, &action, null);
}

pub fn restore() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.CHLD, &action, null);
}

/// `target` must stay valid until `detach` returns.
pub fn attach(target: *const Wake) void {
    wake.store(target, .seq_cst);
}

/// Clears `target` if it is still the attached wake, then returns once no
/// handler can still be using it. A later attach keeps its own wake.
pub fn detach(target: *const Wake) void {
    _ = wake.cmpxchgStrong(target, null, .seq_cst, .seq_cst);
    while (writing.load(.seq_cst) != 0) std.atomic.spinLoopHint();
}

/// Setting an Event is an atomic swap and, when a waiter sleeps, one futex
/// wake: both are async-signal-safe.
fn handle(_: std.posix.SIG) callconv(.c) void {
    _ = writing.fetchAdd(1, .seq_cst);
    defer _ = writing.fetchSub(1, .seq_cst);
    const target = wake.load(.seq_cst) orelse return;
    const saved = std.c._errno().*;
    target.event.set(target.io);
    std.c._errno().* = saved;
}

test "a child's exit sets the attached wake and leaves the child waitable" {
    install();
    defer restore();
    var event: std.Io.Event = .unset;
    const target: Wake = .{ .event = &event, .io = std.testing.io };
    attach(&target);
    defer detach(&target);
    const pid = std.c.fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) std.c._exit(7);
    event.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } }) catch |err| return err;
    try std.testing.expect(event.isSet());
    var status: c_int = 0;
    try std.testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    try std.testing.expectEqual(@as(c_int, 7), (status >> 8) & 0xff);
}

test "a child's exit with no attached wake changes nothing" {
    install();
    defer restore();
    const pid = std.c.fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) std.c._exit(0);
    var status: c_int = 0;
    try std.testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
}
