const std = @import("std");

const State = enum(u8) { available, borrowed, disabled };
var state: std.atomic.Value(State) = .init(.available);

/// Process-local custody only: external aliases share the temporary flags.
/// No concurrent external flag mutation or restoration after abrupt death is
/// promised. Contention drops optional output instead of waiting for a writer.
pub fn tryAcquire() bool {
    return state.cmpxchgStrong(.available, .borrowed, .acquire, .monotonic) == null;
}

/// Required readiness needs exclusion, not permission for optional output.
/// Disabled borrowing already excludes every optional writer permanently.
pub fn tryExclude() bool {
    const previous = state.cmpxchgStrong(.available, .borrowed, .acquire, .acquire);
    return previous == null or previous == .disabled;
}

pub fn release() void {
    // A failed OS restoration poisons later borrowing, not Host work.
    _ = state.cmpxchgStrong(.borrowed, .available, .release, .monotonic);
}

/// The caller owns custody, including any trace formatting/sequence assignment.
/// One write, no credit wait or retry. Existing process initialization owns
/// SIGPIPE. NONBLOCK does not bound filesystem/device latency or scheduling.
pub fn writeHeld(bytes: []const u8) bool {
    const flags = std.c.fcntl(2, std.c.F.GETFL);
    if (flags < 0) return false;
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    const change_flags = flags & nonblock == 0;
    // Darwin can modify status flags before SETFL reports an ioctl failure.
    // Restore after every attempted enable, even when no write was permitted.
    const enabled = !change_flags or std.c.fcntl(2, std.c.F.SETFL, flags | nonblock) == 0;
    const written = if (enabled) std.c.write(2, bytes.ptr, bytes.len) else -1;
    if (change_flags and std.c.fcntl(2, std.c.F.SETFL, flags) != 0) {
        state.store(.disabled, .release);
        return false;
    }
    return written >= 0 and @as(usize, @intCast(written)) == bytes.len;
}

pub fn write(bytes: []const u8) bool {
    if (!tryAcquire()) return false;
    defer release();
    return writeHeld(bytes);
}

/// A receipt the person must see, such as a path Rui left behind: written
/// whole, waiting for the terminal to take each part. Only after the
/// terminal is restored at exit; all other output keeps `write`'s one try.
pub fn writeReceipt(bytes: []const u8) bool {
    if (!tryAcquire()) return false;
    defer release();
    return writeAllTo(2, bytes);
}

fn writeAllTo(fd: c_int, bytes: []const u8) bool {
    var at: usize = 0;
    while (at < bytes.len) {
        const written = std.c.write(fd, bytes[at..].ptr, bytes.len - at);
        if (written > 0) {
            at += @intCast(written);
            continue;
        }
        if (written == 0) return false;
        switch (std.posix.errno(written)) {
            .INTR => {},
            // Full: wait until the terminal takes more.
            .AGAIN => {
                var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                _ = std.posix.poll(&fds, -1) catch return false;
            },
            else => return false,
        }
    }
    return true;
}

test "a receipt larger than the terminal takes at once arrives whole" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    // As `write` leaves the descriptor: non-blocking, so one write is short.
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    try std.testing.expect(std.c.fcntl(fds[1], std.c.F.SETFL, std.c.fcntl(fds[1], std.c.F.GETFL) | nonblock) == 0);
    // Several times what any pipe or PTY buffers.
    var receipt: [1 << 20]u8 = undefined;
    for (&receipt, 0..) |*byte, at| byte.* = @truncate(at *% 31);
    const Reader = struct {
        fn run(fd: c_int, into: []u8, got: *usize) void {
            while (true) {
                const n = std.c.read(fd, into[got.*..].ptr, into.len - got.*);
                if (n <= 0) return;
                got.* += @intCast(n);
            }
        }
    };
    const read = try std.testing.allocator.alloc(u8, receipt.len + 1);
    defer std.testing.allocator.free(read);
    var got: usize = 0;
    const reader = try std.Thread.spawn(.{}, Reader.run, .{ fds[0], read, &got });
    const ok = writeAllTo(fds[1], &receipt);
    _ = std.c.close(fds[1]);
    reader.join();
    try std.testing.expect(ok);
    try std.testing.expectEqualSlices(u8, &receipt, read[0..got]);
}

/// Never inlined: the line buffer stays in this frame, off every caller's.
pub noinline fn print(comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buffer, format, args) catch return;
    _ = write(bytes);
}

/// Already rendered guidance keeps its owner's bound and line framing,
/// rather than making another copy through print's smaller format buffer.
pub fn diagnosticBytes(bytes: []const u8) void {
    _ = write(bytes);
}

/// Optional fatal guidance cannot retain a restored caller on stderr credit.
/// One bounded write is best-effort; its failure never replaces the real error.
pub fn diagnostic(comptime format: []const u8, args: anytype) void {
    // The preceding transcript may end mid-line, including a partial command.
    print("\n" ++ format, args);
}
