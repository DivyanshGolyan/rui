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

pub fn print(comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buffer, format, args) catch return;
    _ = write(bytes);
}
